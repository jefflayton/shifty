import Foundation

/// Something done in the menu bar that may call for punching the timeclock
/// too.
enum ClockEvent: Equatable {
  case clockIn
  case clockOut
  /// Started lunch, which is clocked out for.
  case lunchStarts
  /// Back from lunch: clock back in.
  case lunchEnds

  /// Whether it opens the clock-in link rather than the clock-out one.
  var clockingIn: Bool { self == .clockIn || self == .lunchEnds }

  var isLunch: Bool { self == .lunchStarts || self == .lunchEnds }

  /// What the prompt asks.
  var question: String {
    switch self {
    case .clockIn: "Clock in on your timeclock too?"
    case .clockOut: "Clock out on your timeclock too?"
    case .lunchStarts: "Clock out for lunch on your timeclock too?"
    case .lunchEnds: "Clock back in from lunch on your timeclock too?"
    }
  }
}
