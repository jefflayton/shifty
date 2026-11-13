import Foundation
import Observation

/// The shift the popover shows. Until you clock in it's a draft, a
/// calculator kept in UserDefaults. Once you clock in (here, in the TUI, or
/// with the CLI) it's the open shift in the shared store: edits write
/// through, and `pull` brings in changes made elsewhere.
@Observable class ShiftModel {
  var clockInTime = Date()
  var shiftLength = 8.0
  var breaks: [Interval] = []
  var alarms: [AlarmRule] = []
  /// When the break in progress started, if you're on one. It counts up to
  /// now until it ends and joins `breaks`.
  var breakStart: Date?
  /// The break in progress keeps this id once it ends, so the store sees one
  /// break, not one deleted and another added.
  @ObservationIgnored var breakStartID = UUID()
  /// The store's open shift, while clocked in.
  var shiftID: UUID?
  /// The lunch window, kept up with the settings. Until you've taken lunch,
  /// clock out counts its minimum for it.
  var lunchRule: LunchRule?

  @ObservationIgnored var store: ShiftStore?

  var isOnBreak: Bool { breakStart != nil }
  var isClockedIn: Bool { shiftID != nil }

  /// A shift whose clock out is this far in the past is over.
  static let staleAfter: TimeInterval = 12 * 60 * 60

  var clockOut: Date { clockOut(now: Date()) }

  /// Clock out if the break in progress (if any) ended at `now`, with lunch
  /// still to come counted as `lunchAhead`.
  func clockOut(now: Date) -> Date {
    workedOut(now: now).addingTimeInterval(lunchAhead(now: now))
  }

  /// Lunch time clock out counts before you've had it: the lunch window's
  /// minimum until you take lunch, then what's left of it while you're on
  /// it, then nothing. None when the window is off or the shift doesn't need
  /// lunch.
  func lunchAhead(now: Date) -> TimeInterval {
    guard let rule = lunchRule?.active, let plan = lunch(rule, now: now) else { return 0 }
    guard let lunch = plan.lunch else { return rule.minimum }
    guard lunch.end == nil else { return 0 }
    return max(0, rule.minimum - now.timeIntervalSince(lunch.start))
  }

  /// Clock out from the work and breaks so far, with no lunch to come.
  private func workedOut(now: Date) -> Date {
    let intervals = breaks(now: now).filter(\.isValid).map { brk in
      let (start, end) = ShiftTimes.anchor(brk, clockIn: clockInTime)
      return ShiftInterval(
        in_ts: Int64(start.timeIntervalSince1970),
        out_ts: Int64(end.timeIntervalSince1970)
      )
    }

    let outTs = intervals.withUnsafeBufferPointer { buf in
      clockIn(
        Int64(shiftLength * 60 * 60),
        Int64(clockInTime.timeIntervalSince1970),
        buf.baseAddress,
        buf.count
      )
    }
    return Date(timeIntervalSince1970: TimeInterval(outTs))
  }

  /// Where lunch falls on this shift under `rule`, or nil if it doesn't
  /// need one.
  func lunch(_ rule: LunchRule?, now: Date) -> LunchPlan? {
    guard let rule = rule?.active else { return nil }
    var spans = breaks.filter(\.isValid).map { brk in
      let (start, end) = ShiftTimes.anchor(brk, clockIn: clockInTime)
      return LunchPlan.Span(start: start, end: end)
    }
    if let breakStart { spans.append(.init(start: breakStart, end: nil)) }
    return rule.plan(clockIn: clockInTime, worked: shiftLength * 3600, breaks: spans, now: now)
  }

  /// Whether the break you're on now is lunch under `rule`: the first break
  /// long enough to be, or the one you're on if none before it was. False
  /// off a break, or when the shift doesn't need lunch.
  /// This week against the weekly goal, the open shift included; nil
  /// without a goal or the store. A shift that isn't clocked in isn't in
  /// the store, so it doesn't count yet.
  func weekGoal(now: Date, calendar: Calendar = .current) -> ShiftStore.WeekGoal? {
    guard let store else { return nil }
    let start =
      calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
    do {
      return try store.weekGoal(weekStart: start, now: now)
    } catch {
      log("read weekly goal:", error)
      return nil
    }
  }

