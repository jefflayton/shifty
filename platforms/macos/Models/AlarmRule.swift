import Foundation

/// A user-configured alarm. Clock-out alarms are rules, not fixed times:
/// they follow the computed clock out, so adding a break moves them later.
struct AlarmRule: Identifiable, Codable, Equatable {
  enum Trigger: Codable, Equatable {
    /// Rings `minutes` before clock out; 0 rings at clock out.
    case beforeClockOut(minutes: Int)
    /// Rings at a fixed time of day during the shift.
    case atTime(Date)
    /// Rings when the lunch window opens.
    case lunchOpens
    /// Rings `minutes` before the lunch window closes.
    case beforeLunchCloses(minutes: Int)
  }

  var id = UUID()
  var trigger: Trigger
  var isEnabled = true

  /// When it rings on this shift. A lunch alarm doesn't ring without a
  /// lunch window, or once you've had lunch (or are on a break).
  func fireDate(
    clockIn: Date, clockOut: Date, lunch: LunchPlan? = nil, calendar: Calendar = .current
  ) -> Date? {
    switch trigger {
    case .beforeClockOut(let minutes):
      return clockOut.addingTimeInterval(-TimeInterval(minutes) * 60)
    case .atTime(let time):
      return ShiftTimes.anchor(time: time, clockIn: clockIn, calendar: calendar)
    case .lunchOpens:
      guard let lunch, lunch.lunch == nil else { return nil }
      return lunch.opens
    case .beforeLunchCloses(let minutes):
      guard let lunch, lunch.lunch == nil else { return nil }
      return lunch.closes.addingTimeInterval(-TimeInterval(minutes) * 60)
    }
  }

  var isLunch: Bool {
    switch trigger {
    case .lunchOpens, .beforeLunchCloses: true
    case .beforeClockOut, .atTime: false
    }
  }

  /// Whether it rings relative to clock out, which isn't known while you're
  /// on a break.
  var followsClockOut: Bool {
    if case .beforeClockOut = trigger { true } else { false }
  }

  var title: String {
    switch trigger {
    case .beforeClockOut(0): "Time to clock out"
    case .beforeClockOut(let minutes): "\(minutes) min until clock out"
    case .atTime: "Shifty alarm"
    case .lunchOpens: "Time for lunch"
    case .beforeLunchCloses(0): "Lunch window closing"
    case .beforeLunchCloses(let minutes): "\(minutes) min left to start lunch"
    }
  }
}

/// What an alarm sync should do with one rule's pending alarm.
enum AlarmAction: Equatable {
  /// (Re)schedule at this date.
  case schedule(Date)
  /// Drop any pending alarm, but leave a ringing or snoozed one alone.
  case cancelPending
  /// Already scheduled for the right time.
  case keep
}

enum AlarmPlanner {
  /// Decides how to bring one enabled rule's pending alarm in line with its
  /// current fire date. Past fire dates are never scheduled: an alarm that
  /// already rang stays quiet unless clock out moves later than now. A
  /// `held` alarm (one that follows clock out, during a break) waits until
  /// the break ends and clock out is known again.
  static func action(
    fireDate: Date, pending: Date?, snoozed: Bool, held: Bool = false, now: Date
  ) -> AlarmAction {
    if held || fireDate <= now { return snoozed ? .keep : .cancelPending }
    return pending == fireDate ? .keep : .schedule(fireDate)
  }
}
