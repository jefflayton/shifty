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

  @ObservationIgnored var store: ShiftStore?

  var isOnBreak: Bool { breakStart != nil }
  var isClockedIn: Bool { shiftID != nil }

  /// A shift whose clock out is this far in the past is over.
  static let staleAfter: TimeInterval = 12 * 60 * 60

  var clockOut: Date { clockOut(now: Date()) }

  /// Clock out if the break in progress (if any) ended at `now`.
  func clockOut(now: Date) -> Date {
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

  /// The clock-in picker only edits hour and minute, so a menu bar app left
  /// running overnight would compute today's shift on yesterday's date and
  /// every alarm would already be in the past. Once a shift is stale, start
  /// the next one at the same time of day today, without yesterday's breaks.
  /// A clocked-in shift ends in the store first, at its clock out.
  func rollOverIfStale(now: Date = Date(), calendar: Calendar = .current) {
    if isClockedIn, let store, (try? store.closeStaleShift(now: now)) == true {
      shiftID = nil
    }
    // A break left running this long was forgotten, not taken.
    if let breakStart, breakStart < now.addingTimeInterval(-Self.staleAfter) {
      self.breakStart = nil
    }
    guard clockOut(now: now) < now.addingTimeInterval(-Self.staleAfter) else { return }
    let today = ShiftTimes.on(now, timeOf: clockInTime, calendar: calendar)
    // Only assign real changes: every set notifies observers.
    if today != clockInTime { clockInTime = today }
    if !breaks.isEmpty { breaks = [] }
  }

  // MARK: Clocking in and out

  /// Clocks in now, making this the store's open shift. If another app
  /// clocked in first, shows that shift instead.
  func clockInNow(now: Date = Date()) {
    guard let store, !isClockedIn else { return }
    clockInTime = now
    do {
      shiftID = try store.startShift(at: now, lengthSeconds: lengthSeconds)
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
    for rule in alarms {
      let row = rule.storeRow
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
  var storeRow: ShiftyAlarmRule {
    switch trigger {
    case .beforeClockOut(let minutes):
      ShiftyAlarmRule(
        id: ShiftyId(id), kind: Int32(SHIFTY_ALARM_BEFORE_CLOCK_OUT.rawValue),
        enabled: isEnabled ? 1 : 0, value: Int64(minutes))
    case .atTime(let time):
      ShiftyAlarmRule(
        id: ShiftyId(id), kind: Int32(SHIFTY_ALARM_AT_TIME.rawValue),
        enabled: isEnabled ? 1 : 0, value: Int64(Self.secondsSinceMidnight(time)))
    }
  }

  init(storeRow row: ShiftyAlarmRule, calendar: Calendar = .current) {
    let trigger: Trigger =
      row.kind == Int32(SHIFTY_ALARM_AT_TIME.rawValue)
      ? .atTime(calendar.startOfDay(for: Date()).addingTimeInterval(TimeInterval(row.value)))
      : .beforeClockOut(minutes: Int(row.value))
    self.init(id: UUID(row.id), trigger: trigger, isEnabled: row.enabled != 0)
  }

  static func secondsSinceMidnight(_ date: Date, calendar: Calendar = .current) -> Int {
    let c = calendar.dateComponents([.hour, .minute, .second], from: date)
    return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0)
  }

  /// Same rule, comparing a set time by time of day; the stored date's day
  /// means nothing.
  static func sameRule(_ a: AlarmRule, _ b: AlarmRule) -> Bool {
    let ar = a.storeRow
    let br = b.storeRow
    return a.id == b.id && ar.kind == br.kind && ar.value == br.value && ar.enabled == br.enabled
  }
}
