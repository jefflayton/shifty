// Tests for platforms/macos/Models, linked against the Zig core.
// Run with `zig build test-macos`.

import Foundation

NSTimeZone.default = TimeZone(identifier: "UTC")!
var cal = Calendar(identifier: .gregorian)
cal.timeZone = TimeZone(identifier: "UTC")!

var failures = 0
var count = 0

func check(_ cond: Bool, _ msg: String, line: Int = #line) {
  count += 1
  if !cond {
    failures += 1
    print("FAIL line \(line): \(msg)")
  }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "", line: Int = #line) {
  check(a == b, "\(msg) expected \(b), got \(a)", line: line)
}

/// 2026-10-28 (or `day` later) at hh:mm UTC.
func at(_ h: Int, _ m: Int = 0, day: Int = 0) -> Date {
  cal.date(from: DateComponents(year: 2026, month: 10, day: 28 + day, hour: h, minute: m))!
}

func brk(_ start: Date, _ end: Date) -> Interval { Interval(inDate: start, outDate: end) }

// MARK: ShiftTimes

do {
  let (s, e) = ShiftTimes.anchor(brk(at(23, 30), at(0, 30)), clockIn: at(20), calendar: cal)
  expectEqual(s, at(23, 30), "break crossing midnight start")
  expectEqual(e, at(0, 30, day: 1), "break crossing midnight end")
}
do {
  let (s, e) = ShiftTimes.anchor(brk(at(2), at(2, 30)), clockIn: at(22), calendar: cal)
  expectEqual(s, at(2, day: 1), "break after midnight on a night shift")
  expectEqual(e, at(2, 30, day: 1))
}
do {
  let (s, _) = ShiftTimes.anchor(brk(at(8, 30), at(9, 30)), clockIn: at(9), calendar: cal)
  expectEqual(s, at(8, 30), "break spanning clock in stays on the same day")
}
do {
  // Stored on a different day than clock in: only the time of day counts.
  let (s, e) = ShiftTimes.anchor(
    brk(at(12, day: -3), at(13, day: -3)), clockIn: at(9), calendar: cal)
  expectEqual(s, at(12))
  expectEqual(e, at(13))
}
check(ShiftTimes.isValid(brk(at(12), at(13)), calendar: cal), "1h break is valid")
check(ShiftTimes.isValid(brk(at(23, 30), at(0, 30)), calendar: cal), "midnight break is valid")
check(!ShiftTimes.isValid(brk(at(13), at(12)), calendar: cal), "swapped times (23h) are invalid")
check(!ShiftTimes.isValid(brk(at(12), at(12)), calendar: cal), "empty break is invalid")
expectEqual(ShiftTimes.anchor(time: at(6), clockIn: at(22), calendar: cal), at(6, day: 1))
expectEqual(
  ShiftTimes.anchor(time: at(9), clockIn: at(9).addingTimeInterval(37), calendar: cal), at(9),
  "same minute as clock in is not pushed to tomorrow")

// MARK: ShiftModel.clockOut (through the Zig core)

do {
  let m = ShiftModel()
  m.clockInTime = at(9)
  m.shiftLength = 8
  expectEqual(m.clockOut, at(17), "no breaks")
  m.breaks = [brk(at(12), at(12, 30))]
  expectEqual(m.clockOut, at(17, 30), "lunch")
  m.shiftLength = 7.5
  expectEqual(m.clockOut, at(17), "fractional shift")
  m.breaks.append(brk(at(16), at(15)))  // swapped: ignored, not a 23h break
  expectEqual(m.clockOut, at(17), "invalid break ignored")
}

// MARK: The scenario: an unexpected break moves the clock-out alarm

do {
  let m = ShiftModel()
  m.clockInTime = at(9)
  m.breaks = [brk(at(12), at(12, 30))]
  let rule = AlarmRule(trigger: .beforeClockOut(minutes: 0))
  let early = AlarmRule(trigger: .beforeClockOut(minutes: 15))
  expectEqual(
    rule.fireDate(clockIn: m.clockInTime, clockOut: m.clockOut, calendar: cal), at(17, 30))
  expectEqual(
    early.fireDate(clockIn: m.clockInTime, clockOut: m.clockOut, calendar: cal), at(17, 15))

  m.breaks.append(brk(at(14, 10), at(14, 30)))
  expectEqual(
    rule.fireDate(clockIn: m.clockInTime, clockOut: m.clockOut, calendar: cal), at(17, 50),
    "alarm follows the extra break")

  let fixed = AlarmRule(trigger: .atTime(at(6, day: -5)))
  expectEqual(
    fixed.fireDate(clockIn: at(22), clockOut: at(6, day: 1), calendar: cal), at(6, day: 1),
    "set-time alarm lands inside a night shift")
}

