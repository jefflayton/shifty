import AppKit
import SwiftUI

/// The main window: the timesheet, projects, and settings, picked in a
/// sidebar. Shifty lives in the menu bar; while this is open it's also a
/// regular app with a Dock icon and menus (see `AppWindows`). Without the
/// store, the timesheet and projects say why.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
  private let timesheet: TimesheetModel?
  private let projects: ProjectsModel?
  private let preferences: Preferences
  private let loginItem: LoginItem
  private let shift: ShiftModel?
  /// Why the store didn't open, if it didn't.
  private let storeError: String?
  private let navigation = MainNavigation()
  private var window: NSWindow?
  /// The window's undo: timesheet changes, and typing in its fields.
  private let undoManager = UndoManager()

  init(
    store: ShiftStore?, storeError: String? = nil, preferences: Preferences,
    loginItem: LoginItem, shift: ShiftModel?
  ) {
    self.storeError = storeError
    timesheet = store.map { TimesheetModel(store: $0, preferences: preferences) }
    projects = store.map { ProjectsModel(store: $0) }
    self.preferences = preferences
    self.loginItem = loginItem
    self.shift = shift
    super.init()
    timesheet?.undoManager = undoManager
  }

  /// Called after the timesheet writes, e.g. moving a clock in.
  var didChange: (() -> Void)? {
    get { timesheet?.didChange }
    set { timesheet?.didChange = newValue }
  }

  var isVisible: Bool { window?.isVisible ?? false }
  /// Whether it's showing a page of settings.
  var showsSettings: Bool { navigation.screen.isSettings }

  /// Shows the window, on `screen` if given.
  func show(_ screen: MainScreen? = nil) {
    if let screen { navigation.screen = screen }
    let window = self.window ?? makeWindow()
    self.window = window
    reload()
    AppWindows.present(window)
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: Self.defaultSize()),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = appName
    window.isReleasedWhenClosed = false
    let host = NSHostingController(
      rootView: MainView(
        timesheet: timesheet, projects: projects, storeError: storeError, navigation: navigation,
        preferences: preferences, loginItem: loginItem, shift: shift))
    // Let the views' .toolbar and titles fill the window's.
    host.sceneBridgingOptions = [.toolbars, .title]
    // The window keeps the size it's given; SwiftUI's would shrink it to fit.
    host.sizingOptions = [.minSize]
    window.contentViewController = host
    window.toolbarStyle = .unified
    window.delegate = self
    window.setContentSize(Self.defaultSize())
    window.center()
    // A new name for the bigger default; a frame you've saved since wins.
    window.setFrameAutosaveName("MainWindow.v3")
    return window
  }

  /// Roomy, but never past the screen: up to 1440×900, leaving a margin.
  static func defaultSize(screen: NSScreen? = .main) -> NSSize {
    let visible = screen?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
    return NSSize(
      width: min(1440, max(940, visible.width * 0.9)),
      height: min(900, max(560, visible.height * 0.9)))
  }

  /// Every screen is cheap to read, so all stay current.
  func reload() {
    timesheet?.reload()
    projects?.reload()
    preferences.pull()
    if showsSettings { loginItem.refresh() }
  }

  func windowDidBecomeKey(_ notification: Notification) {
    // Pick up time the popover's breaks stopped, which the store watcher
    // doesn't see (it only notices other processes).
    reload()
  }

  func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { undoManager }

  func windowWillClose(_ notification: Notification) {
    AppWindows.didClose(window)
  }
}

/// Shifty is a menu bar app until one of its windows opens: then it's a
/// regular app with a Dock icon and menus, until the last one closes.
@MainActor
enum AppWindows {
  static func present(_ window: NSWindow) {
    let wasAccessory = NSApp.activationPolicy() != .regular
    NSApp.setActivationPolicy(.regular)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate()
    if wasAccessory { claimMenuBar(window) }
  }

  /// Back to the menu bar alone once no other window is open.
  static func didClose(_ window: NSWindow?) {
    let others = NSApp.windows.contains {
      $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel)
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
}
