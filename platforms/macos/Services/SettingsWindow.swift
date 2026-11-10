import AppKit
import SwiftUI

/// Settings, in a window of their own with toolbar tabs, like any Mac app's.
/// ⌘, and the popover's Settings… open it.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
  private let preferences: Preferences
  private let loginItem: LoginItem
  /// The menu bar's shift, for adding a scheduled break to it today.
  private let shift: ShiftModel?
  private var window: NSWindow?

  init(preferences: Preferences, loginItem: LoginItem, shift: ShiftModel?) {
    self.preferences = preferences
    self.loginItem = loginItem
    self.shift = shift
  }

  func show() {
    preferences.pull()
    // Login items can also be changed in System Settings.
    loginItem.refresh()
    let window = self.window ?? makeWindow()
    self.window = window
    AppWindows.present(window)
  }

  private func makeWindow() -> NSWindow {
    let tabs = SettingsTabsController()
    tabs.tabStyle = .toolbar
    for tab in SettingsTab.allCases {
      let host = NSHostingController(
        rootView: SettingsPane(
          tab: tab, preferences: preferences, loginItem: loginItem, shift: shift))
      // SettingsTabsController sizes the window to this, also when a pane
      // grows, like Clock Links adding the clock-in link.
      host.sizingOptions = .preferredContentSize
      // Becomes the window's title while its tab is picked.
      host.title = tab.title
      let item = NSTabViewItem(viewController: host)
      item.label = tab.title
      item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
      tabs.addTabViewItem(item)
    }

    let window = NSWindow(contentViewController: tabs)
    window.styleMask = [.titled, .closable]
    window.toolbarStyle = .preference
    window.isReleasedWhenClosed = false
    window.delegate = self
    window.center()
    window.setFrameAutosaveName("SettingsWindow")
    tabs.fitWindow(animate: false)
    return window
  }

  func windowWillClose(_ notification: Notification) {
    AppWindows.didClose(window)
  }
}

/// Settings tabs that switch like System Settings' old panes: the new pane
/// shows at once, and the window grows or shrinks to it with its top edge
/// staying put. NSTabViewController's own sizing shows the new pane in the
/// old window for its whole transition, then snaps.
final class SettingsTabsController: NSTabViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    transitionOptions = []
  }

  override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
    super.tabView(tabView, didSelect: item)
    fitWindow(animate: view.window?.isVisible ?? false)
  }

  /// A pane's content changed size. Instead of NSTabViewController's
  /// snap, follow it the same way.
  override func preferredContentSizeDidChange(for viewController: NSViewController) {
    guard viewController === selected else { return }
    fitWindow(animate: view.window?.isVisible ?? false)
  }

  private var selected: NSViewController? {
    tabViewItems[safe: selectedTabViewItemIndex]?.viewController
  }

  /// Sizes the window to the selected pane, keeping its top-left corner.
  func fitWindow(animate: Bool) {
    guard let window = view.window, let size = selected?.preferredContentSize,
      size.width > 0, size.height > 0
    else { return }
    let content = window.contentRect(forFrameRect: window.frame)
    let target = window.frameRect(
      forContentRect: NSRect(
        x: content.minX, y: content.maxY - size.height, width: size.width, height: size.height))
    guard target != window.frame else { return }
    window.setFrame(target, display: true, animate: animate)
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
