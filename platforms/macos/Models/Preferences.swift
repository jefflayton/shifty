import Foundation
import Observation

/// What the menu bar item shows beside its icon.
enum MenuBarDisplay: String, CaseIterable, Identifiable {
  case iconOnly
  case clockOut
  /// The clock-out time until you pass it, then how far over you are.
  case clockOutThenOver
  case timeLeft
  case untilBreak

  var id: Self { self }

  var label: String {
    switch self {
    case .iconOnly: "Icon Only"
    case .clockOut: "Clock-Out Time"
    case .clockOutThenOver: "Clock-Out Time, Then Time Over"
    case .timeLeft: "Time Left"
    case .untilBreak: "Time Until Break"
    }
  }

  /// The text beside the icon, or nil for none. `nextBreak` is when the next
  /// break starts, or the one you're on ends; without one, time until break
  /// shows the time left. Past clock out, a shift you're clocked in to counts
  /// up ("+25m"), except plain clock-out time, which stays; a draft shows
  /// nothing.
  func title(clockOut: Date, now: Date, nextBreak: Date? = nil, isClockedIn: Bool = false)
    -> String?
  {
    guard clockOut > now else {
      guard isClockedIn else { return nil }
      switch self {
      case .iconOnly: return nil
      case .clockOut: return clockOut.formatted(date: .omitted, time: .shortened)
      case .clockOutThenOver, .timeLeft, .untilBreak:
        return "+" + Self.compact(now.timeIntervalSince(clockOut))
      }
    }
    switch self {
    case .iconOnly:
      return nil
    case .clockOut, .clockOutThenOver:
      return clockOut.formatted(date: .omitted, time: .shortened)
    case .timeLeft:
      return Self.compact(clockOut.timeIntervalSince(now))
    case .untilBreak:
      let next = nextBreak.flatMap { $0 > now ? $0 : nil } ?? clockOut
      return Self.compact(next.timeIntervalSince(now))
    }
  }

