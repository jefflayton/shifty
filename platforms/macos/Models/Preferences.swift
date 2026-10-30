import Foundation
import Observation

/// What the menu bar item shows beside its icon.
enum MenuBarDisplay: String, CaseIterable, Identifiable {
  case iconOnly
  case clockOut
  case timeLeft

  var id: Self { self }

  var label: String {
    switch self {
    case .iconOnly: "Icon Only"
    case .clockOut: "Clock-Out Time"
    case .timeLeft: "Time Left"
    }
  }

  /// The text beside the icon, or nil for none. A finished shift shows none.
  func title(clockOut: Date, now: Date) -> String? {
    guard clockOut > now else { return nil }
    switch self {
    case .iconOnly:
      return nil
    case .clockOut:
      return clockOut.formatted(date: .omitted, time: .shortened)
    case .timeLeft:
      return Self.compact(clockOut.timeIntervalSince(now))
    }
  }

  /// "2h 15m", "45m". Rounds up, so it never reads "0m" before clock out.
  static func compact(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int((seconds / 60).rounded(.up)))
    let (h, m) = (minutes / 60, minutes % 60)
    return h == 0 ? "\(m)m" : "\(h)h \(m)m"
  }
}

/// App settings, as opposed to the shift itself.
@Observable final class Preferences {
  var menuBarDisplay: MenuBarDisplay {
    didSet { defaults.set(menuBarDisplay.rawValue, forKey: Self.menuBarDisplayKey) }
  }

  @ObservationIgnored private let defaults: UserDefaults
  static let menuBarDisplayKey = "menuBarDisplay"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    menuBarDisplay =
      defaults.string(forKey: Self.menuBarDisplayKey).flatMap(MenuBarDisplay.init) ?? .clockOut
  }
}
