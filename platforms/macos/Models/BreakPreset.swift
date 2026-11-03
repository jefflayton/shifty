import Foundation

/// A break at set times on set days, like a class on Tuesdays and Thursdays
/// from 11 to 2. It goes on the shift when a new day's shift starts, as an
/// ordinary break you can move or delete for that day. Stored in the shared
/// store as a scheduled break preset, beside the lunch window (a window
/// preset), so the TUI and CLI clock in with it too.
struct ScheduledBreak: Identifiable, Equatable {
  var id = UUID()
  var name = "Break"
  /// ISO weekdays (1 is Monday, 7 Sunday).
  var weekdays: Set<Int> = [1, 2, 3, 4, 5]
  /// Local time of day, in seconds since midnight.
  var start: TimeInterval = 12 * 3600
  var end: TimeInterval = 12.5 * 3600
  var isEnabled = true

  /// Whether the store will take it: it ends after it starts, the same day.
  var isValid: Bool { start >= 0 && start < 86400 && end > start && end <= 86400 }

  /// "11:00 AM – 2:00 PM"
  func times(calendar: Calendar = .current) -> String {
    let day = calendar.startOfDay(for: Date())
    return (day.addingTimeInterval(start)..<day.addingTimeInterval(end))
      .formatted(.interval.hour().minute())
  }
}

/// Converting presets to and from the store's rows.
enum BreakPresets {
  /// ISO weekdays as the store's bits: bit 0 is Monday, bit 6 Sunday.
  static func mask(_ days: Set<Int>) -> Int32 {
    days.filter { (1...7).contains($0) }.reduce(0) { $0 | (1 << ($1 - 1)) }
  }

  static func days(_ mask: Int) -> Set<Int> {
    Set((1...7).filter { mask & (1 << ($0 - 1)) != 0 })
  }

  static func scheduled(_ p: ShiftStore.Preset) -> ScheduledBreak? {
    guard p.kind == "scheduled", let start = p.startSecs, let end = p.endSecs else { return nil }
    return ScheduledBreak(
      id: p.id, name: p.name, weekdays: days(p.weekdays), start: TimeInterval(start),
      end: TimeInterval(end), isEnabled: p.enabled)
  }

  static func lunch(_ p: ShiftStore.Preset) -> LunchRule? {
    guard p.kind == "window", let earliest = p.earliestSecs, let latest = p.latestSecs,
      let minimum = p.minimumSecs
    else { return nil }
    var rule = LunchRule()
    rule.isEnabled = p.enabled
    rule.earliest = TimeInterval(earliest)
    rule.latest = TimeInterval(latest)
    rule.minimum = TimeInterval(minimum)
    return rule
  }

  static func row(_ b: ScheduledBreak) -> ShiftyBreakPreset {
    var row = ShiftyBreakPreset()
    row.id = ShiftyId(b.id)
    row.kind = Int32(SHIFTY_PRESET_SCHEDULED.rawValue)
    row.enabled = b.isEnabled ? 1 : 0
    row.weekdays = mask(b.weekdays)
    row.start_secs = Int64(b.start.rounded())
    row.end_secs = Int64(b.end.rounded())
    return row
  }

  static func row(_ rule: LunchRule, id: UUID) -> ShiftyBreakPreset {
    var row = ShiftyBreakPreset()
    row.id = ShiftyId(id)
    row.kind = Int32(SHIFTY_PRESET_WINDOW.rawValue)
    row.enabled = rule.isEnabled ? 1 : 0
    row.weekdays = 0b111_1111
    row.earliest_secs = Int64(rule.earliest.rounded())
    row.latest_secs = Int64(rule.latest.rounded())
    row.minimum_secs = Int64(rule.minimum.rounded())
    return row
  }
}
