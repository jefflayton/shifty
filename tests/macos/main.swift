// Tests for platforms/macos/Models, linked against the Zig core.
// Run with `zig build test-macos`.

import Foundation

NSTimeZone.default = TimeZone(identifier: "UTC")!
// The store's local time (scheduled breaks) comes from libc.
setenv("TZ", "UTC", 1)
tzset()
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
  expectEqual(AlarmRule(storeRow: rule.storeRow(), calendar: cal).fireDate(clockIn: at(9), clockOut: at(17), calendar: cal), at(16, 45), "set time round-trips by time of day")
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
  // Created in the same millisecond, so their order isn't fixed.
  expectEqual(Set([p.rank(of: web), p.rank(of: api)]), [0, 1], "a rank each")

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

// MARK: Tracking

do {
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let cli = try! ShiftStore(path: path)
  let t = TrackingModel(store: store)
  var changes = 0
  t.didChange = { changes += 1 }
  t.reload(now: at(9))
  check(t.running == nil, "not tracking")

  let web = try! store.createProject(name: "web")
  let api = try! store.createProject(name: "api")

  // Nothing running: picking a project starts it.
  t.choose(project: web, workspace: nil, now: at(9))
  t.reload(now: at(9, 30))
  expectEqual(t.running?.projectId, web, "started")
  expectEqual(t.running?.source, "menubar")
  expectEqual(changes, 1)
  let first = t.running!.id

  // Another project: the old timer stops and keeps its time.
  t.choose(project: api, workspace: nil, now: at(10))
  t.reload(now: at(10, 30))
  expectEqual(t.running?.projectId, api, "switched")
  check(t.running?.id != first, "new timer")
  let sheet = try! store.timesheet(DateInterval(start: at(0), end: at(0, day: 1)))
  expectEqual(sheet.entries.first { $0.id == first }?.end, at(10), "old one stopped")

  // Same project again: nothing changes.
  let current = t.running!.id
  t.choose(project: api, workspace: nil, now: at(11))
  expectEqual(t.running?.id, current, "same project, same timer")

  // A timer with no project, started elsewhere, gets the project.
  _ = try! cli.startEntry(project: nil, workspace: nil, now: at(12))
  t.reload(now: at(12, 30))
  check(t.running?.projectId == nil, "unassigned timer")
  let unassigned = t.running!.id
  t.choose(project: web, workspace: nil, now: at(12, 45))
  expectEqual(t.running?.id, unassigned, "assigned in place")
  expectEqual(t.running?.projectId, web)
  expectEqual(t.running?.start, at(12), "keeps its start")

  t.stop(now: at(13))
  t.reload(now: at(13, 30))
  check(t.running == nil, "stopped")

  expectEqual(t.createProject(named: "WEB"), web, "same name, same project")
  expectEqual(t.label(project: web, workspace: nil), "web")
}

// MARK: Lunch