  func isOnLunch(_ rule: LunchRule?, now: Date = Date()) -> Bool {
    guard let breakStart, let lunch = lunch(rule, now: now)?.lunch else { return false }
    return lunch.end == nil && lunch.start == breakStart
  }

  /// The saved breaks, plus the one in progress as if it ended at `now`.
  func breaks(now: Date) -> [Interval] {
    guard let breakStart else { return breaks }
    return breaks + [Interval(inDate: breakStart, outDate: max(now, breakStart))]
  }

  func startBreak(now: Date = Date()) {
    if breakStart == nil {
      breakStartID = UUID()
      breakStart = now
    }
  }

  /// Saves the break in progress. One ended within the minute it started
  /// (most likely a mis-click) is dropped.
  func endBreak(now: Date = Date()) {
    guard let start = breakStart else { return }
    breakStart = nil
    let brk = Interval(id: breakStartID, inDate: start, outDate: now)
    if brk.isValid { breaks.append(brk) }
  }

  /// The shift's breaks on the clock, start to end, oldest first; the one in
  /// progress isn't one of them.
  func anchoredBreaks() -> [(start: Date, end: Date)] {
    breaks.filter(\.isValid)
      .map { ShiftTimes.anchor($0, clockIn: clockInTime) }
      .sorted { $0.start < $1.start }
  }

  /// When the next break starts or, during one planned with an end, when
  /// it's over. nil once no break is left before clock out.
  func untilBreak(now: Date) -> Date? {
    let clockOut = clockOut(now: now)
    for brk in anchoredBreaks() where brk.end > now && brk.start < clockOut {
      return brk.start > now ? brk.start : brk.end
    }
    return nil
  }

  /// Whether `now` falls in a break planned with an end, like a class.
  func isInPlannedBreak(now: Date) -> Bool {
    anchoredBreaks().contains { $0.start <= now && now < $0.end }
  }

  /// The breaks the scheduled presets put on a shift clocking in at
  /// `clockIn`.
  func scheduledBreaks(clockIn: Date) -> [Interval] {
    guard let store else { return [] }
    do {
      return try store.scheduledBreaks(at: clockIn, lengthSeconds: lengthSeconds)
        .map { Interval(inDate: $0.start, outDate: $0.end) }
    } catch {
      log("scheduled breaks:", error)
      return []
    }
  }

  /// A scheduled break as it would go on this shift today, if it fits:
  /// it's on, it's for the shift's weekday, the shift is today's (or still
  /// going), it isn't over yet, it starts before clock out, and no break
  /// already overlaps it. It counts from clock in, as when clocking in.
  func todayBreak(for preset: ScheduledBreak, now: Date, calendar: Calendar = .current)
    -> Interval?
  {
    guard preset.isEnabled, preset.isValid,
      preset.weekdays.contains(Preferences.isoWeekday(clockInTime, calendar: calendar))
    else { return nil }
    let clockOut = clockOut(now: now)
    guard calendar.isDate(clockInTime, inSameDayAs: now) || clockOut > now else { return nil }

    let day = calendar.startOfDay(for: clockInTime)
    let start = max(day.addingTimeInterval(preset.start), clockInTime)
    let end = day.addingTimeInterval(preset.end)
    guard end > now, end > start, start < clockOut else { return nil }

    var taken = anchoredBreaks()
    if let breakStart { taken.append((breakStart, .distantFuture)) }
    guard !taken.contains(where: { $0.start < end && start < $0.end }) else { return nil }
    return Interval(inDate: start, outDate: end)
  }

  /// Puts a scheduled break on this shift today, if it fits (see
  /// `todayBreak`). Returns whether it did.
  @discardableResult
  func addToday(_ preset: ScheduledBreak, now: Date = Date(), calendar: Calendar = .current)
    -> Bool
  {
    guard let brk = todayBreak(for: preset, now: now, calendar: calendar) else { return false }
    breaks.append(brk)
    return true
  }

