import AppKit
import Foundation
import Sparkle
import SwiftUI
import UserNotifications

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
  var popover: NSPopover!
  /// Close the popover on a click or focus anywhere else; see `watchFocus`.
  private var clickMonitors: [Any] = []
  private var focusObservers: [NSObjectProtocol] = []
  var item: NSStatusItem!
  /// The database the CLI and TUI share. Without it the app still works,
  /// as a calculator only.
  let store = AppDelegate.openStore()
  lazy var model = ShiftModel.load(store: store)
  lazy var preferences = Preferences(store: store)
  lazy var mainWindow: MainWindow = {
    let window = MainWindow(
      store: store, preferences: preferences, loginItem: loginItem, shift: model)
    // A clock in or break moved on the timesheet: the popover reads it before
    // it saves its own copy over it.
    window.didChange = { [weak self] in
      self?.model.pull()
      self?.tracking?.reload()
    }
    return window
  }()
  lazy var tracking = store.map { store in
    let tracking = TrackingModel(store: store)
    // Starting a timer ends a break in progress.
    tracking.didChange = { [weak self] in
      self?.model.pull()
      if self?.mainWindow.isVisible == true { self?.mainWindow.reload() }
    }
    return tracking
  }
  let loginItem = LoginItem()
  private var storeWatcher: Timer?
  private var storeVersion: Int64?
  private var alarmScheduler: AlarmScheduler!
  private var statusItemController: StatusItemController!

  private var updateController: SPUStandardUpdaterController!

  func applicationDidFinishLaunching(_ notification: Notification) {
    setupLogs()

    updateController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )

    NSApp.setActivationPolicy(.accessory)

    alarmScheduler = AlarmScheduler(
      model: model, preferences: preferences, controller: .shared)
    AlarmController.shared.isClockedIn = { [weak self] in self?.model.isClockedIn ?? false }
    AlarmController.shared.endShift = { [weak self] in self?.clockOutFromAlarm() ?? false }
    watchStore()

    setupMenu()

    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItemController = StatusItemController(
      item: item, model: model, preferences: preferences)
    item.button?.action = #selector(toggle)

    popover = NSPopover()
    let host = NSHostingController(
      rootView: PopoverView(
        updater: updateController.updater, model: model, preferences: preferences,
        loginItem: loginItem, tracking: tracking,
        openTimesheet: store == nil ? nil : { [weak self] in self?.showMainWindow() },
        openSettings: { [weak self] in self?.showSettings() },
        clocked: { [weak self] clockingIn in self?.offerClockLink(clockingIn: clockingIn) }))
    // Let the SwiftUI content size the popover. Otherwise NSPopover keeps its
    // default 320x320, positions itself for that, and taller content grows
    // the window upward from its bottom edge, over the menu bar.
    host.sizingOptions = .preferredContentSize
    popover.contentViewController = host
    popover.behavior = .transient
    popover.delegate = self

    // Development: open the main window without clicking.
    if ProcessInfo.processInfo.environment["SHIFTY_OPEN_TIMESHEET"] != nil {
      // Active first, like a click on the popover, then the window.
      NSApp.activate()
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.mainWindow.show() }
    }

    // Development: open the popover without clicking the status item.
    if ProcessInfo.processInfo.environment["SHIFTY_OPEN_ON_LAUNCH"] != nil {
      // Wait for the status item to be placed in the menu bar.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.toggle() }
    }
  }

  private static func openStore() -> ShiftStore? {
    do {
      return try ShiftStore()
    } catch {
      log("open store:", error)
      return nil
    }
  }

  /// Picks up what the TUI and CLI write. The store's data version moves
  /// only for other processes' writes, so the app's own don't loop back.
  private func watchStore() {
    guard let store else { return }
    storeVersion = try? store.dataVersion()
    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.checkStore() }
    }
    timer.tolerance = 1
    RunLoop.main.add(timer, forMode: .common)
    storeWatcher = timer
  }

  private func checkStore() {
    // A planned break, like a class, stops the timer when it begins.
    if model.isClockedIn { tracking?.stopForBreaks(model.anchoredBreaks()) }
    guard let store, let version = try? store.dataVersion(), version != storeVersion else { return }
    storeVersion = version
    model.pull()
    preferences.pull()
    tracking?.reload()
    if mainWindow.isVisible { mainWindow.reload() }
  }

  func showMainWindow() {
    popover.close()
    mainWindow.show(.timesheet)
  }

  /// An alarm's Clock Out: ends the shift as the popover's would, without
  /// the link prompt (the alarm opens the link itself).
  private func clockOutFromAlarm() -> Bool {
    guard model.isClockedIn else { return false }
    model.clockOutNow()
    tracking?.reload()
    if mainWindow.isVisible { mainWindow.reload() }
    return true
  }

  /// Clocked in or out from the popover: close it so the browser comes to
  /// the front, then open the clock link or ask to.
  func offerClockLink(clockingIn: Bool) {
    guard preferences.clockLinkAction(clockingIn: clockingIn) != .none else { return }
    popover.close()
    DispatchQueue.main.async { [preferences] in
      ClockLinkPrompt.offer(clockingIn: clockingIn, preferences: preferences)
    }
  }

  @objc func showSettings() {
    popover.close()
    mainWindow.show(.settings)
  }

  /// Clicking the Dock icon with the window closed (or minimized) shows it.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    if !flag {
      popover.close()
      mainWindow.show()
    }
    return true
  }

  @objc func toggle() {
    if popover.isShown {
      popover.close()
    } else {
      NSApp.activate(ignoringOtherApps: true)
      popover.show(
        relativeTo: item.button!.bounds, of: item.button!, preferredEdge: NSRectEdge.maxY)
      watchFocus()
    }
  }

  // MARK: Popover dismissal

  /// A transient popover only closes on an outside click while Shifty is
  /// active, and macOS doesn't always let a menu bar app activate. Nor does
  /// it close when the main window is clicked or comes forward. So close it
  /// on any click elsewhere, in Shifty or another app, and whenever another
  /// window takes focus or Shifty loses it.
  private func watchFocus() {
    guard clickMonitors.isEmpty, focusObservers.isEmpty else { return }
    let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

    if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
      MainActor.assumeIsolated { self?.popover.close() }
    }) {
      clickMonitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
      MainActor.assumeIsolated { self?.closeIfOutside(event.window) }
      return event
    }) {
      clickMonitors.append(local)
    }

    let center = NotificationCenter.default
    focusObservers.append(
      center.addObserver(
        forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.popover.close() }
      })
    focusObservers.append(
      center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) {
        [weak self] note in
        MainActor.assumeIsolated { self?.closeIfOutside(note.object as? NSWindow) }
      })
  }

  /// Closes the popover unless `window` is part of it: the popover itself,
  /// a menu or pop-up it opened, or the status item (its click toggles).
  private func closeIfOutside(_ window: NSWindow?) {
    guard popover.isShown else { return }
    if let window {
      let popoverWindow = popover.contentViewController?.view.window
      if window === popoverWindow || window === item.button?.window { return }
      if window.level >= .popUpMenu { return }
      var parent = window.parent
      while let p = parent {
        if p === popoverWindow { return }
        parent = p.parent
      }
    }
    popover.close()
  }

  private func unwatchFocus() {
    clickMonitors.forEach(NSEvent.removeMonitor)
    clickMonitors = []
    focusObservers.forEach(NotificationCenter.default.removeObserver)
    focusObservers = []
  }

  func popoverDidClose(_ notification: Notification) {
    unwatchFocus()
  }
}