do {
  var rule = LunchRule()
  check(rule.active == nil, "off by default")
  rule.isEnabled = true
  let r = rule.active!
  func span(_ s: Date, _ e: Date?) -> LunchPlan.Span { .init(start: s, end: e) }

  // 9 AM, an 8h shift: lunch between 12 and 2.
  let plain = r.plan(clockIn: at(9), worked: 8 * 3600, breaks: [], now: at(10))!
  expectEqual(plain.opens, at(12), "opens after 3h of work")
  expectEqual(plain.closes, at(14), "closes after 5h of work")
  expectEqual(plain.status(now: at(11)), .upcoming)
  expectEqual(plain.status(now: at(13)), .open)
  expectEqual(plain.status(now: at(14, 1)), .missed)

  // Five hours or less doesn't need lunch.
  check(r.plan(clockIn: at(9), worked: 5 * 3600, breaks: [], now: at(10)) == nil, "short shift")

  // A short break isn't lunch, and pushes the window later.
  let rest = r.plan(clockIn: at(9), worked: 8 * 3600, breaks: [span(at(10), at(10, 15))], now: at(11))!
  check(rest.lunch == nil, "15 min is a rest")
  expectEqual(rest.opens, at(12, 15))
  expectEqual(rest.closes, at(14, 15))

  // Lunch itself doesn't move the window it's in.
  let ate = r.plan(
    clockIn: at(9), worked: 8 * 3600, breaks: [span(at(10), at(10, 10)), span(at(13), at(13, 30))],
    now: at(15))!
  expectEqual(ate.lunch?.start, at(13), "30 min is lunch")
  expectEqual(ate.closes, at(14, 10))
  expectEqual(ate.status(now: at(15)), .taken)

  // Lunch alarms ring off the window, until you've had lunch.
  let opens = AlarmRule(trigger: .lunchOpens)
  let closing = AlarmRule(trigger: .beforeLunchCloses(minutes: 15))
  expectEqual(opens.fireDate(clockIn: at(9), clockOut: at(17), lunch: plain), at(12))
  expectEqual(closing.fireDate(clockIn: at(9), clockOut: at(17), lunch: plain), at(13, 45))
  check(opens.fireDate(clockIn: at(9), clockOut: at(17), lunch: ate) == nil, "quiet after lunch")
  check(closing.fireDate(clockIn: at(9), clockOut: at(17), lunch: nil) == nil, "quiet without a window")
  check(opens.isLunch && !AlarmRule(trigger: .atTime(at(12))).isLunch, "lunch kinds")
  for rule in [opens, closing] {
    check(
      AlarmRule.sameRule(AlarmRule(storeRow: rule.storeRow(), calendar: cal), rule),
      "\(rule.trigger) round-trips through the store")
  }
  expectEqual(LunchRule().quietReason(nil), "Lunch off")
  expectEqual(rule.quietReason(nil), "No lunch needed")
  expectEqual(rule.quietReason(ate), "Had lunch")

  let late = r.plan(clockIn: at(9), worked: 8 * 3600, breaks: [span(at(14, 30), at(15))], now: at(16))!
  expectEqual(late.status(now: at(16)), .late)

  let eating = r.plan(clockIn: at(9), worked: 8 * 3600, breaks: [span(at(12, 30), nil)], now: at(12, 40))!
  expectEqual(eating.status(now: at(12, 40)), .onLunch, "the break you're on counts")

  // Saved in whole minutes; turning it off keeps the window.
  var custom = rule
  custom.earliest = 3.5 * 3600
  let text = Preferences.format(custom)!
  check(text.contains("\"earliest_mins\":210"), "minutes: \(text)")
  expectEqual(Preferences.lunch(from: text), custom, "round trip")
  check(Preferences.format(LunchRule()) == nil, "the default isn't stored")

  // ShiftModel: the popover's shift, its breaks anchored by time of day.
  let model = ShiftModel()
  model.clockInTime = at(9)
  model.shiftLength = 8
  model.breaks = [brk(at(10), at(10, 10))]
  expectEqual(model.lunch(rule, now: at(11))?.opens, at(12, 10))
  check(model.lunch(LunchRule(), now: at(11)) == nil, "off")
  model.startBreak(now: at(12, 30))
  expectEqual(model.lunch(rule, now: at(12, 40))?.status(now: at(12, 40)), .onLunch)

  let bar = ShiftSummary.span(plain, clockIn: at(9), clockOut: at(17), now: at(10))!
  expectEqual(bar, 0.375...0.625, "window as fractions of the shift")
  check(ShiftSummary.span(ate, clockIn: at(9), clockOut: at(17), now: at(15)) == nil, "hidden once eaten")
}

// MARK: Work days

do {
  expectEqual(Preferences.isoWeekday(at(0), calendar: cal), 3, "Oct 28 2026 is a Wednesday")
  expectEqual(Preferences.isoWeekday(at(0, day: 4), calendar: cal), 7, "Sunday")
  expectEqual(Preferences.format([1, 2, 3, 4, 5]), "1,2,3,4,5")
  check(Preferences.format(Preferences.everyDay) == nil, "every day isn't stored")
  expectEqual(Preferences.workDays(from: "5,1, 3,9"), [1, 3, 5])
  expectEqual(Preferences.weekOrder(cal), [7, 1, 2, 3, 4, 5, 6], "gregorian weeks start Sunday")
  var monday = cal
  monday.firstWeekday = 2
  expectEqual(Preferences.weekOrder(monday), [1, 2, 3, 4, 5, 6, 7])

  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let defaults = UserDefaults(suiteName: "shifty-tests-\(UUID().uuidString)")!
  let prefs = Preferences(defaults: defaults, store: store)
  expectEqual(prefs.workDays, Preferences.everyDay, "every day by default")
  prefs.workDays = [1, 2, 3, 4, 5]
  prefs.lunch.isEnabled = true
  expectEqual(try! store.setting(Preferences.workDaysSetting), "1,2,3,4,5", "shared through the store")
  let again = Preferences(defaults: defaults, store: store)
  expectEqual(again.workDays, [1, 2, 3, 4, 5])
  check(again.lunch.isEnabled, "lunch saved")
  try! store.setSetting(Preferences.workDaysSetting, "1,2,3,4")
  again.pull()
  expectEqual(again.workDays, [1, 2, 3, 4], "picked up from the TUI or CLI")
}

