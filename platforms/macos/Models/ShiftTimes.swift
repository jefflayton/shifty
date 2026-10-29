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
