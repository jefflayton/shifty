import AppKit
import SwiftUI

/// Auto-switch's offer, in a small panel at the top of the screen that
/// floats over everything without taking focus: what it's switching to, a
/// countdown, and buttons to switch now or keep the current project. After
/// a switch it says so, with Undo, for a moment. A meeting's offer has no
/// countdown: it waits for you.
@MainActor
final class SwitchBanner {
  private let model: AutoSwitchModel
  private var panel: NSPanel?
  private var timer: Timer?
  /// The offer on screen, so its sound plays once, when it comes up.
  private var shown: AutoSwitchModel.Offer?
  /// Held while it plays.
  private var sound: NSSound?

  init(model: AutoSwitchModel) {
    self.model = model
  }

  /// Shows or hides the panel for the model's offer or switch.
  func update() {
    timer?.invalidate()
    timer = nil
    if let offer = model.offer, offer.target != shown?.target { chime() }
    shown = model.offer
    guard model.offer != nil || model.switched != nil else {
      panel?.orderOut(nil)
      return
    }
    let panel = self.panel ?? makePanel()
    self.panel = panel
    place(panel)
    panel.orderFrontRegardless()
    // The model acts when its time's up; the watcher only looks every few
    // seconds.
    guard let due = model.offer?.deadline ?? model.switched?.until else { return }
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
    // Kept out of screen shares, since a meeting's offer stays up during
    // the call.
    panel.sharingType = .none
    // The panel follows the banner's size as it's laid out: measuring when
    // the model changes reads the old text, and clips the new.
    let host = NSHostingView(
      rootView: SwitchBannerView(model: model) { [weak self] size in
        guard let self, let panel = self.panel, size != self.size else { return }
        self.size = size
        self.place(panel)
      })
    host.sizingOptions = []
    panel.contentView = host
    return panel
  }

  /// The offer's sound, `notification.caf`.
  private func chime() {
    guard let url = Bundle.main.url(forResource: "notification", withExtension: "caf"),
      let sound = NSSound(contentsOf: url, byReference: true)
    else { return }
    self.sound?.stop()
    self.sound = sound
    sound.play()
  }

  /// The banner's size, as last laid out.
  private var size: CGSize?

  /// Top center of the screen you're on, just under the menu bar.
  private func place(_ panel: NSPanel) {
    let mouse = NSEvent.mouseLocation
    guard
      let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    else { return }
    let size = self.size ?? panel.contentView?.fittingSize ?? panel.frame.size
    let visible = screen.visibleFrame
    panel.setFrame(
      NSRect(
        x: visible.midX - size.width / 2, y: visible.maxY - size.height - 10, width: size.width,
        height: size.height), display: true)
  }
}

struct SwitchBannerView: View {
  let model: AutoSwitchModel
  /// Its size whenever it changes, for the panel to fit.
  var resized: (CGSize) -> Void = { _ in }

  var body: some View {
    Group {
      if let offer = model.offer, offer.kind != .place {
        MeetingOfferView(model: model, offer: offer)
      } else if let offer = model.offer, let deadline = offer.deadline {
        HStack(spacing: 12) {
          Countdown(start: deadline.addingTimeInterval(-model.preferences.autoSwitchCountdown),
            end: deadline)
          VStack(alignment: .leading, spacing: 1) {
            Text("\(offer.starts ? "Starting" : "Switching to") \(Text(offer.name).bold())")
            Text("You're in \(offer.place)" + (offer.from.map { " · from \($0)" } ?? ""))
              .font(.caption)
              .foregroundStyle(.secondary)
              .truncationMode(.middle)
          }
          .lineLimit(1)
          .frame(maxWidth: 320, alignment: .leading)
          Spacer(minLength: 8)
          Button(offer.from.map { "Keep \($0)" } ?? "Not Now") { model.keep() }
            .lineLimit(1)
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
              .truncationMode(.middle)
          }
          .lineLimit(1)
          .frame(maxWidth: 320, alignment: .leading)
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
    .onGeometryChange(for: CGSize.self) { $0.size } action: { resized($0) }
  }
}

/// A meeting's offer, or the offer to go back once it ends: no countdown,
/// since it waits for you.
private struct MeetingOfferView: View {
  let model: AutoSwitchModel
  let offer: AutoSwitchModel.Offer

  private var over: Bool { offer.kind == .meetingOver }

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: over ? "arrow.uturn.backward" : "video")
        .font(.title3)
        .foregroundStyle(.tint)
        .frame(width: 30)
      VStack(alignment: .leading, spacing: 1) {
        if over {
          Text("Back to \(Text(offer.name).bold())?")
        } else {
          Text("\(offer.starts ? "Start" : "Switch to") \(Text(offer.name).bold())?")
        }
        Text((over ? offer.place : "In \(offer.place)") + (offer.from.map { " · from \($0)" } ?? ""))
          .font(.caption)
          .foregroundStyle(.secondary)
          .truncationMode(.middle)
      }
      .lineLimit(1)
      .frame(maxWidth: 320, alignment: .leading)
      Spacer(minLength: 8)
      Button(offer.from.map { "Keep \($0)" } ?? "Not Now") { model.keep() }
        .lineLimit(1)
      Button(over ? "Switch Back" : offer.starts ? "Start" : "Switch") { model.switchNow() }
        .buttonStyle(.borderedProminent)
    }
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
