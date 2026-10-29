import AppKit
import Foundation
import Sparkle
import SwiftUI
import UserNotifications

func log(_ items: Any..., separator: String = " ", terminator: String = "\n") {
  let body = items.map { "\($0)" }.joined(separator: separator)
  print("[swift.menubar]", body, terminator: terminator)
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
  var popover: NSPopover!
  var item: NSStatusItem!
  let model = ShiftModel.load()
  private var alarmScheduler: AlarmScheduler!

  private var updateController: SPUStandardUpdaterController!

  func applicationDidFinishLaunching(_ notification: Notification) {
    setupLogs()

    updateController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )

    NSApp.setActivationPolicy(.accessory)

    alarmScheduler = AlarmScheduler(model: model, controller: .shared)

    setupMenu()

    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    let symbol =
      NSImage(
        systemSymbolName: "clock.arrow.trianglehead.clockwise.rotate.90.path.dotted",
        accessibilityDescription: "Shifty")
      ?? NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Shifty")
    item.button?.image = symbol

    item.button?.action = #selector(toggle)

    popover = NSPopover()
    popover.contentViewController = NSHostingController(
      rootView: PopoverView(updater: updateController.updater, model: model))
    popover.behavior = .transient

    // Development: open the popover without clicking the status item.
    if ProcessInfo.processInfo.environment["SHIFTY_OPEN_ON_LAUNCH"] != nil {
      DispatchQueue.main.async { self.toggle() }
    }
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
    withTitle: "Quit Shifty",
    action: #selector(NSApplication.terminate(_:)),
    keyEquivalent: "q")

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
