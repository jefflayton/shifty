import Foundation

/// When lunch has to happen, counted in time worked. California, for one,
/// requires an unpaid meal break to start before the end of the fifth hour
/// of work; this lets you set your own window instead of building in one
/// state's rules.
struct LunchRule: Codable, Equatable {
  var isEnabled = false
  /// Worked time before lunch is worth taking.
  var earliest: TimeInterval = 3 * 3600
  /// Worked time lunch has to start by.
  var latest: TimeInterval = 5 * 3600
  /// Shorter breaks are rests, not lunch.
  var minimum: TimeInterval = 30 * 60
  /// Worked time to be reminded at, or nil for no reminder.
  var remindAt: TimeInterval? = 4 * 3600

  init() {}

  /// The rule, if it's on and makes sense.
  var active: LunchRule? {
    isEnabled && earliest >= 0 && earliest < latest && minimum > 0 ? self : nil
  }

  /// Where lunch falls on a shift, or nil if it's too short to need one.
  /// - Parameters:
  ///   - worked: the shift's work, not counting breaks: its length while
  ///     you're on it, what you actually worked once it's over.
  ///   - breaks: its breaks; the one in progress has no end.
  func plan(clockIn: Date, worked: TimeInterval, breaks: [LunchPlan.Span], now: Date) -> LunchPlan? {
    guard worked > latest else { return nil }
    let sorted = breaks.sorted { $0.start < $1.start }
    // The first break long enough to be lunch, or the one you're on.
    let lunch = sorted.first { b in
      b.end.map { $0.timeIntervalSince(b.start) >= minimum } ?? true
    }
    // Breaks before lunch push the window later; lunch itself doesn't.
    let before = sorted.filter { b in lunch.map { b.start < $0.start } ?? true }
      .map { ($0.start, $0.end ?? max(now, $0.start)) }
    return LunchPlan(
      opens: ShiftTimes.afterWork(earliest, clockIn: clockIn, breaks: before),
      closes: ShiftTimes.afterWork(latest, clockIn: clockIn, breaks: before),
      lunch: lunch,
      remind: lunch == nil
        ? remindAt.map { ShiftTimes.afterWork($0, clockIn: clockIn, breaks: before) } : nil)
  }

  // Stored as whole minutes, so the TUI and CLI can read it without
  // fractions.
  private enum CodingKeys: String, CodingKey {
    case isEnabled = "enabled"
    case earliest = "earliest_mins"
    case latest = "latest_mins"
    case minimum = "minimum_mins"
    case remindAt = "remind_mins"
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = LunchRule()
    isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
    func minutes(_ key: CodingKeys) throws -> TimeInterval? {
      try c.decodeIfPresent(Int.self, forKey: key).map { TimeInterval($0 * 60) }
    }
    earliest = try minutes(.earliest) ?? defaults.earliest
    latest = try minutes(.latest) ?? defaults.latest
    minimum = try minutes(.minimum) ?? defaults.minimum
    remindAt = try minutes(.remindAt)
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    func minutes(_ t: TimeInterval) -> Int { Int((t / 60).rounded()) }
    try c.encode(isEnabled, forKey: .isEnabled)
    try c.encode(minutes(earliest), forKey: .earliest)
    try c.encode(minutes(latest), forKey: .latest)
    try c.encode(minutes(minimum), forKey: .minimum)
    try c.encodeIfPresent(remindAt.map(minutes), forKey: .remindAt)
  }
}

/// Lunch on one shift: the window it has to start in, and the break that
/// was lunch, if there's been one.
struct LunchPlan: Equatable {
  struct Span: Equatable {
    var start: Date
    /// nil while it's running.
    var end: Date?
  }

  var opens: Date
  var closes: Date
  var lunch: Span?
  /// When to remind you, until you've had lunch.
  var remind: Date?

  enum Status: Equatable {
    /// The window hasn't opened yet.
    case upcoming
    /// Time to take lunch.
    case open
    /// On lunch now.
    case onLunch
    case taken
    /// Lunch started after the window closed.
    case late
    /// The window closed with no lunch.
    case missed
  }

  func status(now: Date) -> Status {
    if let lunch {
      if lunch.end == nil { return .onLunch }
      return lunch.start > closes ? .late : .taken
    }
    if now < opens { return .upcoming }
    return now < closes ? .open : .missed
  }
}

extension ShiftTimes {
  /// When `seconds` of work since `clockIn` is done, with `breaks` not
  /// counting as work. The core's clock-out calculation, with any length.
  static func afterWork(_ seconds: TimeInterval, clockIn start: Date, breaks: [(Date, Date)])
    -> Date
  {
    let intervals = breaks.map {
      ShiftInterval(
        in_ts: Int64($0.0.timeIntervalSince1970), out_ts: Int64($0.1.timeIntervalSince1970))
    }
    let out = intervals.withUnsafeBufferPointer { buf in
      // The core's C function; the parameter is `start` so it isn't shadowed.
      clockIn(Int64(seconds.rounded()), Int64(start.timeIntervalSince1970), buf.baseAddress, buf.count)
    }
    return Date(timeIntervalSince1970: TimeInterval(out))
  }
}