// MARK: AlarmPlanner

do {
  let now = at(12)
  expectEqual(
    AlarmPlanner.action(fireDate: at(17), pending: nil, snoozed: false, now: now),
    .schedule(at(17)), "new alarm")
  expectEqual(
    AlarmPlanner.action(fireDate: at(17), pending: at(17), snoozed: false, now: now),
    .keep, "unchanged")
  expectEqual(
    AlarmPlanner.action(fireDate: at(17, 20), pending: at(17), snoozed: false, now: now),
    .schedule(at(17, 20)), "clock out moved later")
  expectEqual(
    AlarmPlanner.action(fireDate: at(11), pending: at(17), snoozed: false, now: now),
    .cancelPending, "moved into the past: don't ring")
  expectEqual(
    AlarmPlanner.action(fireDate: at(11), pending: at(12, 5), snoozed: true, now: now),
    .keep, "snooze survives unrelated edits")
  expectEqual(
    AlarmPlanner.action(fireDate: at(13), pending: at(12, 5), snoozed: true, now: now),
    .schedule(at(13)), "clock out moved past the snooze: re-arm")
}

// MARK: Day rollover

do {
  let m = ShiftModel()
  m.clockInTime = at(9, day: -1)
  m.breaks = [brk(at(12), at(13))]
  m.rollOverIfStale(now: at(8, 30), calendar: cal)
  expectEqual(m.clockInTime, at(9), "yesterday's shift rolls to today")
  check(m.breaks.isEmpty, "yesterday's breaks are dropped")

  let night = ShiftModel()
  night.clockInTime = at(22, day: -1)
  night.breaks = [brk(at(1), at(1, 30))]
  night.rollOverIfStale(now: at(2), calendar: cal)
  expectEqual(night.clockInTime, at(22, day: -1), "night shift in progress is kept")
  expectEqual(night.breaks.count, 1)
}

// MARK: Persistence

do {
  let suite = "shifty-tests-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }

  let m = ShiftModel()
  m.clockInTime = at(9)
  m.shiftLength = 7.5
  m.breaks = [brk(at(12), at(12, 30))]
  m.alarms = [
    AlarmRule(trigger: .beforeClockOut(minutes: 10)),
    AlarmRule(trigger: .atTime(at(15)), isEnabled: false),
  ]
  m.breakStart = at(14)
  m.save(to: defaults)

  let loaded = ShiftModel.load(from: defaults)
  expectEqual(loaded.clockInTime, m.clockInTime)
  expectEqual(loaded.shiftLength, 7.5)
  expectEqual(loaded.breaks, m.breaks)
  expectEqual(loaded.alarms, m.alarms)
  expectEqual(loaded.breakStart, at(14), "break in progress survives a restart")

  let empty = ShiftModel.load(from: UserDefaults(suiteName: suite + "-none")!)
  check(empty.alarms.isEmpty && empty.breaks.isEmpty, "missing data loads defaults")
}

// MARK: ShiftSummary

