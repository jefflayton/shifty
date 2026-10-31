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

  /// Where you clock out, like a timeclock page. Alarms show a button that
  /// opens it. Shared through the store, so the TUI and CLI can use it too.
  var clockOutLink: URL? {
    didSet {
      if let store {
        do {
          try store.setSetting(Self.clockOutLinkSetting, clockOutLink?.absoluteString)
        } catch {
          log("save clock-out link:", error)
        }
      } else {
        defaults.set(clockOutLink?.absoluteString, forKey: Self.clockOutLinkKey)
      }
    }
  }

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let store: ShiftStore?
  static let menuBarDisplayKey = "menuBarDisplay"
  static let clockOutLinkKey = "clockOutLink"
  static let clockOutLinkSetting = "clock_out_link"
  static let migratedKey = "clockOutLink.migratedToStore"

  init(defaults: UserDefaults = .standard, store: ShiftStore? = nil) {
    self.defaults = defaults
    self.store = store
    menuBarDisplay =
      defaults.string(forKey: Self.menuBarDisplayKey).flatMap(MenuBarDisplay.init) ?? .clockOut

    let saved = defaults.string(forKey: Self.clockOutLinkKey)
    guard let store else {
      clockOutLink = saved.flatMap(Self.link(from:))
      return
    }
    do {
      // A link saved before the store moves into it once.
      if !defaults.bool(forKey: Self.migratedKey) {
        if let saved, try store.setting(Self.clockOutLinkSetting) == nil {
          try store.setSetting(Self.clockOutLinkSetting, saved)
        }
        defaults.set(true, forKey: Self.migratedKey)
      }
      clockOutLink = try store.setting(Self.clockOutLinkSetting).flatMap(Self.link(from:))
    } catch {
      log("load clock-out link:", error)
      clockOutLink = saved.flatMap(Self.link(from:))
    }
  }

  /// Picks up a link changed from the TUI or CLI.
  func pull() {
    guard let store else { return }
    do {
      let link = try store.setting(Self.clockOutLinkSetting).flatMap(Self.link(from:))
      if link != clockOutLink { clockOutLink = link }
    } catch {
      log("load clock-out link:", error)
    }
  }

  /// The link typed into settings, or nil if it isn't one. A bare
  /// "example.com/clock" gets https.
  static func link(from text: String) -> URL? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
    let full = text.contains("://") || text.hasPrefix("mailto:") ? text : "https://\(text)"
    guard let url = URL(string: full), let scheme = url.scheme, !scheme.isEmpty else { return nil }
    if ["http", "https"].contains(scheme.lowercased()), url.host()?.isEmpty ?? true {
      return nil
    }
    return url
  }
}
