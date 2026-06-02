import AppKit
import Foundation
import SwiftUI

var globalState: GlobalState? = nil

class GlobalState: ObservableObject {
  static let shared = GlobalState()
  @Published var clockOutTime: Date? = nil
}

struct PopoverView: View {
  @StateObject var state = GlobalState.shared
  @State var clockInTime = Date()

  func onClockIn(date: Date) {
    let inTs = date.timeIntervalSince1970
    let outTs = zigClockIn(ts: Int(inTs))

    DispatchQueue.main.async {
      self.state.clockOutTime = Date(timeIntervalSince1970: TimeInterval(outTs))
    }
  }

  var body: some View {
    VStack {
      Text("Shifty")

      DatePicker("Clock In", selection: $clockInTime, displayedComponents: .hourAndMinute)
      Button(
        "Clock In",
        role: .none,
        action: { onClockIn(date: clockInTime) }
      )

      if let clockOut = self.state.clockOutTime {
        Text("Clock Out: ").bold()
        Text(clockOut, style: .time)
      }
    }
    .padding()
    .frame(width: 200)
  }
}

class AppDelegate: NSObject, NSApplicationDelegate {
  @StateObject private var globalState = GlobalState.shared
  var popover: NSPopover!
  var item: NSStatusItem!

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    item.button?.title = "😎"
    item.button?.action = #selector(toggle)

    popover = NSPopover()
    popover.contentViewController = NSHostingController(
      rootView: PopoverView())
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
func zigClockIn(ts: Int) -> Int
