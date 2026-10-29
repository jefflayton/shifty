import Foundation

/// Places time-of-day pickers onto the actual shift. The pickers only edit
/// hours and minutes, so the day each stored Date carries is meaningless;
/// these mirror core `time.calc`, which works on times of day.
enum ShiftTimes {
  static let maxBreak: TimeInterval = 12 * 60 * 60

  /// `time`'s hour and minute on `day`'s calendar day.
  static func on(_ day: Date, timeOf time: Date, calendar: Calendar = .current) -> Date {
    let hm = calendar.dateComponents([.hour, .minute], from: time)
    return calendar.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: day)
      ?? day
  }

  static func nextDay(_ date: Date, calendar: Calendar = .current) -> Date {
    calendar.date(byAdding: .day, value: 1, to: date) ?? date
  }

  /// A break as absolute dates. One whose end is before its start crosses
  /// midnight, and one that ends before clock in falls on the next day.
  static func anchor(
    _ brk: Interval, clockIn: Date, calendar: Calendar = .current
  ) -> (start: Date, end: Date) {
    var start = on(clockIn, timeOf: brk.inDate, calendar: calendar)
    var end = on(clockIn, timeOf: brk.outDate, calendar: calendar)
    if end < start { end = nextDay(end, calendar: calendar) }
    if end <= clockIn {
      start = nextDay(start, calendar: calendar)
      end = nextDay(end, calendar: calendar)
    }
    return (start, end)
  }

  /// Breaks are invalid if empty or implausibly long (most likely the
  /// start and end were swapped, which would otherwise read as a ~23h break).
  static func isValid(_ brk: Interval, calendar: Calendar = .current) -> Bool {
    let (start, end) = anchor(brk, clockIn: brk.inDate, calendar: calendar)
    let length = end.timeIntervalSince(start)
    return length > 0 && length <= maxBreak
  }

  /// `time`'s hour and minute at the first occurrence at or after `clockIn`
  /// (to the minute).
  static func anchor(time: Date, clockIn: Date, calendar: Calendar = .current) -> Date {
    let date = on(clockIn, timeOf: time, calendar: calendar)
    let floor = on(clockIn, timeOf: clockIn, calendar: calendar)
    return date < floor ? nextDay(date, calendar: calendar) : date
  }
}

/// Geometry and labels for the popover's shift summary.
enum ShiftSummary {
  /// Valid breaks clipped to the shift and merged where they overlap, as
  /// fractions (0...1) of the clock-in to clock-out span.
  static func breakSpans(
    _ breaks: [Interval], clockIn: Date, clockOut: Date, calendar: Calendar = .current
  ) -> [ClosedRange<Double>] {
    let total = clockOut.timeIntervalSince(clockIn)
    guard total > 0 else { return [] }

    let clipped = breaks.filter { ShiftTimes.isValid($0, calendar: calendar) }
      .map { ShiftTimes.anchor($0, clockIn: clockIn, calendar: calendar) }
      .map { (max($0.start, clockIn), min($0.end, clockOut)) }
      .filter { $0.0 < $0.1 }
      .sorted { $0.0 < $1.0 }

    var merged: [(Date, Date)] = []
    for (start, end) in clipped {
      if let last = merged.last, start <= last.1 {
        merged[merged.count - 1].1 = max(last.1, end)
      } else {
        merged.append((start, end))
      }
    }
    return merged.map {
      ($0.0.timeIntervalSince(clockIn) / total)...($0.1.timeIntervalSince(clockIn) / total)
    }
  }

  /// Total break time inside the shift, in seconds.
  static func breakSeconds(
    _ breaks: [Interval], clockIn: Date, clockOut: Date, calendar: Calendar = .current
  ) -> TimeInterval {
    let total = clockOut.timeIntervalSince(clockIn)
    return breakSpans(breaks, clockIn: clockIn, clockOut: clockOut, calendar: calendar)
      .reduce(0) { $0 + ($1.upperBound - $1.lowerBound) * total }
  }

  /// "45 min", "2 hr", "1 hr 5 min" (rounded to the minute).
  static func duration(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int((seconds / 60).rounded()))
    let (h, m) = (minutes / 60, minutes % 60)
    switch (h, m) {
    case (0, _): return "\(m) min"
    case (_, 0): return "\(h) hr"
    default: return "\(h) hr \(m) min"
    }
  }

  /// When clock out is relative to now: "in 3 hr 12 min", "now", "12 min ago".
  static func relative(_ clockOut: Date, now: Date) -> String {
    let seconds = clockOut.timeIntervalSince(now)
    if abs(seconds) < 60 { return "now" }
    return seconds > 0 ? "in \(duration(seconds))" : "\(duration(-seconds)) ago"
  }
}
