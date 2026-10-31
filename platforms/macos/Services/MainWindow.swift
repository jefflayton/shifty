import AppKit
import SwiftUI

/// The main window. Shifty lives in the menu bar; while this is open it's
/// also a regular app with a Dock icon and menus, and it goes back to the
/// menu bar alone when the window closes.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
  private let model: TimesheetModel
  private var window: NSWindow?

  init(model: TimesheetModel) {
    self.model = model
  }

  var isVisible: Bool { window?.isVisible ?? false }

  func show() {
    let window = self.window ?? makeWindow()
    self.window = window
    model.reload()
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
    window.title = "Shifty"
    window.isReleasedWhenClosed = false
    window.contentViewController = NSHostingController(rootView: TimesheetView(model: model))
    window.delegate = self
    window.center()
    window.setFrameAutosaveName("MainWindow")
    return window
  }

  func reload() { model.reload() }

  func windowDidBecomeKey(_ notification: Notification) {
    // Pick up time the popover's breaks stopped, which the store watcher
    // doesn't see (it only notices other processes).
    model.reload()
  }

  func windowWillClose(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
  }
}