// MARK: Timesheet shifts

do {
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let defaults = UserDefaults(suiteName: "shifty-tests-\(UUID().uuidString)")!
  let prefs = Preferences(defaults: defaults, store: store)
  prefs.workDays = [1, 2, 3, 4, 5]
  prefs.lunch.isEnabled = true
  let t = TimesheetModel(store: store, preferences: prefs, calendar: cal, now: at(12))
  var changes = 0
  t.didChange = { changes += 1 }

  // Sunday and Saturday are hidden while they're empty.
  expectEqual(t.visibleDays, (1...5).map { at(0, day: $0 - 3) }, "Monday to Friday")
  expectEqual(t.hiddenDays.count, 2)

  // Clocked in at 8; tracked 8:30 to 4; clocked out at 5, lunch 12 to 12:30.
  let shift = try! store.addShift(start: at(8), end: at(17))
  try! store.putBreak(.init(id: UUID(), start: at(12), end: at(12, 30)), shift: shift)
  _ = try! store.addEntry(project: nil, workspace: nil, start: at(8, 30), end: at(16))
  t.reload()
  var s = t.shifts(on: at(0)).first!
  expectEqual(s.id, shift)
  expectEqual(t.worked(s, now: at(18)), 8.5 * 3600, "9h less a half-hour break")
  expectEqual(t.onBreak(s, now: at(18)), 30 * 60)
  expectEqual(t.untracked(s, now: at(18)), 1.5 * 3600, "8 to 8:30 and 4 to 5")
  expectEqual(t.lunch(of: s, now: at(18))?.status(now: at(18)), .taken)
  expectEqual(t.worked(now: at(18)), 8.5 * 3600)

  // Move clock in and out.
  t.setStart(s, to: at(7, 45))
  s = t.shifts(on: at(0)).first!
  expectEqual(s.start, at(7, 45))
  expectEqual(s.end, at(17), "clock out stays")
  t.setEnd(s, to: at(17, 30))
  s = t.shifts(on: at(0)).first!
  expectEqual(s.end, at(17, 30))
  check(changes >= 2, "the popover hears about it")

  // An impossible clock out stays a draft.
  t.setStart(s, to: at(6))
  t.setEnd(s, to: at(23, 30))
  check(t.drafts[shift] != nil, "17.5h shift is a draft")
  expectEqual(t.shifts(on: at(0)).first!.end, at(17, 30), "store unchanged")
  t.setEnd(s, to: at(17))
  check(t.drafts[shift] == nil, "fixed")
  s = t.shifts(on: at(0)).first!
  expectEqual(s.start, at(6))

  // Breaks: move, add one at the lunch window, delete.
  let lunch = s.breaks.first!
  t.setStart(lunch, of: s, to: at(12, 15))
  s = t.shifts(on: at(0)).first!
  expectEqual(s.breaks.first!.start, at(12, 15))
  expectEqual(s.breaks.first!.end, at(12, 30), "end stays")
  t.setEnd(s.breaks.first!, of: s, to: at(12, 45))
  s = t.shifts(on: at(0)).first!
  expectEqual(s.breaks.first!.end, at(12, 45))
  t.delete(s.breaks.first!)
  s = t.shifts(on: at(0)).first!
  check(s.breaks.isEmpty, "break deleted")
  t.addBreak(to: s, now: at(18))
  s = t.shifts(on: at(0)).first!
  expectEqual(s.breaks.first?.start, at(9), "at the lunch window: 3h after 6 AM")
  expectEqual(s.breaks.first?.end, at(9, 30))

  // A day off with time on it shows.
  _ = try! store.addShift(start: at(9, day: 3), end: at(13, day: 3))
  t.reload()
  check(t.visibleDays.contains(at(0, day: 3)), "Saturday with a shift shows")

  // Adding a shift: around the day's time, or 9 to 5, never ahead of now.
  _ = try! store.addEntry(project: nil, workspace: nil, start: at(10, 5, day: 1), end: at(14, 50, day: 1))
  t.reload()
  let slot = t.shiftSlot(on: at(0, day: 1), now: at(12, day: 2))!
  expectEqual(slot.0, at(10, day: 1), "from the first entry, to the quarter before")
  expectEqual(slot.1, at(15, day: 1), "to the last, the quarter after")
  let plain = t.shiftSlot(on: at(0, day: 2), now: at(20, day: 2))!
  expectEqual(plain.0, at(9, day: 2))
  expectEqual(plain.1, at(17, day: 2))
  expectEqual(t.shiftSlot(on: at(0, day: 2), now: at(12, day: 2))!.1, at(12, day: 2), "ends now")
  check(t.shiftSlot(on: at(0, day: 2), now: at(12, day: 1)) == nil, "not tomorrow")
  let added = t.addShift(on: at(0, day: 2), now: at(20, day: 2))!
  check(t.sheet.shifts.contains { $0.id == added }, "added")
  t.delete(t.sheet.shifts.first { $0.id == added }!)
  check(!t.sheet.shifts.contains { $0.id == added }, "deleted")

  // The shift you're on: clock in moves, clock out is now.
  _ = try! store.startShift(at: at(8, day: 1), lengthSeconds: 8 * 3600)
  t.reload()
  var open = t.shifts(on: at(0, day: 1)).first!
  t.setStart(open, to: at(7, 30))
  open = t.shifts(on: at(0, day: 1)).first!
  expectEqual(open.start, at(7, 30, day: 1))
  check(open.end == nil, "still on it")
  expectEqual(try! store.currentShift()?.lengthSeconds, 8 * 3600, "length kept")
  t.clockOut(now: at(16, day: 1))
  expectEqual(t.shifts(on: at(0, day: 1)).first!.end, at(16, day: 1), "clocked out")

  expectEqual(TimesheetModel.roundedToQuarter(at(10, 5), calendar: cal, up: true), at(10, 15))
  expectEqual(TimesheetModel.roundedToQuarter(at(10, 15), calendar: cal, up: true), at(10, 15))
  expectEqual(TimesheetModel.roundedToQuarter(at(10, 14), calendar: cal, up: false), at(10))

  let spans = Spans.subtract([(at(8), at(17))], [(at(12), at(13)), (at(16), at(18))])
  expectEqual(spans.map(\.0), [at(8), at(13)])
  expectEqual(spans.map(\.1), [at(12), at(16)])
}