do {
  // 9-5 shift with lunch 12-1 (1/8 of the span) and an overlapping 12:30-1:30
  let spans = ShiftSummary.breakSpans(
    [brk(at(12), at(13)), brk(at(12, 30), at(13, 30))], clockIn: at(9), clockOut: at(17),
    calendar: cal)
  expectEqual(spans.count, 1, "overlapping breaks merge")
  expectEqual(spans.first?.lowerBound, 3.0 / 8)
  expectEqual(spans.first?.upperBound, 4.5 / 8)
  expectEqual(
    ShiftSummary.breakSeconds(
      [brk(at(12), at(13)), brk(at(12, 30), at(13, 30))], clockIn: at(9), clockOut: at(17),
      calendar: cal), 90 * 60)

  let clipped = ShiftSummary.breakSpans(
    [brk(at(8, 30), at(9, 30)), brk(at(16, 30), at(17, 30)), brk(at(13), at(12))],
    clockIn: at(9), clockOut: at(17), calendar: cal)
  expectEqual(clipped.count, 2, "invalid break dropped")
  expectEqual(clipped.first?.lowerBound, 0, "clipped to clock in")
  expectEqual(clipped.last?.upperBound, 1, "clipped to clock out")
}
expectEqual(ShiftSummary.duration(45 * 60), "45 min")
expectEqual(ShiftSummary.duration(2 * 3600), "2 hr")
expectEqual(ShiftSummary.duration(3600 + 5 * 60), "1 hr 5 min")
expectEqual(ShiftSummary.relative(at(17, 30), now: at(14, 18)), "in 3 hr 12 min")
expectEqual(ShiftSummary.relative(at(17), now: at(17, 0).addingTimeInterval(20)), "now")
expectEqual(ShiftSummary.relative(at(17), now: at(17, 12)), "12 min ago")

// MARK: Break in progress

do {
  let m = ShiftModel()
  m.clockInTime = at(9)
  m.startBreak(now: at(12))
  check(m.isOnBreak, "on break")
  m.startBreak(now: at(12, 5))
  expectEqual(m.breakStart, at(12), "starting again keeps the first start")
  expectEqual(m.clockOut(now: at(12, 20)), at(17, 20), "clock out moves while on break")
  expectEqual(m.clockOut(now: at(12, 45)), at(17, 45))
  check(m.breaks.isEmpty, "not saved until it ends")

  m.endBreak(now: at(12, 30))
  check(!m.isOnBreak, "break ended")
  expectEqual(m.breaks.map(\.inDate), [at(12)], "ended break is saved")
  expectEqual(m.breaks.map(\.outDate), [at(12, 30)])
  expectEqual(m.clockOut(now: at(15)), at(17, 30), "saved break stops moving")

  m.startBreak(now: at(14))
  m.endBreak(now: at(14).addingTimeInterval(20))
  expectEqual(m.breaks.count, 1, "a break ended in the same minute is dropped")
}
do {
  let m = ShiftModel()
  m.clockInTime = at(9, day: -1)
  m.startBreak(now: at(16, day: -1))
  m.rollOverIfStale(now: at(8), calendar: cal)
  check(!m.isOnBreak, "a break left running overnight is dropped")
  expectEqual(m.clockInTime, at(9), "and the shift rolls over")
}
do {
  let now = at(12, 10)
  expectEqual(
    AlarmPlanner.action(fireDate: at(17), pending: at(17), snoozed: false, held: true, now: now),
    .cancelPending, "clock-out alarms wait for the break to end")
  expectEqual(
    AlarmPlanner.action(fireDate: at(17), pending: at(12, 12), snoozed: true, held: true, now: now),
    .keep, "a snooze still rings during a break")
  check(AlarmRule(trigger: .beforeClockOut(minutes: 5)).followsClockOut, "follows clock out")
  check(!AlarmRule(trigger: .atTime(at(15))).followsClockOut, "set time doesn't")
}

// MARK: Menu bar text

do {
  expectEqual(MenuBarDisplay.compact(2 * 3600 + 15 * 60), "2h 15m")
  expectEqual(MenuBarDisplay.compact(45 * 60), "45m")
  expectEqual(MenuBarDisplay.compact(20), "1m", "rounds up before clock out")
  expectEqual(MenuBarDisplay.timeLeft.title(clockOut: at(17), now: at(14, 50)), "2h 10m")
  check(MenuBarDisplay.clockOut.title(clockOut: at(17), now: at(14)) != nil, "clock-out time")
  check(MenuBarDisplay.iconOnly.title(clockOut: at(17), now: at(14)) == nil, "icon only")
  check(MenuBarDisplay.timeLeft.title(clockOut: at(17), now: at(17, 1)) == nil, "shift over")

  let suite = "shifty-tests-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  expectEqual(Preferences(defaults: defaults).menuBarDisplay, .clockOut, "default")
  Preferences(defaults: defaults).menuBarDisplay = .timeLeft
  expectEqual(Preferences(defaults: defaults).menuBarDisplay, .timeLeft, "saved")
}

// MARK: Clock-out link

