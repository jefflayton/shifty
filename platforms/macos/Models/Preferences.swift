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

  /// The days you work, as ISO weekdays (1 is Monday, 7 Sunday). The
  /// timesheet hides the others unless there's time on them.
  var workDays: Set<Int> {
    didSet { save(Self.workDaysSetting, Self.format(workDays)) }
  }

  /// When to take lunch. Off until it's turned on.
  var lunch: LunchRule {
    didSet { save(Self.lunchSetting, Self.format(lunch)) }
  }

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let store: ShiftStore?
  static let menuBarDisplayKey = "menuBarDisplay"
  static let clockOutLinkKey = "clockOutLink"
  static let clockOutLinkSetting = "clock_out_link"
  static let migratedKey = "clockOutLink.migratedToStore"
  static let workDaysSetting = "work_days"
  static let lunchSetting = "lunch"
  static let everyDay = Set(1...7)

  init(defaults: UserDefaults = .standard, store: ShiftStore? = nil) {
    self.defaults = defaults
    self.store = store
    workDays = Self.load(Self.workDaysSetting, store: store, defaults: defaults)
      .flatMap(Self.workDays(from:)) ?? Self.everyDay
    lunch = Self.load(Self.lunchSetting, store: store, defaults: defaults)
      .flatMap(Self.lunch(from:)) ?? LunchRule()
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

  /// Picks up settings changed from the TUI or CLI.
  func pull() {
    guard let store else { return }
    let days = Self.load(Self.workDaysSetting, store: store, defaults: defaults)
      .flatMap(Self.workDays(from:)) ?? Self.everyDay
    if days != workDays { workDays = days }
    let rule = Self.load(Self.lunchSetting, store: store, defaults: defaults)
      .flatMap(Self.lunch(from:)) ?? LunchRule()
    if rule != lunch { lunch = rule }
    do {
      let link = try store.setting(Self.clockOutLinkSetting).flatMap(Self.link(from:))
      if link != clockOutLink { clockOutLink = link }
    } catch {
      log("load clock-out link:", error)
    }
  }

  /// Whether `day` is one you work.
  func isWorkDay(_ day: Date, calendar: Calendar = .current) -> Bool {
    workDays.contains(Self.isoWeekday(day, calendar: calendar))
  }

  /// 1 for Monday through 7 for Sunday, whatever day the calendar's week
  /// starts on.
  static func isoWeekday(_ day: Date, calendar: Calendar = .current) -> Int {
    (calendar.component(.weekday, from: day) + 5) % 7 + 1
  }

  /// ISO weekdays starting at the calendar's first day of the week.
  static func weekOrder(_ calendar: Calendar = .current) -> [Int] {
    let first = (calendar.firstWeekday + 5) % 7 + 1
    return (0..<7).map { (first - 1 + $0) % 7 + 1 }
  }

  /// "1,2,3,4,5"; nil for every day, the default.
  static func format(_ days: Set<Int>) -> String? {
    days == everyDay ? nil : days.sorted().map(String.init).joined(separator: ",")
  }

  static func workDays(from text: String) -> Set<Int>? {
    let days = text.split(separator: ",").compactMap {
      Int($0.trimmingCharacters(in: .whitespaces))
    }
    let valid = Set(days.filter { (1...7).contains($0) })
    return valid.isEmpty && !text.isEmpty ? nil : valid
  }

  static func format(_ rule: LunchRule) -> String? {
    guard rule != LunchRule(), let data = try? JSONEncoder().encode(rule) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  static func lunch(from text: String) -> LunchRule? {
    try? JSONDecoder().decode(LunchRule.self, from: Data(text.utf8))
  }

  /// A setting from the store, or UserDefaults without one.
  private static func load(_ key: String, store: ShiftStore?, defaults: UserDefaults) -> String? {
    guard let store else { return defaults.string(forKey: key) }
    do {
      return try store.setting(key)
    } catch {
      log("load \(key):", error)
      return nil
    }
  }

  /// Saves a setting to the store, or UserDefaults without one. nil
  /// removes it.
  private func save(_ key: String, _ value: String?) {
    guard let store else { return defaults.set(value, forKey: key) }
    do {
      try store.setSetting(key, value)
    } catch {
      log("save \(key):", error)
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
