import AppKit
import SwiftUI

/// The main window. Shifty lives in the menu bar; while this is open it's
/// also a regular app with a Dock icon and menus, and it goes back to the
/// menu bar alone when the window closes.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
  private let timesheet: TimesheetModel
  private let projects: ProjectsModel
  private var window: NSWindow?

  init(store: ShiftStore, preferences: Preferences) {
    timesheet = TimesheetModel(store: store, preferences: preferences)
    projects = ProjectsModel(store: store)
  }

  /// Called after the timesheet writes, e.g. moving a clock in.
  var didChange: (() -> Void)? {
    get { timesheet.didChange }
    set { timesheet.didChange = newValue }
  }

  var isVisible: Bool { window?.isVisible ?? false }

  func show() {
    let window = self.window ?? makeWindow()
    self.window = window
    reload()
    Self.bringForward(window)
  }

  /// Shows `window` as a regular app's: with a Dock icon and the menu bar.
  static func bringForward(_ window: NSWindow) {
    let wasAccessory = NSApp.activationPolicy() != .regular
    NSApp.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    if wasAccessory { claimMenuBar(window) }
  }

  /// Back to the menu bar alone, once no window of ours is open. `closing`
  /// is on its way out but still visible.
  static func returnToMenuBar(closing: NSWindow) {
    let others = NSApp.windows.contains {
      $0 !== closing && $0.isVisible && ($0.delegate is MainWindow || $0.delegate is SettingsWindow)
    }
    if !others { NSApp.setActivationPolicy(.accessory) }
  }

  /// An app that turns regular while it's already active (as it is after a
  /// click in the popover) gets a menu bar that ignores clicks until it's
  /// activated again. So hand activation to the Dock and take it back.
  private static func claimMenuBar(_ window: NSWindow) {
    guard
      let dock = NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.apple.dock"
      ).first
    else { return }
    NSApp.yieldActivation(to: dock)
    dock.activate()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        // macOS can keep another app active instead. Keep the window on
        // top anyway: clicking it activates Shifty, menu bar and all.
        if !NSApp.isActive { window.orderFrontRegardless() }
      }
    }
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "Shifty"
    window.isReleasedWhenClosed = false
    let host = NSHostingController(rootView: MainView(timesheet: timesheet, projects: projects))
    // Let the views' .toolbar fill the window's.
    host.sceneBridgingOptions = [.toolbars]
    window.contentViewController = host
    window.toolbarStyle = .unified
    // The toolbar's switcher says which screen this is.
    window.titleVisibility = .hidden
    window.delegate = self
    window.center()
    window.setFrameAutosaveName("MainWindow")
    return window
  }

  /// Both screens are cheap to read, so both stay current.
  func reload() {
    timesheet.reload()
    projects.reload()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    // Pick up time the popover's breaks stopped, which the store watcher
    // doesn't see (it only notices other processes).
    reload()
  }

  func windowWillClose(_ notification: Notification) {
    if let window { Self.returnToMenuBar(closing: window) }
  }
}