  /// The clock-in picker only edits hour and minute, so a menu bar app left
  /// running overnight would compute today's shift on yesterday's date and
  /// every alarm would already be in the past. Once a shift is stale, start
  /// the next one at the same time of day today, with today's scheduled
  /// breaks instead of yesterday's. A clocked-in shift ends in the store
  /// first, at its clock out.
  ///
  /// Off the clock, a draft from an earlier day rolls over as soon as its
  /// shift is over, so a new day never starts with yesterday's breaks.
  func rollOverIfStale(now: Date = Date(), calendar: Calendar = .current) {
    if isClockedIn, let store, (try? store.closeStaleShift(now: now)) == true {
      shiftID = nil
    }
    // A break left running this long was forgotten, not taken.
    if let breakStart, breakStart < now.addingTimeInterval(-Self.staleAfter) {
      self.breakStart = nil
    }
    let stale = clockOut(now: now) < now.addingTimeInterval(-Self.staleAfter)
    let earlierDay =
      !isClockedIn && !calendar.isDate(clockInTime, inSameDayAs: now)
      && clockInTime < now && clockOut(now: now) <= now
    guard stale || earlierDay else { return }
    let today = ShiftTimes.on(now, timeOf: clockInTime, calendar: calendar)
    // Only assign real changes: every set notifies observers.
    if today != clockInTime { clockInTime = today }
    if breakStart != nil { breakStart = nil }
    let planned = scheduledBreaks(clockIn: today)
    if breaks != planned { breaks = planned }
  }

  // MARK: Clocking in and out

  /// Clocks in now, making this the store's open shift. If another app
  /// clocked in first, shows that shift instead. Back the same day from
  /// clocking out early (for a class, say), the store resumes that shift,
  /// and it's shown as the store has it.
  ///
  /// Otherwise the shift starts with the day's planned breaks (scheduled
  /// and one-off) and the draft's breaks still to come today, all as new
  /// breaks. The draft's breaks can be an ended shift's under that shift's
  /// ids, and saving one of those here would take it off its own day.
  func clockInNow(now: Date = Date(), calendar: Calendar = .current) {
    guard let store, !isClockedIn else { return }
    let ahead = draftBreaksAhead(now: now, calendar: calendar)
    do {
      let id = try store.startShift(at: now, lengthSeconds: lengthSeconds)
      if let shift = try store.currentShift(), shift.id == id, shift.clockIn != now.flooredToSecond {
        // Resumed, with the store's breaks and the time away as one.
        pull()
        return
      }
      clockInTime = now
      // A break you started today goes along, as a new one; an older one
      // was forgotten.
      if let start = breakStart, calendar.isDate(start, inSameDayAs: now), start <= now {
        breakStartID = UUID()
      } else {
        breakStart = nil
      }
      var fresh = scheduledBreaks(clockIn: now)
      for brk in ahead where !fresh.contains(where: { $0.inDate < brk.outDate && brk.inDate < $0.outDate }) {
        fresh.append(brk)
      }
      breaks = fresh.sorted { $0.inDate < $1.inDate }
      shiftID = id
      push(now: now)
    } catch {
      log("clock in:", error)
      pull()
    }
  }

  /// Clocks out now. The shift stays on screen as a draft.
  func clockOutNow(now: Date = Date()) {
    guard let store, isClockedIn else { return }
    do {
      try store.endShift(now: now)
    } catch {
      log("clock out:", error)
    }
    // The store ended any break with the shift.
    endBreak(now: now)
    shiftID = nil
  }

  /// The draft's breaks that end after `now` on today's clock, under new
  /// ids, cut to start no earlier than `now`. None from another day's draft.
  private func draftBreaksAhead(now: Date, calendar: Calendar) -> [Interval] {
    guard calendar.isDate(clockInTime, inSameDayAs: now) else { return [] }
    return breaks.filter(\.isValid).compactMap { brk in
      let (start, end) = ShiftTimes.anchor(brk, clockIn: clockInTime, calendar: calendar)
      guard end > now, calendar.isDate(start, inSameDayAs: now) || start < now else { return nil }
      return Interval(inDate: max(start, now), outDate: end)
    }
  }

  private var lengthSeconds: Int64 { Int64((shiftLength * 3600).rounded()) }

  // MARK: Store

