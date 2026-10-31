import AppKit
import Foundation
import Sparkle
import SwiftUI
import UserNotifications

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  var popover: NSPopover!
  var item: NSStatusItem!
  /// The database the CLI and TUI share. Without it the app still works,
  /// as a calculator only.
  let store = AppDelegate.openStore()
  lazy var model = ShiftModel.load(store: store)
  lazy var preferences = Preferences(store: store)
  lazy var mainWindow = store.map { MainWindow(store: $0) }
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
        loginItem: loginItem,
        openTimesheet: mainWindow == nil ? nil : { [weak self] in self?.showMainWindow() }))
    // Let the SwiftUI content size the popover. Otherwise NSPopover keeps its
    // default 320x320, positions itself for that, and taller content grows
    // the window upward from its bottom edge, over the menu bar.
    host.sizingOptions = .preferredContentSize
    popover.contentViewController = host
    popover.behavior = .transient

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
    guard let store, let version = try? store.dataVersion(), version != storeVersion else { return }
    storeVersion = version
    model.pull()
    preferences.pull()
    if mainWindow?.isVisible == true { mainWindow?.reload() }
  }

  func showMainWindow() {
    popover.close()
    mainWindow?.show()
  }

  /// Clicking the Dock icon with the window closed (or minimized) shows it.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    if !flag { mainWindow?.show() }
    return true
  }

  @objc func toggle() {
    if popover.isShown {
      popover.close()
    } else {
      NSApp.activate(ignoringOtherApps: true)
      popover.show(
        relativeTo: item.button!.bounds, of: item.button!, preferredEdge: NSRectEdge.maxY)
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

func setupLogs() {
  let dir = "\(NSHomeDirectory())/Library/Logs/Shifty"
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