func setupMenu() {
  let mainMenu = NSMenu()

  let appItem = NSMenuItem()
  mainMenu.addItem(appItem)
  let appMenu = NSMenu()
  appItem.submenu = appMenu
  appMenu.addItem(
    withTitle: "About Shifty",
    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
  appMenu.addItem(.separator())
  appMenu.addItem(
    withTitle: "Settings…", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
  appMenu.addItem(.separator())
  appMenu.addItem(
    withTitle: "Hide Shifty", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
  let hideOthers = appMenu.addItem(
    withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
    keyEquivalent: "h")
  hideOthers.keyEquivalentModifierMask = [.command, .option]
  appMenu.addItem(
    withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
    keyEquivalent: "")
  appMenu.addItem(.separator())
  appMenu.addItem(
    withTitle: "Quit Shifty",
    action: #selector(NSApplication.terminate(_:)),
    keyEquivalent: "q")

  let fileItem = NSMenuItem()
  fileItem.title = "File"
  mainMenu.addItem(fileItem)
  let fileMenu = NSMenu(title: "File")
  fileItem.submenu = fileMenu
  fileMenu.addItem(
    withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

  let editItem = NSMenuItem()
  editItem.title = "Edit"
  mainMenu.addItem(editItem)
  let editMenu = NSMenu(title: "Edit")
  editItem.submenu = editMenu

  editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
  editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
  editMenu.addItem(.separator())
  editMenu.addItem(
    withTitle: "Cut", action: #selector(NSText.cut(_:)),
    keyEquivalent:
      "x")
  editMenu.addItem(
    withTitle: "Copy", action: #selector(NSText.copy(_:)),
    keyEquivalent:
      "c")
  editMenu.addItem(
    withTitle: "Paste", action: #selector(NSText.paste(_:)),
    keyEquivalent: "v")
  editMenu.addItem(
    withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
    keyEquivalent: "a")

  let windowItem = NSMenuItem()
  windowItem.title = "Window"
  mainMenu.addItem(windowItem)
  let windowMenu = NSMenu(title: "Window")
  windowItem.submenu = windowMenu
  windowMenu.addItem(
    withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)),
    keyEquivalent: "m")
  windowMenu.addItem(
    withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
  windowMenu.addItem(.separator())
  windowMenu.addItem(
    withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)),
    keyEquivalent: "")
  NSApp.windowsMenu = windowMenu

  NSApp.mainMenu = mainMenu
}

/// "Shifty", or "Shifty Dev" for a build without `-Drelease`.
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Shifty"

func setupLogs() {
  // A dev build logs on its own, so its errors aren't mistaken for the
  // installed app's.
  let dir = "\(NSHomeDirectory())/Library/Logs/\(appName)"
  try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  let path = "\(dir)/shifty.log"
  freopen(path, "a+", stdout)
  freopen(path, "a+", stderr)
  setvbuf(stdout, nil, _IOLBF, 0)
  setvbuf(stderr, nil, _IOLBF, 0)
}

private var appDelegate: AppDelegate?

@_cdecl("swiftuiInit")
public func swiftuiInit() {}

@_cdecl("swiftuiRun")
public func swiftuiRun() {
  // Called from Zig's main on the main thread.
  MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    appDelegate = delegate  // retain
    app.delegate = delegate
    app.run()
  }
}