  /// "2h 15m", "45m". Rounds up, and never reads "0m", before clock out or
  /// past it.
  static func compact(_ seconds: TimeInterval) -> String {
    let minutes = max(1, Int((seconds / 60).rounded(.up)))
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

  /// Where you clock in, if it isn't the clock-out link. Shared through the
  /// store like that one.
  var separateClockInLink: URL? {
    didSet { if !loading { save(Self.clockInLinkSetting, separateClockInLink?.absoluteString) } }
  }

  /// What Clock In in the menu bar opens: its own link, else the clock-out
  /// link.
  var clockInLink: URL? { separateClockInLink ?? clockOutLink }

  /// Whether Clock In and Clock Out in the menu bar open the link too. Kept
  /// on this Mac.
  var clockLinkMode: ClockLinkMode {
    didSet { defaults.set(clockLinkMode.rawValue, forKey: Self.clockLinkModeKey) }
  }

  /// What to do with the link after `event` in the menu bar.
  func clockLinkAction(for event: ClockEvent) -> ClockLinkAction {
    event.isLunch
      ? lunchLinkAction(clockingIn: event.clockingIn)
      : clockLinkAction(clockingIn: event.clockingIn)
  }

  /// What to do with the link after starting (clocking out for) or ending
  /// (clocking back in from) lunch in the menu bar: as for clocking in or
  /// out, if lunch is on and offers the clock links.
  func lunchLinkAction(clockingIn: Bool) -> ClockLinkAction {
    guard lunch.active?.clockLink == true else { return .none }
    return clockLinkAction(clockingIn: clockingIn)
  }

  /// What to do with the link after clocking in or out from the menu bar.
  func clockLinkAction(clockingIn: Bool) -> ClockLinkAction {
    guard let link = clockingIn ? clockInLink : clockOutLink else { return .none }
    switch clockLinkMode {
    case .ask: return .ask(link)
    case .always: return .open(link)
    case .never: return .none
    }
  }

  /// The days you work, as ISO weekdays (1 is Monday, 7 Sunday). The
  /// timesheet hides the others unless there's time on them.
  var workDays: Set<Int> {
    didSet { save(Self.workDaysSetting, Self.format(workDays)) }
  }

  /// When to take lunch. Off until it's turned on. With the store, it's the
  /// window break preset; without, a setting.
  var lunch: LunchRule {
    didSet { if lunch != oldValue && !loading { saveLunch() } }
  }

  /// An SF Symbol for breaks you start from the menu bar, and scheduled ones
  /// with none of their own; nil for the cup. Shared through the store.
  var breakIcon: String? {
    didSet { if breakIcon != oldValue && !loading { save(Self.breakIconSetting, breakIcon) } }
  }

  /// The symbol a break you start yourself shows.
  var breakSymbol: String { BreakIcon.symbol(breakIcon, or: BreakIcon.rest) }

  /// The scheduled break a break on the clock is on its day, if any.
  func scheduledBreak(start: Date, end: Date?, calendar: Calendar = .current) -> ScheduledBreak? {
    scheduledBreaks.first { $0.matches(start: start, end: end, calendar: calendar) }
  }

  /// Breaks at set times on set days, put on each new day's shift. They
  /// need the store.
  var scheduledBreaks: [ScheduledBreak] = [] {
    didSet {
      if scheduledBreaks != oldValue && !loading { saveScheduled(was: oldValue) }
    }
  }

  /// How long Snooze puts off a ringing alarm. Shared through the store, so
  /// it follows the database rather than this Mac.
  var snoozeLength: TimeInterval {
    didSet { save(Self.snoozeSetting, Self.format(snooze: snoozeLength)) }
  }

  /// Whether there's a store to keep scheduled breaks in.
  var hasStore: Bool { store != nil }

  /// Whether the running timer follows the project linked to the repo,
  /// folder, or app you're working in. Kept on this Mac.
  var autoSwitch: Bool {
    didSet { defaults.set(autoSwitch, forKey: Self.autoSwitchKey) }
  }

  /// How long you stay somewhere linked to another project before Shifty
  /// offers to switch, so a quick look elsewhere doesn't.
  var autoSwitchDelay: TimeInterval {
    didSet { defaults.set(autoSwitchDelay, forKey: Self.autoSwitchDelayKey) }
  }

  /// How long the offer counts down before it switches.
  var autoSwitchCountdown: TimeInterval {
    didSet { defaults.set(autoSwitchCountdown, forKey: Self.autoSwitchCountdownKey) }
  }

  /// Whether a Teams meeting whose title has a project's keyword brings up
  /// an offer to switch to that project (and back, when it ends). It only
  /// offers, never switches by itself. Kept on this Mac.
  var meetingSwitch: Bool {
    didSet { defaults.set(meetingSwitch, forKey: Self.meetingSwitchKey) }
  }

  /// Whether Shifty runs Rex's `rex do` script (`RexFollow`) so auto
  /// switch follows the Rex tab and session you're on, remote ones too.
  /// Kept on this Mac.
  var followRex: Bool {
    didSet { defaults.set(followRex, forKey: Self.followRexKey) }
  }

  /// Rex hosts to follow besides this Mac's server: their labels from
  /// `rex hosts`, separated by commas or spaces. Kept on this Mac.
  var rexHosts: String {
    didSet { defaults.set(rexHosts, forKey: Self.rexHostsKey) }
  }

  static let autoSwitchDelays: [TimeInterval] = [10, 30, 60, 120, 300]
  static let autoSwitchCountdowns: [TimeInterval] = [5, 10, 15, 30]

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let store: ShiftStore?
  /// The lunch window's preset in the store.
  @ObservationIgnored private var lunchID: UUID?
  /// Set while reading the store, so what was read isn't written back.
  @ObservationIgnored private var loading = false
  static let menuBarDisplayKey = "menuBarDisplay"
  static let clockOutLinkKey = "clockOutLink"
  static let clockOutLinkSetting = "clock_out_link"
  static let clockInLinkSetting = "clock_in_link"
  static let clockLinkModeKey = "clockLinkMode"
  static let breakIconSetting = "break_icon"
  static let migratedKey = "clockOutLink.migratedToStore"
  static let autoSwitchKey = "autoSwitch"
  static let autoSwitchDelayKey = "autoSwitch.delay"
  static let autoSwitchCountdownKey = "autoSwitch.countdown"
  static let meetingSwitchKey = "autoSwitch.meetings"
  static let followRexKey = "autoSwitch.rex"
  static let rexHostsKey = "autoSwitch.rexHosts"
  static let workDaysSetting = "work_days"
  static let lunchSetting = "lunch"
  static let snoozeSetting = "snooze_secs"
  static let defaultSnooze: TimeInterval = 5 * 60
  /// One minute to an hour.
  static let snoozeRange: ClosedRange<TimeInterval> = 60...(60 * 60)
  static let everyDay = Set(1...7)

  init(defaults: UserDefaults = .standard, store: ShiftStore? = nil) {
    self.defaults = defaults
    self.store = store
    workDays = Self.load(Self.workDaysSetting, store: store, defaults: defaults)
      .flatMap(Self.workDays(from:)) ?? Self.everyDay
    lunch = LunchRule()
    snoozeLength = Self.load(Self.snoozeSetting, store: store, defaults: defaults)
      .flatMap(Self.snooze(from:)) ?? Self.defaultSnooze
    menuBarDisplay =
      defaults.string(forKey: Self.menuBarDisplayKey).flatMap(MenuBarDisplay.init) ?? .clockOut
    clockLinkMode =
      defaults.string(forKey: Self.clockLinkModeKey).flatMap(ClockLinkMode.init) ?? .ask
    separateClockInLink = Self.load(Self.clockInLinkSetting, store: store, defaults: defaults)
      .flatMap(Self.link(from:))
    autoSwitch = defaults.bool(forKey: Self.autoSwitchKey)
    autoSwitchDelay = defaults.object(forKey: Self.autoSwitchDelayKey) as? TimeInterval ?? 30
    autoSwitchCountdown =
      defaults.object(forKey: Self.autoSwitchCountdownKey) as? TimeInterval ?? 10
    meetingSwitch = defaults.object(forKey: Self.meetingSwitchKey) as? Bool ?? true
    followRex = defaults.bool(forKey: Self.followRexKey)
    rexHosts = defaults.string(forKey: Self.rexHostsKey) ?? ""
    breakIcon = Self.load(Self.breakIconSetting, store: store, defaults: defaults)
      .flatMap { $0.isEmpty ? nil : $0 }

    let saved = defaults.string(forKey: Self.clockOutLinkKey)
    guard let store else {
      lunch = defaults.string(forKey: Self.lunchSetting).flatMap(Self.lunch(from:)) ?? LunchRule()
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
    loadPresets()
  }

  /// Picks up settings changed from the TUI or CLI.
  func pull() {
    guard let store else { return }
    let days = Self.load(Self.workDaysSetting, store: store, defaults: defaults)
      .flatMap(Self.workDays(from:)) ?? Self.everyDay
    if days != workDays { workDays = days }
    let snooze = Self.load(Self.snoozeSetting, store: store, defaults: defaults)
      .flatMap(Self.snooze(from:)) ?? Self.defaultSnooze
    if snooze != snoozeLength { snoozeLength = snooze }
    let inLink = Self.load(Self.clockInLinkSetting, store: store, defaults: defaults)
      .flatMap(Self.link(from:))
    if inLink != separateClockInLink {
      loading = true
      separateClockInLink = inLink
      loading = false
    }
    let icon = Self.load(Self.breakIconSetting, store: store, defaults: defaults)
      .flatMap { $0.isEmpty ? nil : $0 }
    if icon != breakIcon {
      loading = true
      breakIcon = icon
      loading = false
    }
    loadPresets()
    do {
      let link = try store.setting(Self.clockOutLinkSetting).flatMap(Self.link(from:))
      if link != clockOutLink { clockOutLink = link }
    } catch {
      log("load clock-out link:", error)
    }
  }

  /// Reads the lunch window and scheduled breaks from the store, assigning
  /// only real changes.
  private func loadPresets() {
    guard let store else { return }
    loading = true
    defer { loading = false }
    do {
      let presets = try store.breakPresets()
      let window = presets.first { $0.kind == "window" }
      lunchID = window?.id
      let rule = window.flatMap(BreakPresets.lunch) ?? LunchRule()
      if rule != lunch { lunch = rule }
      // Ones still being typed in (not valid yet) aren't in the store.
      let stored = presets.compactMap(BreakPresets.scheduled)
      let pending = scheduledBreaks.filter { !$0.isValid }
      if stored + pending != scheduledBreaks { scheduledBreaks = stored + pending }
    } catch {
      log("load break presets:", error)
    }
  }

  private func saveLunch() {
    guard let store else {
      return defaults.set(Self.format(lunch), forKey: Self.lunchSetting)
    }
    let id = lunchID ?? UUID()
    do {
      try store.putBreakPreset(BreakPresets.row(lunch, id: id), name: "Lunch", icon: lunch.icon)
      lunchID = id
    } catch {
      log("save lunch:", error)
    }
  }

  private func saveScheduled(was old: [ScheduledBreak]) {
    guard let store else { return }
    let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    do {
      for brk in scheduledBreaks where brk.isValid && before[brk.id] != brk {
        try store.putBreakPreset(BreakPresets.row(brk), name: brk.name, icon: brk.icon)
      }
      let ids = Set(scheduledBreaks.filter(\.isValid).map(\.id))
      for brk in old where brk.isValid && !ids.contains(brk.id) {
        try store.deleteBreakPreset(brk.id)
      }
    } catch {
      log("save scheduled breaks:", error)
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

  /// Whole seconds, or nil for the default, so the setting is only stored
  /// once it's changed.
  static func format(snooze: TimeInterval) -> String? {
    snooze == defaultSnooze ? nil : String(Int(snooze.rounded()))
  }

  /// A snooze length in seconds, kept within `snoozeRange`; nil if it isn't
  /// a number.
  static func snooze(from text: String) -> TimeInterval? {
    guard let secs = Int(text.trimmingCharacters(in: .whitespaces)) else { return nil }
    return min(max(TimeInterval(secs), snoozeRange.lowerBound), snoozeRange.upperBound)
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

/// Whether clocking in or out from the menu bar opens the clock link.
enum ClockLinkMode: String, CaseIterable, Identifiable {
  case ask, always, never

  var id: Self { self }

  var label: String {
    switch self {
    case .ask: "Ask first"
    case .always: "Always"
    case .never: "Never"
    }
  }
}

enum ClockLinkAction: Equatable {
  case none
  case ask(URL)
  case open(URL)
}
