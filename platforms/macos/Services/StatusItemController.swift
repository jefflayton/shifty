import AppKit
import Observation

/// Keeps the menu bar item's icon and text current: the break's icon while
/// you're on one (one you started, lunch, or one planned like a class), and
/// the clock-out time, time left, or time until break beside it.
@MainActor
final class StatusItemController {
  private let item: NSStatusItem
  private let model: ShiftModel
  private let preferences: Preferences
  private var timer: Timer?
  /// The break symbol shown, nil for the shift icon, and the text.
  private var shown: (symbol: String?, title: String?)?

  private static let shiftIcon =
    NSImage(
      systemSymbolName: "clock.arrow.trianglehead.clockwise.rotate.90.path.dotted",
      accessibilityDescription: "Shifty")
    ?? NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Shifty")

  /// A break's icon, else the cup, else the shift icon.
  private static func breakIcon(_ symbol: String) -> NSImage? {
    NSImage(systemSymbolName: symbol, accessibilityDescription: "Shifty, on break")
      ?? NSImage(systemSymbolName: BreakIcon.rest, accessibilityDescription: "Shifty, on break")
      ?? shiftIcon
  }

  init(item: NSStatusItem, model: ShiftModel, preferences: Preferences) {
    self.item = item
    self.model = model
    self.preferences = preferences
    observe()

    // Time left counts down, a break pushes clock out later, planned breaks
    // start and end, and the text goes away once the shift is over: none of
    // that changes the model.
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
    let symbol = breakSymbol(now: now)
    let title = preferences.menuBarDisplay.title(
      clockOut: model.clockOut(now: now), now: now, nextBreak: model.untilBreak(now: now),
      isClockedIn: model.isClockedIn)
    guard let button = item.button, shown?.symbol != symbol || shown?.title != title else {
      return
    }
    shown = (symbol, title)

    button.image = symbol.flatMap(Self.breakIcon) ?? Self.shiftIcon
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

  /// The icon of the break you're on: lunch's, a scheduled break's, or the
  /// one for breaks you start; nil off a break.
  private func breakSymbol(now: Date) -> String? {
    if model.isOnBreak {
      return model.isOnLunch(preferences.lunch, now: now)
        ? preferences.lunch.symbol : preferences.breakSymbol
    }
    guard
      let planned = model.anchoredBreaks().first(where: { $0.start <= now && now < $0.end })
    else { return nil }
    if model.lunch(preferences.lunch, now: now)?.lunch?.start == planned.start {
      return preferences.lunch.symbol
    }
    return preferences.scheduledBreak(start: planned.start, end: planned.end)?
      .symbol(rest: preferences.breakSymbol) ?? preferences.breakSymbol
  }
}
