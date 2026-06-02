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
  @State var shiftLength = 8
  @State var lunchMins = 0.0
  @State var quitHovered = false

  func onClockIn() {
    let inTs = self.clockInTime.timeIntervalSince1970
    let outTs = zigClockIn(shift: shiftLength, in_ts: Int(inTs), lunch: Int(lunchMins))

    DispatchQueue.main.async {
      self.state.clockOutTime = Date(timeIntervalSince1970: TimeInterval(outTs))
    }
  }

  var body: some View {
    VStack {
      Text("Shifty")
        .font(.system(size: 20))
        .padding(.vertical, 5)

      HStack {
        Text("Shift Length").bold()
        Spacer()
        TextField("Shift Length", value: $shiftLength, format: .number)
          .frame(width: 20)
        Text(" hr")
      }

      DatePicker("Clock In", selection: $clockInTime, displayedComponents: .hourAndMinute)

      HStack {
        Text("Lunch").bold()
        Spacer()
        TextField("Lunch", value: $lunchMins, format: .number)
          .frame(width: 40)
        Text(" min")
      }.padding(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))

      Slider(value: $lunchMins, in: 0...120, step: 1) {
      } minimumValueLabel: {
        Text("0")
      } maximumValueLabel: {
        Text("120")
      }

      if let clockOut = self.state.clockOutTime {
        HStack {
          Text("Clock Out:").bold()
          Text(clockOut, style: .time)
        }.padding()
      }

      Button(
        "Clock In",
        role: .none,
        action: { onClockIn() }
      )

      Divider()
      Button {
        NSApp.terminate(nil)
      } label: {
        HStack {
          Text("Quit Shifty")
          Spacer()
        }
        .buttonStyle(.borderless)
        .tint(.clear)
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .padding(.vertical, 4)

        .background(
          quitHovered ? Color.accentColor : .clear,
          in: RoundedRectangle(
            cornerRadius:
              4)
        )
        .foregroundStyle(quitHovered ? .white : .primary)
      }
      .buttonStyle(.borderless)
      .onHover { quitHovered = $0 }
      .padding(.horizontal, 4)
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
    item.button?.image = NSImage(
      systemSymbolName: "clock.arrow.trianglehead.clockwise.rotate.90.path.dotted",
      accessibilityDescription:
        "Shifty")
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
func zigClockIn(shift: Int, in_ts: Int, lunch: Int) -> Int
