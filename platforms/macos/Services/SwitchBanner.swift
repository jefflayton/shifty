import AppKit
import SwiftUI

/// Auto-switch's offer, in a small panel at the top of the screen that
/// floats over everything without taking focus: what it's switching to, a
/// countdown, and buttons to switch now or keep the current project. After
/// a switch it says so, with Undo, for a moment.
@MainActor
final class SwitchBanner {
  private let model: AutoSwitchModel
  private var panel: NSPanel?
  private var timer: Timer?

  init(model: AutoSwitchModel) {
    self.model = model
  }

  /// Shows or hides the panel for the model's offer or switch.
  func update() {
    timer?.invalidate()
    timer = nil
    let due = model.offer?.deadline ?? model.switched?.until
    guard let due else {
      panel?.orderOut(nil)
      return
    }
    let panel = self.panel ?? makePanel()
    self.panel = panel
    place(panel)
    panel.orderFrontRegardless()
    // The model acts when its time's up; the watcher only looks every few
    // seconds.
    let timer = Timer(fire: due, interval: 0, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.model.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 64),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovableByWindowBackground = false
    let host = NSHostingView(rootView: SwitchBannerView(model: model))
    host.sizingOptions = [.intrinsicContentSize]
    panel.contentView = host
    return panel
  }

  /// Top center of the screen you're on, just under the menu bar.
  private func place(_ panel: NSPanel) {
    let mouse = NSEvent.mouseLocation
    guard
      let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    else { return }
    let size = panel.contentView?.fittingSize ?? panel.frame.size
    let visible = screen.visibleFrame
    panel.setFrame(
      NSRect(
        x: visible.midX - size.width / 2, y: visible.maxY - size.height - 10, width: size.width,
        height: size.height), display: true)
  }
}

struct SwitchBannerView: View {
  let model: AutoSwitchModel

  var body: some View {
    Group {
      if let offer = model.offer {
        HStack(spacing: 12) {
          Countdown(start: offer.deadline.addingTimeInterval(-model.preferences.autoSwitchCountdown),
            end: offer.deadline)
          VStack(alignment: .leading, spacing: 1) {
            Text("\(offer.starts ? "Starting" : "Switching to") \(Text(offer.name).bold())")
            Text("You're in \(offer.place)" + (offer.from.map { " · from \($0)" } ?? ""))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .lineLimit(1)
          Spacer(minLength: 8)
          Button(offer.from.map { "Keep \($0)" } ?? "Not Now") { model.keep() }
          Button(offer.starts ? "Start Now" : "Switch Now") { model.switchNow() }
            .buttonStyle(.borderedProminent)
        }
      } else if let switched = model.switched {
        HStack(spacing: 12) {
          Image(systemName: "arrow.triangle.swap")
            .font(.title3)
            .foregroundStyle(.tint)
            .frame(width: 30)
          VStack(alignment: .leading, spacing: 1) {
            Text("\(switched.started ? "Tracking" : "Switched to") \(Text(switched.name).bold())")
            Text("You're in \(switched.place)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .lineLimit(1)
          Spacer(minLength: 8)
          Button("Undo") { model.undoSwitch() }
          Button {
            model.dismissSwitched()
          } label: {
            Image(systemName: "xmark")
          }
          .buttonStyle(.borderless)
          .help("Dismiss")
        }
      }
    }
    .controlSize(.regular)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(minWidth: 420)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(.separator))
    .padding(8)
    .fixedSize()
  }
}

/// A ring that empties as the countdown runs, with the seconds left.
private struct Countdown: View {
  let start: Date
  let end: Date

  var body: some View {
    TimelineView(.animation(minimumInterval: 0.1)) { context in
      let total = max(1, end.timeIntervalSince(start))
      let left = max(0, end.timeIntervalSince(context.date))
      ZStack {
        Circle().stroke(.quaternary, lineWidth: 3)
        Circle()
          .trim(from: 0, to: left / total)
          .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
          .rotationEffect(.degrees(-90))
        Text("\(Int(left.rounded(.up)))")
          .font(.caption.monospacedDigit().bold())
      }
      .frame(width: 30, height: 30)
    }
  }
}
