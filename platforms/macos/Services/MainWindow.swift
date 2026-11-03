import AppKit
import SwiftUI

/// The main window: the timesheet, projects, and settings. Shifty lives in
/// the menu bar; while this is open it's also a regular app with a Dock icon
/// and menus, and it goes back to the menu bar alone when the window closes.
/// Without the store it has settings only.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
  private let timesheet: TimesheetModel?
  private let projects: ProjectsModel?
  private let preferences: Preferences
  private let loginItem: LoginItem
  /// The menu bar's shift, for adding a scheduled break to it today.
  private let shift: ShiftModel?
  private let navigation = MainNavigation()
  private var window: NSWindow?

  init(
    store: ShiftStore?, preferences: Preferences, loginItem: LoginItem, shift: ShiftModel? = nil
  ) {
    self.shift = shift
    timesheet = store.map { TimesheetModel(store: $0, preferences: preferences) }
    projects = store.map { ProjectsModel(store: $0) }
    self.preferences = preferences
    self.loginItem = loginItem
    if store == nil { navigation.screen = .settings }
  }

  /// Called after the timesheet writes, e.g. moving a clock in.
  var didChange: (() -> Void)? {
    get { timesheet?.didChange }
    set { timesheet?.didChange = newValue }
  }

  var isVisible: Bool { window?.isVisible ?? false }

  /// Shows the window, on `screen` if given.
  func show(_ screen: MainScreen? = nil) {
    if let screen, timesheet != nil || !screen.needsStore { navigation.screen = screen }
    let window = self.window ?? makeWindow()
    self.window = window
    reload()
    let wasAccessory = NSApp.activationPolicy() != .regular
    NSApp.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    if wasAccessory { Self.claimMenuBar(window) }
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
    window.title = appName
    window.isReleasedWhenClosed = false
    let host = NSHostingController(
      rootView: MainView(
        timesheet: timesheet, projects: projects, preferences: preferences, loginItem: loginItem,
        shift: shift, navigation: navigation))
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

  /// Every screen is cheap to read, so all stay current.
  func reload() {
    timesheet?.reload()
    projects?.reload()
    preferences.pull()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    // Pick up time the popover's breaks stopped, which the store watcher
    // doesn't see (it only notices other processes).
    reload()
  }

  func windowWillClose(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}