do {
  expectEqual(Preferences.link(from: "https://example.com/clock")?.absoluteString,
    "https://example.com/clock")
  expectEqual(Preferences.link(from: "  example.com/clock ")?.absoluteString,
    "https://example.com/clock", "bare address gets https")
  expectEqual(Preferences.link(from: "http://timeclock")?.absoluteString, "http://timeclock",
    "intranet host")
  check(Preferences.link(from: "") == nil, "empty")
  check(Preferences.link(from: "not a link") == nil, "spaces")
  check(Preferences.link(from: "https://") == nil, "no host")

  let suite = "shifty-tests-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  check(Preferences(defaults: defaults).clockOutLink == nil, "no link by default")
  Preferences(defaults: defaults).clockOutLink = URL(string: "https://example.com")
  expectEqual(Preferences(defaults: defaults).clockOutLink, URL(string: "https://example.com"),
    "saved")
  Preferences(defaults: defaults).clockOutLink = nil
  check(Preferences(defaults: defaults).clockOutLink == nil, "cleared")
}

// MARK: Store

/// A fresh database file; a second ShiftStore on the same path stands in
/// for the TUI or CLI.
func tempStorePath() -> String {
  NSTemporaryDirectory() + "shifty-tests-\(UUID().uuidString).db"
}

do {
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let tui = try! ShiftStore(path: path)

  let m = ShiftModel()
  m.store = store
  m.clockInTime = at(8)
  m.breaks = [brk(at(12), at(12, 30))]
  m.push(now: at(9))
  check(try! store.currentShift() == nil, "a draft isn't saved as a shift")

  m.clockInNow(now: at(9))
  check(m.isClockedIn, "clocked in")
  var shift = try! tui.currentShift()!
  expectEqual(shift.clockIn, at(9), "clock in is now")
  expectEqual(shift.lengthSeconds, 8 * 3600)
  expectEqual(try! tui.breaks(of: shift.id).map(\.start), [at(12)], "planned break goes along")

  m.shiftLength = 7.5
  m.push(now: at(9, 5))
  expectEqual(try! tui.currentShift()!.lengthSeconds, 7 * 3600 + 1800, "length writes through")

  m.startBreak(now: at(10))
  m.push(now: at(10))
  var stored = try! tui.breaks(of: shift.id)
  let running = stored.first { $0.end == nil }
  check(running != nil, "break in progress is shared")
  m.endBreak(now: at(10, 15))
  m.push(now: at(10, 15))
  stored = try! tui.breaks(of: shift.id)
  expectEqual(stored.count, 2, "ended break keeps its row")
  expectEqual(stored.first { $0.id == running?.id }?.end, at(10, 15))

  m.breaks.removeAll { $0.inDate == at(12) }
  m.push(now: at(10, 20))
  expectEqual(try! tui.breaks(of: shift.id).count, 1, "removed break is deleted")

  // The TUI edits the shift and starts a break; the app pulls it in.
  try! tui.editShift(shift.id, clockIn: at(8, 30), lengthSeconds: 8 * 3600, now: at(11))
  try! tui.putBreak(.init(id: UUID(), start: at(11), end: nil), shift: shift.id, now: at(11))
  m.pull()
  expectEqual(m.clockInTime, at(8, 30), "clock in from elsewhere")
  expectEqual(m.shiftLength, 8)
  expectEqual(m.breakStart, at(11), "break from elsewhere")
  m.push(now: at(11, 1))
  expectEqual(try! tui.breaks(of: shift.id).count, 2, "pulling then saving changes nothing")

  // Clocking out elsewhere leaves the shift on screen as a draft.
  try! tui.endShift(now: at(12))
  m.pull()
  check(!m.isClockedIn, "clocked out elsewhere")
  check(!m.isOnBreak, "the break ended with the shift")
  expectEqual(m.clockInTime, at(8, 30), "draft keeps the shift's values")

  m.clockInNow(now: at(13))
  shift = try! tui.currentShift()!
  m.clockOutNow(now: at(17))
  check(try! tui.currentShift() == nil, "clocked out here")
  check(!m.isClockedIn, "not clocked in")
}

do {
  // Someone else clocked in first: clocking in here shows their shift.
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  _ = try! ShiftStore(path: path).startShift(at: at(7), lengthSeconds: 6 * 3600)
  let m = ShiftModel()
  m.store = store
  m.clockInNow(now: at(9))
  check(m.isClockedIn, "on the other shift")
  expectEqual(m.clockInTime, at(7))
  expectEqual(m.shiftLength, 6)
}

