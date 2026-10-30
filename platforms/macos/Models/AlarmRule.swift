import Foundation

/// A user-configured alarm. Clock-out alarms are rules, not fixed times:
/// they follow the computed clock out, so adding a break moves them later.
struct AlarmRule: Identifiable, Codable, Equatable {
  enum Trigger: Codable, Equatable {
    /// Rings `minutes` before clock out; 0 rings at clock out.
    case beforeClockOut(minutes: Int)
    /// Rings at a fixed time of day during the shift.
    case atTime(Date)
  }

  var id = UUID()
  var trigger: Trigger
  var isEnabled = true

  func fireDate(clockIn: Date, clockOut: Date, calendar: Calendar = .current) -> Date {
    switch trigger {
    case .beforeClockOut(let minutes):
      clockOut.addingTimeInterval(-TimeInterval(minutes) * 60)
    case .atTime(let time):
      ShiftTimes.anchor(time: time, clockIn: clockIn, calendar: calendar)
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
