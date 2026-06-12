import AppKit
import Foundation
import Sparkle
import SwiftUI

// This view model class publishes when new updates can be checked by the user
final class CheckForUpdatesViewModel: ObservableObject {
  @Published var canCheckForUpdates = false

  init(updater: SPUUpdater) {
    updater.publisher(for: \.canCheckForUpdates)
      .assign(to: &$canCheckForUpdates)
  }
}

class Interval: Identifiable {
  let id = UUID()
  var inDate: Date
  var outDate: Date

  var isValid: Bool { inDate < outDate }

  init() {
    let calendar = Calendar.current
    self.inDate = Date()
    if let newDate = calendar.date(byAdding: .hour, value: 1, to: self.inDate) {
      self.outDate = newDate
    } else {
      self.outDate = Date()
    }
  }
}

@Observable class ShiftModel {
  var clockInTime = Date()
  var shiftLength = 8
  var lunchMins = 0.0
  var breaks: [Interval] = []
}

struct PopoverView: View {
  @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
  private let updater: SPUUpdater

  @Bindable var model: ShiftModel
  @State var quitHovered = false

  var clockOut: Date {
    let cBreaks = model.breaks.map { brk in
      ShiftInterval(
        in_ts: Int64(brk.inDate.timeIntervalSince1970),
        out_ts: Int64(brk.outDate.timeIntervalSince1970),
      )
    }

    let inTs = model.clockInTime.timeIntervalSince1970
    let outTs = cBreaks.withUnsafeBufferPointer { buf in
      clockIn(
        Int64(model.shiftLength),
        Int64(inTs),
        buf.baseAddress,
        buf.count
      )
    }

    return Date(timeIntervalSince1970: TimeInterval(outTs))
  }

  init(updater: SPUUpdater, model: ShiftModel) {
    self.updater = updater
    self.model = model

    // Create our view model for our CheckForUpdatesView
    self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
  }

  var body: some View {
    VStack {
      Text("Shifty")
        .font(.system(size: 20))
        .padding(.vertical, 5)

      HStack {
        Text("Shift Length").bold()
        TextField("Shift Length", value: $model.shiftLength, format: .number)
          .frame(width: 20)
        Text(" hr")
      }

      DatePicker("Clock In", selection: $model.clockInTime, displayedComponents: .hourAndMinute)

      HStack {
        Text("Breaks").bold()
        Button(action: { model.breaks.append(Interval()) }) {
          Image(systemName: "plus")
        }
      }
      .padding(.vertical, 4)

      ForEach($model.breaks) { $brk in
        HStack {
          DatePicker("", selection: $brk.inDate, displayedComponents: .hourAndMinute)
            .labelsHidden()
          DatePicker("", selection: $brk.outDate, displayedComponents: .hourAndMinute)
            .labelsHidden()
          Button {
            let id = brk.id
            model.breaks.removeAll { $0.id == id }
          } label: {
            Image(systemName: "trash")
          }
          .buttonStyle(.borderless)
        }
        if !brk.isValid {
          HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Invalid break times")
          }
          .foregroundStyle(.red)
        }
      }

      HStack {
        Text("Clock Out:").bold()
        Text(clockOut, style: .time)
      }.padding()

      Divider()
      Button("Check for Updates", action: updater.checkForUpdates)
        .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
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
    .frame(width: 250)
  }
}

class AppDelegate: NSObject, NSApplicationDelegate {
  var popover: NSPopover!
  var item: NSStatusItem!
  let model = ShiftModel()

  private var updateController: SPUStandardUpdaterController!

  func applicationDidFinishLaunching(_ notification: Notification) {
    updateController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )

    NSApp.setActivationPolicy(.accessory)

    setupMenu()

    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    let symbol =
      NSImage(
        systemSymbolName: "clock.arrow.trianglehead.clockwise.rotte.90.path.dotted",
        accessibilityDescription: "Shifty")
      ?? NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Shifty")
    item.button?.image = symbol

    item.button?.action = #selector(toggle)

    popover = NSPopover()
    popover.contentViewController = NSHostingController(
      rootView: PopoverView(updater: updateController.updater, model: model))
    popover.behavior = .transient
  }

  @objc func toggle() {
    if popover.isShown {
      popover.close()
    } else {
      NSApp.activate(ignoringOtherApps: true)
      popover.show(
        relativeTo: item.button!.bounds, of: item.button!, preferredEdge: NSRectEdge.maxY)
    }
  }
}

func setupMenu() {
  let mainMenu = NSMenu()

  let appItem = NSMenuItem()
  mainMenu.addItem(appItem)
  let appMenu = NSMenu()
  appItem.submenu = appMenu
  appMenu.addItem(
    withTitle: "Quit Shifty",
    action: #selector(NSApplication.terminate(_:)),
    keyEquivalent: "q")

  let editItem = NSMenuItem()
  editItem.title = "Edit"
  mainMenu.addItem(editItem)
  let editMenu = NSMenu(title: "Edit")
  editItem.submenu = editMenu

  editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
  editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
  editMenu.addItem(.separator())
  editMenu.addItem(
    withTitle: "Cut", action: #selector(NSText.cut(_:)),
    keyEquivalent:
      "x")
  editMenu.addItem(
    withTitle: "Copy", action: #selector(NSText.copy(_:)),
    keyEquivalent:
      "c")
  editMenu.addItem(
    withTitle: "Paste", action: #selector(NSText.paste(_:)),
    keyEquivalent: "v")
  editMenu.addItem(
    withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
    keyEquivalent: "a")

  NSApp.mainMenu = mainMenu
}

private var appDelegate: AppDelegate?

@_cdecl("swiftuiInit")
public func swiftuiInit() {}

@_cdecl("swiftuiRun")
public func swiftuiRun() {
  let app = NSApplication.shared
  let delegate = AppDelegate()
  appDelegate = delegate  // retain
  app.delegate = delegate
  app.run()
}