  /// Writes the model to the store: alarm rules always, and the shift and
  /// its breaks while clocked in. Unchanged rows aren't touched.
  func push(now: Date = Date()) {
    guard let store else { return }
    do {
      try pushAlarms(store, now: now)
      guard let shiftID else { return }

      if let current = try store.currentShift(), current.id == shiftID {
        if current.clockIn != clockInTime.flooredToSecond || current.lengthSeconds != lengthSeconds {
          try store.editShift(shiftID, clockIn: clockInTime, lengthSeconds: lengthSeconds, now: now)
        }
      } else {
        // Clocked out elsewhere since the last pull.
        self.shiftID = nil
        return
      }

      var wanted: [UUID: ShiftStore.Break] = [:]
      for brk in breaks where brk.isValid {
        let (start, end) = ShiftTimes.anchor(brk, clockIn: clockInTime)
        wanted[brk.id] = .init(id: brk.id, start: start.flooredToSecond, end: end.flooredToSecond)
      }
      if let breakStart {
        wanted[breakStartID] = .init(id: breakStartID, start: breakStart.flooredToSecond, end: nil)
      }
      let stored = try store.breaks(of: shiftID)
      for brk in wanted.values where !stored.contains(brk) {
        try store.putBreak(brk, shift: shiftID, now: now)
      }
      for brk in stored where wanted[brk.id] == nil {
        try store.deleteBreak(brk.id, now: now)
      }
    } catch {
      log("save to store:", error)
    }
  }

  private func pushAlarms(_ store: ShiftStore, now: Date) throws {
    let stored = Dictionary(
      try store.alarmRules().map { (UUID($0.id), $0) }, uniquingKeysWith: { a, _ in a })
    // Lunch alarms name the lunch window's preset.
    let lunchID = alarms.contains(where: \.isLunch)
      ? try store.breakPresets().first { $0.kind == "window" }?.id : nil
    for rule in alarms {
      if rule.isLunch && lunchID == nil { continue }
      let row = rule.storeRow(lunchID: lunchID)
      if let old = stored[rule.id], old.kind == row.kind, old.value == row.value,
        old.enabled == row.enabled
      {
        continue
      }
      try store.putAlarmRule(row, now: now)
    }
    let ids = Set(alarms.map(\.id))
    for id in stored.keys where !ids.contains(id) {
      try store.deleteAlarmRule(id, now: now)
    }
  }

  /// Reads the store into the model: alarm rules, and the open shift if
  /// there is one. Breaks being typed in that aren't valid yet are kept.
  func pull() {
    guard let store else { return }
    do {
      let rules = try store.alarmRules().map { AlarmRule(storeRow: $0) }
      if !rules.elementsEqual(alarms, by: AlarmRule.sameRule) { alarms = rules }

      guard let shift = try store.currentShift() else {
        if isClockedIn {
          // Clocked out elsewhere; the store ended any break with it.
          shiftID = nil
          breakStart = nil
        }
        return
      }
      if shiftID != shift.id { shiftID = shift.id }
      if clockInTime.flooredToSecond != shift.clockIn { clockInTime = shift.clockIn }
      let length = Double(shift.lengthSeconds) / 3600
      if shiftLength != length { shiftLength = length }

      let stored = try store.breaks(of: shift.id)
      let done = stored.compactMap { brk in
        brk.end.map { Interval(id: brk.id, inDate: brk.start, outDate: $0) }
      }
      let pending = breaks.filter { !$0.isValid }
      if done + pending != breaks { breaks = done + pending }
      if let running = stored.first(where: { $0.end == nil }) {
        breakStartID = running.id
        if breakStart?.flooredToSecond != running.start { breakStart = running.start }
      } else if breakStart != nil {
        breakStart = nil
      }
    } catch {
      log("load from store:", error)
    }
  }

  /// Copies alarm rules saved by a version before the store into it, once.
  func migrateAlarms(from defaults: UserDefaults = .standard) {
    guard let store, !defaults.bool(forKey: Self.migratedKey) else { return }
    do {
      if try store.alarmRules().isEmpty { try pushAlarms(store, now: Date()) }
      defaults.set(true, forKey: Self.migratedKey)
    } catch {
      log("migrate alarms:", error)
    }
  }

  static let migratedKey = "shift.v1.migratedToStore"

  // MARK: Draft

  private struct Snapshot: Codable {
    var clockInTime: Date
    var shiftLength: Double
    var breaks: [Interval]
    var alarms: [AlarmRule]
    var breakStart: Date?
  }

