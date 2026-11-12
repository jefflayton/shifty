import AppKit
import Foundation
import Observation
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
  /// The timesheet and projects; nil without the store.
  lazy var mainWindow: MainWindow? = store.map { store in
    let window = MainWindow(
      store: store, preferences: preferences, shift: model, autoSwitch: autoSwitch)
    // A clock in or break moved on the timesheet: the popover reads it before
    // it saves its own copy over it.
    window.didChange = { [weak self] in
      self?.model.pull()
      self?.tracking?.reload()
    }
    return window
  }
  lazy var settingsWindow = SettingsWindow(
    preferences: preferences, loginItem: loginItem, shift: store == nil ? nil : model)
  lazy var tracking = store.map { store in
    let tracking = TrackingModel(store: store)
    // Starting a timer ends a break in progress.
    tracking.didChange = { [weak self] in
      self?.model.pull()
      if self?.mainWindow?.isVisible == true { self?.mainWindow?.reload() }
    }
    return tracking
  }
  /// Moves the timer to the project linked to where you work.
  lazy var autoSwitch = tracking.map { AutoSwitchModel(tracking: $0, preferences: preferences) }
  private var focusWatcher: FocusWatcher?
  /// Runs Rex's script so auto switch follows its tabs and sessions.
  private var rexWatcher: RexWatcher?
  private var switchBanner: SwitchBanner?
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

    followLunch()
    alarmScheduler = AlarmScheduler(
      model: model, preferences: preferences, controller: .shared)
    AlarmController.shared.isClockedIn = { [weak self] in self?.model.isClockedIn ?? false }
    AlarmController.shared.endShift = { [weak self] in self?.clockOutFromAlarm() ?? false }
    AlarmController.shared.snoozeLength = { [weak self] in
      self?.preferences.snoozeLength ?? Preferences.defaultSnooze
    }
    watchStore()
    if let store, let autoSwitch {
      let banner = SwitchBanner(model: autoSwitch)
      autoSwitch.didChange = { [weak banner] in banner?.update() }
      autoSwitch.onShiftSince = { [weak self] in
        guard let model = self?.model, model.isClockedIn, !model.isOnBreak else { return nil }
        return model.clockInTime
      }
      switchBanner = banner
      focusWatcher = FocusWatcher(store: store, model: autoSwitch)
      focusWatcher?.start()
      rexWatcher = RexWatcher()
      followRex()
    }

    setupMenu()

    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItemController = StatusItemController(
      item: item, model: model, preferences: preferences)
    item.button?.action = #selector(toggle)

    popover = NSPopover()
    let host = NSHostingController(
      rootView: PopoverView(
        updater: updateController.updater, model: model, preferences: preferences,
        loginItem: loginItem, tracking: tracking, autoSwitch: autoSwitch,
        openTimesheet: store == nil ? nil : { [weak self] in self?.showMainWindow() },
        openSettings: { [weak self] in self?.showSettings() },
        clocked: { [weak self] event in self?.offerClockLink(event) }))
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
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.mainWindow?.show() }
    }

    // Development: open the popover without clicking the status item.
    if ProcessInfo.processInfo.environment["SHIFTY_OPEN_ON_LAUNCH"] != nil {
      // Wait for the status item to be placed in the menu bar.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.toggle() }
    }
  }

  /// Runs the Rex script while auto switch follows Rex, for this Mac and
  /// the hosts in the settings.
  private func followRex() {
    withObservationTracking {
      rexWatcher?.update(
        follow: preferences.autoSwitch && preferences.followRex,
        hosts: RexFollow.hosts(preferences.rexHosts))
    } onChange: { [weak self] in
      Task { @MainActor in self?.followRex() }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    rexWatcher?.stop()
  }

  /// Keeps the shift's lunch window, which clock out counts, up with the
  /// settings.
  private func followLunch() {
    withObservationTracking {
      model.lunchRule = preferences.lunch
    } onChange: { [weak self] in
      Task { @MainActor in self?.followLunch() }
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
    if mainWindow?.isVisible == true { mainWindow?.reload() }
  }

  func showMainWindow() {
    popover.close()
    mainWindow?.show(.timesheet)
  }

  @objc func showTimesheet() { showMainWindow() }

  /// Puts the bundled `shifty` command in PATH, and says how it went.
  @objc func installCommandLineTool() {
    let name = CommandLineTool.name
    let alert = NSAlert()
    switch CommandLineTool.status {
    case .missing:
      alert.messageText = "This build of Shifty has no command line tool."
      alert.informativeText = "Rebuild it with zig build macos."
    case .installed:
      alert.messageText = "The \(name) command is installed."
      alert.informativeText = "It's at \(CommandLineTool.link). Run \(name) --help to get started."
    case .notInstalled, .taken:
      guard CommandLineTool.install() else { return }
      alert.messageText = "Installed the \(name) command."
      alert.informativeText =
        "Open a new terminal and run \(name) --help. To have auto-switch follow your terminal, add the hook from Settings → Auto-Switch."
    }
    NSApp.activate()
    alert.runModal()
  }

  @objc func showProjects() {
    popover.close()
    mainWindow?.show(.projects)
  }

  @objc func showMeetings() {
    popover.close()
    mainWindow?.show(.meetings)
  }

  @objc func showBreaks() {
    popover.close()
    mainWindow?.show(.breaks)
  }

  /// An alarm's Clock Out: ends the shift as the popover's would, without
  /// the link prompt (the alarm opens the link itself).
  private func clockOutFromAlarm() -> Bool {
    guard model.isClockedIn else { return false }
    model.clockOutNow()
    tracking?.reload()
    if mainWindow?.isVisible == true { mainWindow?.reload() }
    return true
  }

  /// Clocked in or out, or started or ended lunch, from the popover: close
  /// it so the browser comes to the front, then open the clock link or ask
  /// to.
  func offerClockLink(_ event: ClockEvent) {
    guard preferences.clockLinkAction(for: event) != .none else { return }
    popover.close()
    DispatchQueue.main.async { [preferences] in
      ClockLinkPrompt.offer(event, preferences: preferences)
    }
  }

  @objc func showSettings() {
    popover.close()
    settingsWindow.show()
  }

  /// Clicking the Dock icon with the window closed (or minimized) shows it.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    if !flag {
      popover.close()
      // Without the store there's only settings.
      if let mainWindow { mainWindow.show() } else { settingsWindow.show() }
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

extension AppDelegate: NSMenuItemValidation {
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    // Without the store there's no timesheet.
    case #selector(showTimesheet), #selector(showProjects): store != nil
    default: true
    }
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
  appMenu.addItem(
    withTitle: "Install Command Line Tool…",
    action: #selector(AppDelegate.installCommandLineTool), keyEquivalent: "")
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

  let viewItem = NSMenuItem()
  viewItem.title = "View"
  mainMenu.addItem(viewItem)
  let viewMenu = NSMenu(title: "View")
  viewItem.submenu = viewMenu
  let sidebar = viewMenu.addItem(
    withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)),
    keyEquivalent: "s")
  sidebar.keyEquivalentModifierMask = [.command, .control]
  viewMenu.addItem(.separator())
  let fullScreen = viewMenu.addItem(
    withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)),
    keyEquivalent: "f")
  fullScreen.keyEquivalentModifierMask = [.command, .control]

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
    withTitle: "Timesheet", action: #selector(AppDelegate.showTimesheet), keyEquivalent: "1")
  windowMenu.addItem(
    withTitle: "Meetings", action: #selector(AppDelegate.showMeetings), keyEquivalent: "2")
  windowMenu.addItem(
    withTitle: "Breaks", action: #selector(AppDelegate.showBreaks), keyEquivalent: "3")
  windowMenu.addItem(
    withTitle: "Projects", action: #selector(AppDelegate.showProjects), keyEquivalent: "4")
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
