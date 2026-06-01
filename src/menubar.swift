import AppKit
import Foundation
import SwiftUI

struct PopoverView: View {
  var onClockIn: (Date) -> Void

  @State private var clockInTime = Date()

  var body: some View {
    VStack {
      Text("Shifty")
      DatePicker("Clock In", selection: $clockInTime, displayedComponents: .hourAndMinute)
      Button(
        "Clock In",
        role: .none,
        action: { onClockIn(clockInTime) }
      )
    }
    .padding()
    .frame(width: 200)
  }
}

class AppDelegate: NSObject, NSApplicationDelegate {
  var popover: NSPopover!
  var item: NSStatusItem!

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    NSApplication.shared.activate(ignoringOtherApps: true)

    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.title = "😎"
    item.button?.action = #selector(toggle)

    popover = NSPopover()
    popover.contentViewController = NSHostingController(
      rootView: PopoverView(onClockIn: onClockIn))
    popover.behavior = .transient
  }

  @objc func toggle() {
    if popover.isShown {
      popover.close()
    } else {
      popover.show(
        relativeTo: item.button!.bounds, of: item.button!, preferredEdge: NSRectEdge.maxY)
    }
  }

  func onClockIn(date: Date) {
    let ts = date.timeIntervalSince1970
    zigClockIn(ts: Int(ts))
  }

}

struct ZigApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

  var body: some Scene {}
}

@_cdecl("swiftuiInit")
public func swiftuiInit() {}

@_cdecl("swiftuiRun")
public func swiftuiRun() {
  ZigApp.main()
}

@_silgen_name("zigClockIn")
func zigClockIn(ts: Int)