  static let defaultsKey = "shift.v1"

  /// The draft from UserDefaults, then, with a store, the store's alarms
  /// and open shift on top.
  static func load(from defaults: UserDefaults = .standard, store: ShiftStore? = nil) -> ShiftModel {
    let model = ShiftModel()
    model.store = store
    if let data = defaults.data(forKey: defaultsKey),
      let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
    {
      model.clockInTime = snap.clockInTime
      model.shiftLength = snap.shiftLength
      model.breaks = snap.breaks
      model.alarms = snap.alarms
      model.breakStart = snap.breakStart
    }
    model.migrateAlarms(from: defaults)
    model.pull()
    return model
  }

  /// Saves the draft and writes through to the store.
  func save(to defaults: UserDefaults = .standard) {
    let snap = Snapshot(
      clockInTime: clockInTime, shiftLength: shiftLength, breaks: breaks, alarms: alarms,
      breakStart: breakStart)
    if let data = try? JSONEncoder().encode(snap) {
      defaults.set(data, forKey: Self.defaultsKey)
    }
    push()
  }
}

extension Date {
  /// The store keeps whole seconds.
  var flooredToSecond: Date {
    Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
  }
}

extension AlarmRule {
  /// The store's row. Lunch alarms need `lunchID`, the lunch window's
  /// preset.
  func storeRow(lunchID: UUID? = nil) -> ShiftyAlarmRule {
    let (kind, value): (ShiftyAlarmKind, Int) =
      switch trigger {
      case .beforeClockOut(let minutes): (SHIFTY_ALARM_BEFORE_CLOCK_OUT, minutes)
      case .atTime(let time): (SHIFTY_ALARM_AT_TIME, Self.secondsSinceMidnight(time))
      case .lunchOpens: (SHIFTY_ALARM_WINDOW_OPENS, 0)
      case .beforeLunchCloses(let minutes): (SHIFTY_ALARM_BEFORE_WINDOW_CLOSES, minutes)
      case .beforeBreak(let minutes): (SHIFTY_ALARM_BEFORE_BREAK, minutes)
      case .beforeBreakEnds(let minutes): (SHIFTY_ALARM_BEFORE_BREAK_ENDS, minutes)
      }
    return ShiftyAlarmRule(
      id: ShiftyId(id), kind: Int32(kind.rawValue), enabled: isEnabled ? 1 : 0,
      value: Int64(value), preset_id: isLunch ? lunchID.map(ShiftyId.init) ?? ShiftyId() : ShiftyId())
  }

  /// A rule from the store. Window alarms are lunch alarms: lunch is the
  /// only window.
  init(storeRow row: ShiftyAlarmRule, calendar: Calendar = .current) {
    let minutes = Int(row.value)
    let trigger: Trigger =
      switch row.kind {
      case Int32(SHIFTY_ALARM_AT_TIME.rawValue):
        .atTime(calendar.startOfDay(for: Date()).addingTimeInterval(TimeInterval(row.value)))
      case Int32(SHIFTY_ALARM_WINDOW_OPENS.rawValue): .lunchOpens
      case Int32(SHIFTY_ALARM_BEFORE_WINDOW_CLOSES.rawValue): .beforeLunchCloses(minutes: minutes)
      case Int32(SHIFTY_ALARM_BEFORE_BREAK.rawValue): .beforeBreak(minutes: minutes)
      case Int32(SHIFTY_ALARM_BEFORE_BREAK_ENDS.rawValue): .beforeBreakEnds(minutes: minutes)
      default: .beforeClockOut(minutes: minutes)
      }
    self.init(id: UUID(row.id), trigger: trigger, isEnabled: row.enabled != 0)
  }

  static func secondsSinceMidnight(_ date: Date, calendar: Calendar = .current) -> Int {
    let c = calendar.dateComponents([.hour, .minute, .second], from: date)
    return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
  }

  /// Same rule, comparing a set time by time of day; the stored date's day
  /// means nothing.
  static func sameRule(_ a: AlarmRule, _ b: AlarmRule) -> Bool {
    let ar = a.storeRow()
    let br = b.storeRow()
    return a.id == b.id && ar.kind == br.kind && ar.value == br.value && ar.enabled == br.enabled
  }
}
