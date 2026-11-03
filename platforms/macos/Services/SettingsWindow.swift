import AppKit
import SwiftUI

/// The Settings window. Like the main window, Shifty is a regular app while
/// it's open.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
  private let preferences: Preferences
  private let loginItem: LoginItem
  private var window: NSWindow?

  init(preferences: Preferences, loginItem: LoginItem) {
    self.preferences = preferences
    self.loginItem = loginItem
  }

  func show() {
    let window = self.window ?? makeWindow()
    self.window = window
    MainWindow.bringForward(window)
  }

  private func makeWindow() -> NSWindow {
    let host = NSHostingController(
      rootView: SettingsView(preferences: preferences, loginItem: loginItem))
    host.sizingOptions = .preferredContentSize
    let window = NSWindow(contentViewController: host)
    window.title = "Settings"
    window.styleMask = [.titled, .closable]
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    return window
  }

  func windowWillClose(_ notification: Notification) {
    if let window { MainWindow.returnToMenuBar(closing: window) }
  }
}