// MARK: Break presets

do {
  // Scheduled breaks live in the store, beside the lunch window.
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let defaults = UserDefaults(suiteName: "shifty-tests-\(UUID().uuidString)")!
  let prefs = Preferences(defaults: defaults, store: store)
  check(prefs.scheduledBreaks.isEmpty, "none by default")
  check(!prefs.lunch.isEnabled, "lunch off by default")

  // Class on Tuesdays and Thursdays, 11 to 2.
  var cls = ScheduledBreak(name: "Class", weekdays: [2, 4], start: 11 * 3600, end: 14 * 3600)
  prefs.scheduledBreaks.append(cls)
  prefs.lunch.isEnabled = true
  let again = Preferences(defaults: defaults, store: store)
  expectEqual(again.scheduledBreaks, [cls], "saved")
  check(again.lunch.isEnabled, "lunch is a preset beside it")
  expectEqual(try! store.breakPresets().map(\.name), ["Lunch", "Class"])

  cls.end = 13 * 3600
  again.scheduledBreaks[0] = cls
  prefs.pull()
  expectEqual(prefs.scheduledBreaks.first?.end, 13 * 3600, "edits picked up elsewhere")

  // An invalid one isn't saved until it's fixed.
  var bad = ScheduledBreak(name: "Oops", weekdays: [2], start: 15 * 3600, end: 14 * 3600)
  prefs.scheduledBreaks.append(bad)
  expectEqual(try! store.breakPresets().count, 2, "invalid not saved")
  bad.end = 16 * 3600
  prefs.scheduledBreaks[1] = bad
  expectEqual(try! store.breakPresets().count, 3, "saved once valid")
  prefs.scheduledBreaks.removeAll { $0.id == bad.id }
  expectEqual(try! store.breakPresets().count, 2, "deleted")

  // Thursday Oct 29: a draft rolling to a new day gets class.
  let m = ShiftModel()
  m.store = store
  m.clockInTime = at(9, day: -1)
  m.breaks = [brk(at(12, day: -1), at(13, day: -1))]
  m.rollOverIfStale(now: at(8, day: 1), calendar: cal)
  expectEqual(m.clockInTime, at(9, day: 1))
  expectEqual(m.breaks.map(\.inDate), [at(11, day: 1)], "class instead of yesterday's breaks")
  expectEqual(m.breaks.map(\.outDate), [at(13, day: 1)])
  expectEqual(m.clockOut(now: at(8, day: 1)), at(19, day: 1), "class pushes clock out")

  // Clocking in from the menu bar brings the draft's breaks, not a second
  // copy of class.
  m.clockInNow(now: at(9, day: 1))
  let shift = try! store.currentShift()!
  expectEqual(try! store.breaks(of: shift.id).count, 1, "class once")

  // Friday: no class.
  m.clockOutNow(now: at(19, day: 1))
  m.rollOverIfStale(now: at(8, day: 2), calendar: cal)
  check(m.breaks.isEmpty, "no class on Friday")
}