do {
  // Alarm rules move into the store once, then live there.
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let suite = "shifty-tests-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }

  let old = ShiftModel()
  old.alarms = [
    AlarmRule(trigger: .beforeClockOut(minutes: 10)),
    AlarmRule(trigger: .atTime(at(15, 30)), isEnabled: false),
  ]
  old.save(to: defaults)

  let store = try! ShiftStore(path: path)
  let m = ShiftModel.load(from: defaults, store: store)
  expectEqual(try! store.alarmRules().count, 2, "migrated")
  check(m.alarms.elementsEqual(old.alarms, by: AlarmRule.sameRule), "same rules after loading")
  check(defaults.bool(forKey: ShiftModel.migratedKey), "migration recorded")

  m.alarms.removeAll()
  m.save(to: defaults)
  let again = ShiftModel.load(from: defaults, store: store)
  check(again.alarms.isEmpty, "deleted rules don't come back from the old copy")

  let rule = AlarmRule(trigger: .atTime(at(16, 45)))
  expectEqual(AlarmRule(storeRow: rule.storeRow, calendar: cal).fireDate(clockIn: at(9), clockOut: at(17), calendar: cal), at(16, 45), "set time round-trips by time of day")
}

do {
  // The clock-out link moves into the store once.
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let suite = "shifty-tests-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  Preferences(defaults: defaults).clockOutLink = URL(string: "https://example.com/clock")

  let store = try! ShiftStore(path: path)
  expectEqual(Preferences(defaults: defaults, store: store).clockOutLink,
    URL(string: "https://example.com/clock"), "migrated")
  expectEqual(try! store.setting(Preferences.clockOutLinkSetting), "https://example.com/clock")

  Preferences(defaults: defaults, store: store).clockOutLink = nil
  check(Preferences(defaults: defaults, store: store).clockOutLink == nil,
    "cleared link doesn't come back from the old copy")

  let prefs = Preferences(defaults: defaults, store: store)
  try! ShiftStore(path: path).setSetting(Preferences.clockOutLinkSetting, "https://tui.example")
  prefs.pull()
  expectEqual(prefs.clockOutLink, URL(string: "https://tui.example"), "link set elsewhere")
}

// MARK: Timesheet

