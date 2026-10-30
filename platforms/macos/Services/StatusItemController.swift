import AppKit
import Observation

/// Keeps the menu bar item's icon and text current: a cup while you're on a
/// break, and the clock-out time or time left beside it.
@MainActor
final class StatusItemController {
  private let item: NSStatusItem
  private let model: ShiftModel
  private let preferences: Preferences
  private var timer: Timer?
  private var shown: (onBreak: Bool, title: String?)?

  private static let shiftIcon =
    NSImage(
      systemSymbolName: "clock.arrow.trianglehead.clockwise.rotate.90.path.dotted",
      accessibilityDescription: "Shifty")
    ?? NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Shifty")
  private static let breakIcon = NSImage(
    systemSymbolName: "cup.and.saucer", accessibilityDescription: "Shifty, on break")

  init(item: NSStatusItem, model: ShiftModel, preferences: Preferences) {
    self.item = item
    self.model = model
    self.preferences = preferences
    observe()

    // Time left counts down, a break pushes clock out later, and the text
    // goes away once the shift is over: none of that changes the model.
    let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.update() }
    }
    timer.tolerance = 5
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  /// Runs `update` now and again after any model property it read changes.
  private func observe() {
    withObservationTracking {
      update()
    } onChange: { [weak self] in
      Task { @MainActor in self?.observe() }
    }
  }

  private func update(now: Date = Date()) {
    let onBreak = model.isOnBreak
    let title = preferences.menuBarDisplay.title(clockOut: model.clockOut(now: now), now: now)
    guard let button = item.button, shown?.onBreak != onBreak || shown?.title != title else {
      return
    }
    shown = (onBreak, title)

    button.image = onBreak ? Self.breakIcon ?? Self.shiftIcon : Self.shiftIcon
    if let title {
      button.attributedTitle = NSAttributedString(
        string: title,
        attributes: [
          .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ])
      button.imagePosition = .imageLeading
    } else {
      button.title = ""
      button.imagePosition = .imageOnly
    }
  }
}