do {
  // The next break, for the menu bar and alarms.
  let m = ShiftModel()
  m.clockInTime = at(9)
  m.shiftLength = 8
  m.breaks = [brk(at(15), at(15, 15)), brk(at(11), at(14))]
  expectEqual(m.untilBreak(now: at(10)), at(11), "counts to the next break")
  expectEqual(m.untilBreak(now: at(12)), at(14), "on one, counts to when it's over")
  check(m.isInPlannedBreak(now: at(12)), "in a planned break")
  check(!m.isInPlannedBreak(now: at(14, 30)), "between breaks")
  expectEqual(m.untilBreak(now: at(14, 30)), at(15))
  check(m.untilBreak(now: at(16)) == nil, "none left")

  let d = MenuBarDisplay.untilBreak
  expectEqual(d.title(clockOut: at(20, 15), now: at(10), nextBreak: at(11)), "1h 0m")
  expectEqual(d.title(clockOut: at(20, 15), now: at(16), nextBreak: nil), "4h 15m", "falls back to time left")
  check(d.title(clockOut: at(20, 15), now: at(21), nextBreak: nil) == nil, "nothing after the shift")

  // Break alarms ring off the next break, before it starts or ends.
  let spans = m.anchoredBreaks()
  let before = AlarmRule(trigger: .beforeBreak(minutes: 10))
  let back = AlarmRule(trigger: .beforeBreakEnds(minutes: 0))
  expectEqual(before.fireDate(clockIn: at(9), clockOut: at(20, 15), breaks: spans, now: at(10)), at(10, 50))
  expectEqual(before.fireDate(clockIn: at(9), clockOut: at(20, 15), breaks: spans, now: at(12)), at(14, 50), "then the next one")
  expectEqual(back.fireDate(clockIn: at(9), clockOut: at(20, 15), breaks: spans, now: at(10)), at(14))
  check(before.fireDate(clockIn: at(9), clockOut: at(20, 15), breaks: spans, now: at(16)) == nil, "no break ahead")
  check(before.isBreak && back.isBreak && !before.isLunch, "break kinds")
  expectEqual(before.title, "10 min until break")
  expectEqual(back.title, "Break's over")

  // They round-trip through the store, and so do lunch alarms.
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let model = ShiftModel()
  model.store = store
  model.alarms = [before, back, AlarmRule(trigger: .lunchOpens), AlarmRule(trigger: .beforeLunchCloses(minutes: 15))]
  model.push(now: at(9))
  let rows = try! store.alarmRules()
  expectEqual(rows.count, 4, "all saved")
  let lunchID = try! store.breakPresets().first!.id
  expectEqual(rows.filter { UUID($0.preset_id) == lunchID }.count, 2, "lunch alarms name the lunch window")
  let pulled = ShiftModel()
  pulled.store = store
  pulled.pull()
  check(pulled.alarms.elementsEqual(model.alarms, by: AlarmRule.sameRule), "round trip")
}

print("\(count - failures)/\(count) checks passed")
exit(failures == 0 ? 0 : 1)
