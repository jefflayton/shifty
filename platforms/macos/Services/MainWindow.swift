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
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
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