do {
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let tui = try! ShiftStore(path: path)
  // Wednesday Oct 28; gregorian weeks start Sunday Oct 25.
  let t = TimesheetModel(store: store, calendar: cal, now: at(12))
  expectEqual(t.weekStart, at(0, day: -3), "week starts Sunday")
  expectEqual(t.days.count, 7)

  let web = try! store.createProject(name: "web", color: "#ff8800")
  let entry = try! tui.addEntry(project: web, workspace: nil, start: at(9), end: at(10), note: "standup")
  _ = try! tui.addEntry(project: nil, workspace: nil, start: at(13, day: 1), end: at(14, day: 1))
  _ = try! tui.addEntry(project: nil, workspace: nil, start: at(9, day: 7), end: at(10, day: 7))
  t.reload()
  expectEqual(t.entries(on: at(0)).map(\.id), [entry], "Wednesday's entry")
  expectEqual(t.entries(on: at(0, day: 1)).count, 1, "Thursday's entry")
  expectEqual(t.total(now: at(23, day: 3)), 2 * 3600, "next week's entry isn't counted")
  expectEqual(t.label(project: web, workspace: nil), "web")

  // A new hour goes after the day's last entry; today's ends now.
  expectEqual(t.slot(on: at(0), now: at(12)).0, at(10), "after the last entry")
  expectEqual(t.slot(on: at(0, day: 2), now: at(12)).0, at(9, day: 2), "9 AM on an empty day")
  let today = t.slot(on: at(0, day: 3), now: at(15, 8, day: 3))
  expectEqual(today.1, at(15, 15, day: 3), "today's ends now, to the quarter hour")

  var e = t.sheet.entries.first { $0.id == entry }!
  t.setEnd(e, to: at(10, 30))
  expectEqual(t.sheet.entries.first { $0.id == entry }!.end, at(10, 30), "end saved")

  // Moving the start past the end makes a 23h entry: kept as a draft.
  e = t.sheet.entries.first { $0.id == entry }!
  t.setStart(e, to: at(11))
  check(t.drafts[entry] != nil, "invalid times stay a draft")
  expectEqual(t.sheet.entries.first { $0.id == entry }!.start, at(9), "store unchanged")
  t.setEnd(e, to: at(11, 45))
  check(t.drafts[entry] == nil, "fixed draft is saved")
  e = t.sheet.entries.first { $0.id == entry }!
  expectEqual(e.start, at(11))
  expectEqual(e.end, at(11, 45))

  t.setEnd(e, to: at(1))
  expectEqual(
    t.sheet.entries.first { $0.id == entry }!.end, at(1, day: 1),
    "an end before the start is past midnight")

  t.setNote(e, to: "  ")
  check(t.sheet.entries.first { $0.id == entry }!.note == nil, "blank note clears it")

  let api = t.createProject(named: "api")!
  expectEqual(t.createProject(named: "API"), api, "same name, same project")
  t.setProject(t.sheet.entries.first { $0.id == entry }!, project: api, workspace: nil)
  expectEqual(t.sheet.entries.first { $0.id == entry }!.projectId, api)
  expectEqual(t.totalsByProject(now: at(23, day: 3)).first?.project, api, "most time first")

  let added = t.addEntry(on: at(0, day: 2), now: at(12))!
  t.delete(t.sheet.entries.first { $0.id == added }!)
  check(!t.sheet.entries.contains { $0.id == added }, "deleted")

  let start = t.weekStart
  t.nextWeek()
  expectEqual(t.weekStart, at(0, day: 4))
  expectEqual(t.sheet.entries.count, 1, "next week's entry")
  t.previousWeek()
  expectEqual(t.weekStart, start)

  // A running entry from elsewhere: stop it from the timesheet.
  t.showWeek(containing: Date())
  _ = try! tui.startShift(at: Date().addingTimeInterval(-3600), lengthSeconds: 8 * 3600)
  t.reload()
  let running = t.addEntry(on: Date())
  check(running != nil, "added today")
}

// MARK: Projects

do {
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let p = ProjectsModel(store: store)
  p.reload()
  check(p.projects.isEmpty, "no projects yet")

  let web = p.create(named: " web ")!
  let api = p.create(named: "api")!
  expectEqual(p.create(named: "WEB"), web, "same name, same project")
  check(p.create(named: "  ") == nil, "blank name")
  expectEqual(p.projects.map(\.name), ["api", "web"])
  expectEqual(p.rank(of: web), 0, "oldest first")
  expectEqual(p.rank(of: api), 1)

  _ = try! store.addEntry(project: web, workspace: nil, start: at(9), end: at(11))
  _ = try! store.addEntry(project: web, workspace: nil, start: at(9, day: 1), end: at(9, 30, day: 1))
  p.reload()
  expectEqual(p.usage(of: web)?.seconds, 9000)
  expectEqual(p.usage(of: web)?.entries, 2)
  expectEqual(p.usage(of: web)?.lastUsed, at(9, day: 1))
  check(p.usage(of: api) == nil, "unused")

  check(p.rename(p.project(web)!, to: "Website"), "renamed")
  expectEqual(p.project(web)?.name, "Website")
  check(!p.rename(p.project(web)!, to: "API"), "name taken")
  check(p.error != nil, "says why")
  check(!p.rename(p.project(web)!, to: " "), "blank refused")
  expectEqual(p.project(web)?.name, "Website", "unchanged")
  check(p.rename(p.project(web)!, to: "website"), "own name, new case")
  check(p.error == nil, "error clears")

  p.setColor(p.project(web)!, to: "#3B82F6")
  expectEqual(p.project(web)?.color, "#3B82F6")
  p.setColor(p.project(web)!, to: nil)
  expectEqual(p.project(web)?.color, nil, "back to default")

  p.delete(p.project(web)!)
  expectEqual(p.projects.map(\.id), [api], "deleted")
  let day = try! store.timesheet(DateInterval(start: at(0), end: at(0, day: 2)))
  expectEqual(day.entries.count, 2, "its time stays")
  check(day.entries.allSatisfy { $0.projectId == nil }, "unassigned")
}

print("\(count - failures)/\(count) checks passed")
exit(failures == 0 ? 0 : 1)
