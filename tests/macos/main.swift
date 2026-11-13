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

/// Settings for one test, emptied first. Every test shares these few names:
/// macOS keeps a domain's file even once it's emptied, so a fresh name per
/// test would leave a file in ~/Library/Preferences for each one.
func testDefaults(_ name: String = "shifty-tests") -> UserDefaults {
  UserDefaults.standard.removePersistentDomain(forName: name)
  return UserDefaults(suiteName: name)!
}

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
  let defaults = testDefaults()

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

  let empty = ShiftModel.load(from: testDefaults("shifty-tests-none"))
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
expectEqual(ShiftSummary.relative(at(17), now: at(17, 12), isClockedIn: true), "12 min over")
expectEqual(ShiftSummary.relative(at(17, 30), now: at(14, 18), isClockedIn: true), "in 3 hr 12 min")

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
  check(MenuBarDisplay.timeLeft.title(clockOut: at(17), now: at(17, 1)) == nil, "draft over")
  check(MenuBarDisplay.clockOut.title(clockOut: at(17), now: at(17, 1)) == nil, "draft over")

  // Clocked in, past clock out counts up, and the clock-out time stays.
  let over = { (d: MenuBarDisplay, now: Date) in
    d.title(clockOut: at(17), now: now, isClockedIn: true)
  }
  expectEqual(over(.timeLeft, at(17, 25)), "+25m")
  expectEqual(over(.timeLeft, at(18, 5)), "+1h 5m")
  expectEqual(over(.timeLeft, at(17).addingTimeInterval(20)), "+1m", "rounds up")
  expectEqual(over(.timeLeft, at(17)), "+1m", "never +0m")
  expectEqual(over(.untilBreak, at(17, 25)), "+25m", "no break left")
  expectEqual(over(.clockOut, at(17, 25)), at(17).formatted(date: .omitted, time: .shortened))
  expectEqual(over(.clockOutThenOver, at(17, 25)), "+25m", "then time over")
  expectEqual(
    over(.clockOutThenOver, at(16, 50)), at(17).formatted(date: .omitted, time: .shortened),
    "clock-out time until then")
  check(
    MenuBarDisplay.clockOutThenOver.title(clockOut: at(17), now: at(17, 25)) == nil, "draft over")
  check(over(.iconOnly, at(17, 25)) == nil, "icon only")
  expectEqual(over(.timeLeft, at(16, 50)), "10m", "before clock out, as before")

  let defaults = testDefaults()
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

  let defaults = testDefaults()
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
  let defaults = testDefaults()

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
  let defaults = testDefaults()
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

do {
  // Clocking in uses the clock-out link unless it has one of its own, and
  // the menu bar asks before opening either until told otherwise.
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let defaults = testDefaults()
  let store = try! ShiftStore(path: path)
  let prefs = Preferences(defaults: defaults, store: store)
  let out = URL(string: "https://example.com/out")!
  let inn = URL(string: "https://example.com/in")!

  check(prefs.clockInLink == nil, "no link, no clock-in link")
  expectEqual(prefs.clockLinkAction(clockingIn: true), .none, "nothing to open")
  prefs.clockOutLink = out
  expectEqual(prefs.clockInLink, out, "falls back to the clock-out link")
  expectEqual(prefs.clockLinkMode, .ask, "asks by default")
  expectEqual(prefs.clockLinkAction(clockingIn: true), .ask(out))

  prefs.separateClockInLink = inn
  expectEqual(try! store.setting(Preferences.clockInLinkSetting), "https://example.com/in", "shared with the TUI and CLI")
  expectEqual(Preferences(defaults: defaults, store: store).clockInLink, inn, "kept")
  expectEqual(prefs.clockLinkAction(clockingIn: true), .ask(inn), "its own link")
  expectEqual(prefs.clockLinkAction(clockingIn: false), .ask(out), "clocking out keeps its own")

  prefs.clockLinkMode = .always
  expectEqual(Preferences(defaults: defaults, store: store).clockLinkMode, .always, "mode kept")
  expectEqual(prefs.clockLinkAction(clockingIn: false), .open(out))
  prefs.clockLinkMode = .never
  expectEqual(prefs.clockLinkAction(clockingIn: false), .none, "don't open")

  try! ShiftStore(path: path).setSetting(Preferences.clockInLinkSetting, nil)
  prefs.pull()
  expectEqual(prefs.clockInLink, out, "cleared elsewhere, back to the clock-out link")
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
  expectEqual(rule.quietReason(nil), "Not needed")
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
  let defaults = testDefaults()
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

do {
  // Snooze length: five minutes until changed, kept in the store, picked up
  // from elsewhere, and held to one minute to an hour.
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let defaults = UserDefaults(suiteName: "shifty-tests-\(UUID().uuidString)")!
  let prefs = Preferences(defaults: defaults, store: store)
  expectEqual(prefs.snoozeLength, 5 * 60, "five minutes by default")
  check(try! store.setting(Preferences.snoozeSetting) == nil, "default isn't stored")
  prefs.snoozeLength = 10 * 60
  expectEqual(try! store.setting(Preferences.snoozeSetting), "600", "shared through the store")
  expectEqual(Preferences(defaults: defaults, store: store).snoozeLength, 10 * 60, "kept")
  try! store.setSetting(Preferences.snoozeSetting, "120")
  prefs.pull()
  expectEqual(prefs.snoozeLength, 2 * 60, "picked up from the TUI or CLI")
  prefs.snoozeLength = Preferences.defaultSnooze
  check(try! store.setting(Preferences.snoozeSetting) == nil, "back to the default clears it")
  expectEqual(Preferences.snooze(from: "5"), 60, "under a minute rounds up to one")
  expectEqual(Preferences.snooze(from: "99999"), 3600, "over an hour comes down to one")
  check(Preferences.snooze(from: "soon") == nil, "not a number")

  let local = UserDefaults(suiteName: "shifty-tests-\(UUID().uuidString)")!
  Preferences(defaults: local).snoozeLength = 15 * 60
  expectEqual(Preferences(defaults: local).snoozeLength, 15 * 60, "kept without a store")
}

do {
  // Weekly goal: off until set, kept in the store as seconds (what
  // `shifty goal` writes), picked up from elsewhere, and measured against
  // the week with today's open shift.
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let defaults = testDefaults()
  let prefs = Preferences(defaults: defaults, store: store)
  check(prefs.weeklyGoal == nil, "no goal by default")
  check(try! store.weekGoal(weekStart: at(0, day: -3), now: at(12)) == nil, "nothing to measure")
  prefs.weeklyGoal = 20 * 60 * 60
  expectEqual(try! store.setting(Preferences.weeklyGoalSetting), "72000", "shared through the store")
  expectEqual(Preferences(defaults: defaults, store: store).weeklyGoal, 20 * 60 * 60, "kept")
  try! store.setSetting(Preferences.weeklyGoalSetting, "36000")
  prefs.pull()
  expectEqual(prefs.weeklyGoal, 10 * 60 * 60, "picked up from the TUI or CLI")
  check(Preferences.goal(from: "0") == nil, "zero is no goal")
  check(Preferences.goal(from: "20h") == nil, "seconds only, as stored")
  expectEqual(Preferences.goal(from: "99999999"), 7 * 24 * 60 * 60, "at most a week")

  // On a 4h shift since 9, three hours in, against the 10h goal.
  _ = try! store.startShift(at: at(9), lengthSeconds: 4 * 60 * 60)
  let goal = try! store.weekGoal(weekStart: at(0, day: -3), now: at(12))!
  expectEqual(goal.worked, 3 * 60 * 60)
  expectEqual(goal.left, 7 * 60 * 60)
  expectEqual(goal.leftAfterClockOut, 6 * 60 * 60, "an hour of the shift to go")
  expectEqual(goal.metAt, at(19), "seven more hours")
  expectEqual(goal.detail, "6h after today")
  prefs.weeklyGoal = 2 * 60 * 60
  let met = try! store.weekGoal(weekStart: at(0, day: -3), now: at(12))!
  check(met.isMet, "met")
  expectEqual(met.over, 60 * 60)
  check(met.metAt == nil, "nothing to wait for")
  expectEqual(met.detail, "Goal met")
  prefs.weeklyGoal = 3.5 * 60 * 60
  let today = try! store.weekGoal(weekStart: at(0, day: -3), now: at(12))!
  expectEqual(today.leftAfterClockOut, 0, "today's shift gets there")
  expectEqual(today.metAt, at(12, 30))
  prefs.weeklyGoal = nil
  check(try! store.setting(Preferences.weeklyGoalSetting) == nil, "off clears it")
}

// MARK: Timesheet shifts

do {
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let defaults = testDefaults()
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

do {
  // Starting a break: the popover's timeline can draw with a `now` from its
  // last tick, before the break began. That once trapped ("Range requires
  // lowerBound <= upperBound") on macOS 27.
  var rule = LunchRule()
  rule.isEnabled = true
  let plan = rule.plan(
    clockIn: at(9), worked: 8 * 3600, breaks: [.init(start: at(12, 0), end: nil)], now: at(12))!
  let stale = at(11, 59)
  check(ShiftSummary.lunchBreak(plan, clockIn: at(9), clockOut: at(17), now: stale) == nil, "nothing to draw yet")
  check(ShiftSummary.lunchBreak(plan, clockIn: at(9), clockOut: at(17), now: at(12, 30)) != nil, "drawn once it's going")

  let model = ShiftModel()
  model.clockInTime = at(9)
  model.startBreak(now: at(12))
  check(model.lunch(rule, now: stale) != nil, "planning with a stale now is fine")
}

// MARK: Break presets

do {
  // Scheduled breaks live in the store, beside the lunch window.
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let defaults = testDefaults()
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

do {
  // A scheduled break made today can be added to today's shift by hand.
  // Wednesday Oct 28, 9 to 5.
  let m = ShiftModel()
  m.clockInTime = at(9)
  m.shiftLength = 8
  let today = ScheduledBreak(name: "Class", weekdays: [3], start: 14 * 3600, end: 15 * 3600)
  let added = m.todayBreak(for: today, now: at(10), calendar: cal)
  expectEqual(added?.inDate, at(14), "today's times")
  expectEqual(added?.outDate, at(15))

  var tomorrow = today
  tomorrow.weekdays = [4]
  check(m.todayBreak(for: tomorrow, now: at(10), calendar: cal) == nil, "not today's weekday")
  var off = today
  off.isEnabled = false
  check(m.todayBreak(for: off, now: at(10), calendar: cal) == nil, "turned off")
  check(m.todayBreak(for: today, now: at(15, 30), calendar: cal) == nil, "already over")
  var early = today
  early.start = 8 * 3600
  early.end = 10 * 3600
  expectEqual(m.todayBreak(for: early, now: at(9, 30), calendar: cal)?.inDate, at(9), "cut to clock in")
  var late = today
  late.start = 18 * 3600
  late.end = 19 * 3600
  check(m.todayBreak(for: late, now: at(10), calendar: cal) == nil, "after clock out")
  check(m.todayBreak(for: today, now: at(10, day: 1), calendar: cal) == nil, "the shift isn't today's")

  check(m.addToday(today, now: at(10), calendar: cal), "added")
  expectEqual(m.breaks.map(\.inDate), [at(14)])
  check(m.todayBreak(for: today, now: at(10), calendar: cal) == nil, "not twice")
  check(!m.addToday(today, now: at(10), calendar: cal), "second add does nothing")
  var overlapping = today
  overlapping.start = 14.5 * 3600
  overlapping.end = 16 * 3600
  check(m.todayBreak(for: overlapping, now: at(10), calendar: cal) == nil, "overlaps a break")
  m.startBreak(now: at(16, 30))
  var during = today
  during.start = 16 * 3600
  during.end = 17 * 3600
  check(m.todayBreak(for: during, now: at(16, 40), calendar: cal) == nil, "overlaps the break you're on")
}

do {
  // A planned break stops the timer where it begins.
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let m = ShiftModel()
  m.store = store
  m.clockInTime = at(9)
  m.breaks = [brk(at(11), at(14))]
  m.clockInNow(now: at(9))
  let tracking = TrackingModel(store: store)
  var changed = 0
  tracking.didChange = { changed += 1 }
  try! store.startEntry(project: nil, workspace: nil, now: at(9))
  tracking.reload(now: at(9))

  tracking.stopForBreaks(m.anchoredBreaks(), now: at(10))
  check(tracking.running != nil, "still working before class")
  expectEqual(changed, 0, "nothing written")
  tracking.stopForBreaks(m.anchoredBreaks(), now: at(11, 1))
  check(tracking.running == nil, "stopped for class")
  expectEqual(changed, 1, "the shift hears about it")
  expectEqual(try! store.timesheet(DateInterval(start: at(0), end: at(23))).entries.first?.end, at(11), "ended when class began")
}

do {
  // Days fold down to their header, one at a time or all at once.
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let t = TimesheetModel(store: store, calendar: cal, now: at(12))
  _ = try! store.addEntry(project: nil, workspace: nil, start: at(9), end: at(10))
  _ = try! store.addEntry(project: nil, workspace: nil, start: at(9, day: -1), end: at(10, day: -1))
  t.reload()
  let now = at(12)
  check(!t.isCollapsed(at(0), now: now), "today starts open")
  check(t.isCollapsed(at(0, day: -1), now: now), "other days start folded")
  t.toggleCollapsed(at(0), now: now)
  check(t.isCollapsed(at(0), now: now), "folded")
  t.toggleCollapsed(at(0, day: -1), now: now)
  check(!t.isCollapsed(at(0, day: -1), now: now), "opened")
  check(t.isCollapsed(at(0), now: now), "only that day")
  t.toggleCollapsed(at(0, day: -1), all: true, now: now)
  check(t.isCollapsed(at(0), now: now) && t.isCollapsed(at(0, day: -1), now: now), "all folded")
  check(!t.isCollapsed(at(0, day: 1), now: now), "a day with nothing on it has nothing to fold")
  t.toggleCollapsed(at(0), all: true, now: now)
  check(!t.isCollapsed(at(0), now: now) && !t.isCollapsed(at(0, day: -1), now: now), "all open")
  t.toggleCollapsed(at(0), now: now)
  t.expand(at(0))
  check(!t.isCollapsed(at(0), now: now), "opened to jump to it")
}

do {
  // Time past a shift's length shows as over, by shift and for the week.
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let t = TimesheetModel(store: store, calendar: cal, now: at(12))
  // A shift added after the fact is as long as it ran: 8 to 4, 8 hr.
  _ = try! store.addShift(start: at(8), end: at(16))
  _ = try! store.addShift(start: at(8, day: -1), end: at(16, day: -1))
  t.reload()
  var s = t.shifts(on: at(0)).first!
  expectEqual(t.over(s, now: at(18)), 0, "on time")

  t.setEnd(s, to: at(16, 25))
  s = t.shifts(on: at(0)).first!
  expectEqual(t.over(s, now: at(18)), 25 * 60, "stayed 25 min")
  expectEqual(t.over(now: at(18)), 25 * 60, "the week adds up shifts")

  t.setEnd(s, to: at(16).addingTimeInterval(30))
  s = t.shifts(on: at(0)).first!
  expectEqual(t.over(s, now: at(18)), 0, "under a minute isn't over")

  try! store.putBreak(.init(id: UUID(), start: at(12), end: at(12, 30)), shift: s.id)
  t.reload()
  s = t.shifts(on: at(0)).first!
  expectEqual(t.over(s, now: at(18)), 0, "short isn't negative")
}

do {
  // After midnight the new day is the open one; days you opened or folded
  // stay that way.
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let t = TimesheetModel(store: store, calendar: cal, now: at(12))
  for d in [-1, 0, 1] {
    _ = try! store.addEntry(project: nil, workspace: nil, start: at(9, day: d), end: at(10, day: d))
  }
  t.reload()
  t.toggleCollapsed(at(0, day: -1), now: at(12))
  let tomorrow = at(8, day: 1)
  check(!t.isCollapsed(at(0, day: 1), now: tomorrow), "the new today opens")
  check(t.isCollapsed(at(0), now: tomorrow), "yesterday folds")
  check(!t.isCollapsed(at(0, day: -1), now: tomorrow), "a day you opened stays open")
}

// MARK: Timesheet undo

do {
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let t = TimesheetModel(store: store, calendar: cal, now: at(12))
  let undo = UndoManager()
  undo.groupsByEvent = false
  t.undoManager = undo
  func step(_ body: () -> Void) {
    undo.beginUndoGrouping()
    body()
    undo.endUndoGrouping()
  }

  let shift = try! store.addShift(start: at(8), end: at(17))
  let lunch = UUID()
  try! store.putBreak(.init(id: lunch, start: at(12), end: at(12, 30)), shift: shift)
  let entry = try! store.addEntry(project: nil, workspace: nil, start: at(9), end: at(10))
  t.reload()
  func theEntry() -> ShiftStore.Entry? { t.sheet.entries.first { $0.id == entry } }
  func theShift() -> ShiftStore.SheetShift? { t.sheet.shifts.first { $0.id == shift } }

  // Deleting an entry undoes and redoes, keeping its id.
  step { t.delete(theEntry()!) }
  check(theEntry() == nil, "entry deleted")
  expectEqual(undo.undoActionName, "Delete Time")
  undo.undo()
  expectEqual(theEntry()?.end, at(10), "undo brings the entry back as it was")
  check(undo.canRedo, "redo is offered")
  undo.redo()
  check(theEntry() == nil, "redo deletes it again")
  undo.undo()

  // A time typed in steps undoes at once.
  step { t.setEnd(theEntry()!, to: at(10, 3)) }
  // Joins the step above, so registers nothing; outside a test, groups by
  // event open only when something registers.
  t.setEnd(theEntry()!, to: at(10, 30))
  expectEqual(theEntry()?.end, at(10, 30))
  undo.undo()
  expectEqual(theEntry()?.end, at(10), "one undo for a time typed in steps")

  step { t.setNote(theEntry()!, to: "standup") }
  expectEqual(undo.undoActionName, "Change Note")
  undo.undo()
  expectEqual(theEntry()?.note, nil, "undo clears the note again")

  // A deleted shift comes back with its breaks.
  step { t.delete(theShift()!) }
  check(theShift() == nil, "shift deleted")
  undo.undo()
  expectEqual(theShift()?.breaks.map(\.id), [lunch], "undo restores the shift and its break")

  step { t.setEnd(theShift()!, to: at(18)) }
  undo.undo()
  expectEqual(theShift()?.end, at(17), "undo moves clock out back")

  // Breaks: a change, a delete, an add.
  step { t.setEnd(theShift()!.breaks[0], of: theShift()!, to: at(13)) }
  expectEqual(theShift()?.breaks.first?.end, at(13))
  undo.undo()
  expectEqual(theShift()?.breaks.first?.end, at(12, 30), "undo puts the break's end back")
  step { t.delete(theShift()!.breaks[0]) }
  check(theShift()?.breaks.isEmpty == true, "break deleted")
  undo.undo()
  expectEqual(theShift()?.breaks.count, 1, "undo restores the break")
  var added: UUID?
  step { added = t.addBreak(to: theShift()!, now: at(18)) }
  expectEqual(theShift()?.breaks.count, 2)
  expectEqual(undo.undoActionName, "Add Break")
  undo.undo()
  check(theShift()?.breaks.contains { $0.id == added } == false, "undo removes an added break")
}

// MARK: Timesheet rows and selection

do {
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let t = TimesheetModel(store: store, calendar: cal, now: at(12))
  let shift = try! store.addShift(start: at(8), end: at(17))
  let lunch = UUID()
  try! store.putBreak(.init(id: lunch, start: at(12), end: at(12, 30)), shift: shift)
  let morning = try! store.addEntry(project: nil, workspace: nil, start: at(9), end: at(11))
  let afternoon = try! store.addEntry(project: nil, workspace: nil, start: at(13), end: at(15))
  t.reload()

  // Breaks sit among the entries, in order.
  expectEqual(
    t.rows(on: at(0)).map(\.id), [.entry(morning), .brk(lunch), .entry(afternoon)],
    "entries and breaks by start")
  expectEqual(
    t.items(now: at(12)), [.shift(shift), .entry(morning), .brk(lunch), .entry(afternoon)])
  expectEqual(t.day(of: .brk(lunch)), at(0))

  t.moveSelection(by: 1, now: at(12))
  expectEqual(t.selection, .shift(shift), "down with nothing selected picks the first")
  t.moveSelection(by: 2, now: at(12))
  expectEqual(t.selection, .brk(lunch))
  t.moveSelection(by: 5, now: at(12))
  expectEqual(t.selection, .entry(afternoon), "stops at the last")
  t.moveSelection(by: -1, now: at(12))
  expectEqual(t.text(of: t.selection!, now: at(12))?.hasPrefix("Break\t"), true, "break as text")

  // Deleting selects what took its place.
  t.deleteSelection(now: at(12))
  check(t.breakAndShift(lunch) == nil, "selected break deleted")
  expectEqual(t.selection, .entry(afternoon), "the next row is selected")
  t.deleteSelection(now: at(12))
  expectEqual(t.selection, .entry(morning), "the last row's delete selects the one above")
}

// MARK: Places and auto-switch

do {
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let web = try! store.createProject(name: "Web")
  let chat = try! store.createProject(name: "Chat")

  // A git repo, linked by its remote.
  let repo = NSTemporaryDirectory() + "shifty-tests-repo-\(UUID().uuidString)"
  defer { try? FileManager.default.removeItem(atPath: repo) }
  try! FileManager.default.createDirectory(
    atPath: repo + "/.git", withIntermediateDirectories: true)
  try! FileManager.default.createDirectory(
    atPath: repo + "/src", withIntermediateDirectories: true)
  try! "[remote \"origin\"]\n\turl = git@github.com:o/web.git\n".write(
    toFile: repo + "/.git/config", atomically: true, encoding: .utf8)

  var p = try! store.place(dir: repo + "/src", app: nil)
  check(p.target == nil, "an unlinked repo has no project")
  expectEqual(p.remote, "github.com/o/web")
  expectEqual(try! store.link(dir: repo + "/src", to: .init(project: web)), .git)
  try! store.link(app: "com.example.chat", to: .init(project: chat))
  p = try! store.place(dir: repo + "/src", app: "com.example.chat")
  expectEqual(p.via, .git, "the repo beats the app")
  expectEqual(p.target, .init(project: web))
  expectEqual(try! store.place(dir: nil, app: "com.example.chat").target, .init(project: chat))

  let links = try! store.links()
  expectEqual(links.map(\.externalId), ["github.com/o/web", "com.example.chat"])
  try! store.unlink(links[1])
  check(try! store.place(dir: nil, app: "com.example.chat").target == nil, "unlinked app")

  // The repo, shared with Chat: the first linked until Chat is tracked,
  // and a keyword in the window's title picks, whatever was tracked.
  try! store.link(dir: repo, to: .init(project: chat))
  p = try! store.place(dir: repo, app: nil)
  expectEqual(p.choices, 2, "a repo two projects share")
  expectEqual(p.target, .init(project: web))
  try! store.link(keyword: "  Chat ", to: .init(project: chat))
  p = try! store.place(dir: repo, app: "com.superlogical.rex", title: "chat — zsh")
  expectEqual(p.via, .keyword, "a Rex session named for the project")
  expectEqual(p.keyword, "chat")
  expectEqual(p.target, .init(project: chat))
  let shared = try! store.links().filter { $0.externalId == "github.com/o/web" }
  expectEqual(shared.count, 2)
  try! store.unlink(shared.first { $0.projectId == chat }!)
  expectEqual(try! store.place(dir: repo, app: nil).choices, 1, "Web keeps its link")
  try! store.unlink(try! store.links().first { $0.provider == "keyword" }!)

  check(try! store.spotsPath().hasSuffix("/here.tsv"), "the hook's record sits by the db")
  expectEqual(try! store.spots(), [], "no hook yet")

  // The Rex script's record: with Rex in front, its tab and session stand in
  // for its window's title, which can't say on a remote host.
  expectEqual(try! store.rexFocus(now: at(10)), nil, "no Rex record yet")
  let rexFile = ((path as NSString).deletingLastPathComponent as NSString)
    .appendingPathComponent("rex.tsv")
  defer { try? FileManager.default.removeItem(atPath: rexFile) }
  try! "\(Int64(at(9).timeIntervalSince1970))\tdevbox\tChat\tapi\n"
    .write(toFile: rexFile, atomically: true, encoding: .utf8)
  let focus = try! store.rexFocus(now: at(10))
  expectEqual(focus?.title, "api - Chat", "tab, then session, as Rex titles them")
  expectEqual(focus?.server, "devbox")
  expectEqual(try! store.rexFocus(now: at(10, day: 2)), nil, "a day-old record says nothing")
  let rexTitle = RexFollow.title(
    app: "com.superlogical.rex", window: "zsh ~ - remote", focus: focus)
  expectEqual(rexTitle, "api - Chat")
  expectEqual(
    RexFollow.title(app: "com.apple.Terminal", window: "zsh", focus: focus), "zsh",
    "only Rex's windows")
  try! store.link(keyword: "chat", to: .init(project: chat))
  expectEqual(
    try! store.place(dir: nil, app: "com.superlogical.rex", title: rexTitle).target,
    .init(project: chat), "the Rex session's keyword")
  try! store.unlink(try! store.links().first { $0.provider == "keyword" }!)

  // Auto-switch: a running timer on Web, then working somewhere that's Chat.
  let defaults = testDefaults()
  let prefs = Preferences(defaults: defaults)
  prefs.autoSwitch = true
  prefs.autoSwitchDelay = 30
  prefs.autoSwitchCountdown = 10
  let tracking = TrackingModel(store: store)
  tracking.choose(project: web, workspace: nil, now: at(9))
  tracking.reload(now: at(9, 1))
  let auto = AutoSwitchModel(tracking: tracking, preferences: prefs)
  let toChat = ShiftStore.Target(project: chat)

  auto.observe(toChat, place: "Chat", now: at(10))
  check(auto.offer == nil, "no offer before the delay")
  auto.observe(nil, place: "Safari", now: at(10, 0) + 20)
  check(auto.offer == nil, "an unknown place changes nothing")
  auto.observe(toChat, place: "Chat", now: at(10, 0) + 31)
  expectEqual(auto.offer?.name, "Chat", "offered after the delay")
  expectEqual(auto.offer?.from, "Web")
  expectEqual(auto.offer?.arrived, at(10), "from when you got there")
  auto.tick(now: at(10, 0) + 35)
  expectEqual(tracking.runningTarget, .init(project: web), "still counting down")
  auto.tick(now: at(10, 0) + 41)
  check(auto.offer == nil, "the countdown ran out")
  expectEqual(tracking.runningTarget, toChat, "switched")
  expectEqual(tracking.running?.start, at(10), "the new entry starts when you got there")
  expectEqual(auto.switched?.name, "Chat")

  auto.undoSwitch()
  tracking.reload(now: at(10, 1))
  expectEqual(tracking.runningTarget, .init(project: web), "undo puts Web back")
  expectEqual(tracking.running?.start, at(9), "running from where it was")
  check(auto.switched == nil, "undo dismisses")

  // Back where the timer's project is: the offer goes.
  auto.observe(toChat, place: "Chat", now: at(11))
  auto.observe(toChat, place: "Chat", now: at(11, 1))
  check(auto.offer != nil, "offered again")
  auto.observe(.init(project: web), place: "web", now: at(11, 2))
  check(auto.offer == nil, "back in Web's repo")

  // Keep holds off the same project.
  auto.observe(toChat, place: "Chat", now: at(12))
  auto.observe(toChat, place: "Chat", now: at(12, 1))
  auto.keep(now: at(12, 1))
  check(auto.offer == nil, "kept")
  auto.observe(toChat, place: "Chat", now: at(12, 10))
  auto.observe(toChat, place: "Chat", now: at(12, 20))
  check(auto.offer == nil, "not offered again so soon")
  auto.observe(toChat, place: "Chat", now: at(12, 40))
  auto.observe(toChat, place: "Chat", now: at(12, 41))
  check(auto.offer != nil, "offered once Keep wears off")
  auto.switchNow(now: at(12, 41))
  expectEqual(tracking.runningTarget, toChat, "Switch Now")

  // Off, or no timer: nothing.
  prefs.autoSwitch = false
  auto.observe(.init(project: web), place: "web", now: at(13))
  auto.observe(.init(project: web), place: "web", now: at(13, 5))
  check(auto.offer == nil, "off")
  prefs.autoSwitch = true
  tracking.stop(now: at(14))
  tracking.reload(now: at(14, 1))
  auto.observe(.init(project: web), place: "web", now: at(14, 1))
  auto.observe(.init(project: web), place: "web", now: at(14, 5))
  check(auto.offer == nil, "no timer running")

  // On shift with no timer: it offers to start one.
  var onShift: Date? = at(14)
  auto.onShiftSince = { onShift }
  auto.observe(toChat, place: "Chat", now: at(14, 20))
  auto.observe(toChat, place: "Chat", now: at(14, 21))
  expectEqual(auto.offer?.starts, true, "offers to start")
  check(auto.offer?.from == nil, "from nothing")
  auto.tick(now: at(14, 21) + 11)
  expectEqual(tracking.runningTarget, toChat, "started")
  expectEqual(tracking.running?.start, at(14, 20), "from when you got there")
  expectEqual(auto.switched?.started, true)
  auto.undoSwitch()
  tracking.reload(now: at(14, 33))
  check(tracking.running == nil, "undo takes the timer back")
  onShift = nil
  auto.observe(toChat, place: "Chat", now: at(14, 40))
  check(auto.offer == nil, "off shift (or on a break): nothing")
  auto.observe(toChat, place: "Chat", now: at(14, 45))
  check(auto.offer == nil, "still nothing")

  // An unassigned timer just gets the project.
  tracking.choose(project: nil, workspace: nil, now: at(15))
  tracking.reload(now: at(15, 1))
  let undo = tracking.switchTo(toChat, since: at(15, 30), now: at(15, 31))
  expectEqual(tracking.runningTarget, toChat)
  expectEqual(tracking.running?.start, at(15), "all of it")
  undo?()
  tracking.reload(now: at(15, 32))
  check(tracking.running != nil && tracking.runningTarget == nil, "undo unassigns it")
}

// MARK: Teams meetings

do {
  expectEqual(Meetings.name(fromTitle: "Shifty sync | Microsoft Teams"), "Shifty sync")
  expectEqual(Meetings.name(fromTitle: "Chat | Situ | Microsoft Teams"), "Chat | Situ")
  check(Meetings.name(fromTitle: " | Microsoft Teams") == nil, "only Teams' own name")
  check(Meetings.isTeams("com.microsoft.teams2"), "new Teams")
  check(Meetings.isTeams("com.microsoft.teams"), "classic Teams")
  check(Meetings.isTeams("com.microsoft.teams2.helper"), "one of its helpers")
  check(!Meetings.isTeams("com.microsoft.teamsplus"), "not a lookalike")
  check(!Meetings.isTeams(nil), "no bundle")
  check(
    Meetings.isTeams(path: "/Applications/Microsoft Teams.app/Contents/MacOS/MSTeams"),
    "by its path")
  expectEqual(
    Meetings.ordered(["Chat | Microsoft Teams", "Sync | Microsoft Teams"], before: ["Chat | Microsoft Teams"]),
    ["Sync | Microsoft Teams", "Chat | Microsoft Teams"], "a window opened for the call first")

  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let situ = try! store.createProject(name: "Situ")
  let shifty = try! store.createProject(name: "Shifty")
  try! store.link(keyword: "shifty", to: .init(project: shifty))
  let p = try! store.place(dir: nil, app: nil, title: "Shifty sync | Microsoft Teams")
  expectEqual(p.via, .keyword, "a meeting named for the project")
  expectEqual(p.target, .init(project: shifty))

  let prefs = Preferences(defaults: testDefaults())
  check(prefs.meetingSwitch, "meetings offer by default")
  check(!prefs.meetingAutoLog, "and ask first")
  prefs.autoSwitch = true
  prefs.autoSwitchDelay = 30
  let tracking = TrackingModel(store: store)
  tracking.choose(project: situ, workspace: nil, now: at(9))
  tracking.reload(now: at(9, 1))
  let auto = AutoSwitchModel(tracking: tracking, preferences: prefs)
  let toShifty = ShiftStore.Target(project: shifty)
  let toSitu = ShiftStore.Target(project: situ)
  typealias Seen = AutoSwitchModel.MeetingSeen

  // A call that names no project: it offers to log it on the running
  // timer's.
  auto.observeMeeting(Seen(title: "Standup", target: nil), now: at(10))
  check(auto.meeting != nil, "a call is on")
  expectEqual(auto.offer?.kind, .meeting)
  expectEqual(auto.offer?.target, toSitu, "on the running timer's project")
  check(auto.offer?.logsHere == true, "where it's running")
  expectEqual(auto.offer?.meeting, "Standup")
  check(auto.offer?.deadline == nil, "it waits")
  auto.keep(now: at(10, 1))
  check(auto.offer == nil, "not now")
  auto.observeMeeting(Seen(title: "Standup", target: nil), now: at(10, 2))
  check(auto.offer == nil, "once a call")
  auto.observeMeeting(nil, now: at(10, 15))
  check(auto.meeting == nil, "it ended")
  expectEqual(tracking.runningTarget, toSitu, "nothing changed")
  check(tracking.running?.isMeeting == false, "still work")

  // Logged on the same project: the work stops when the call began, and
  // the meeting ends with the call, back to work.
  auto.observeMeeting(Seen(title: "Standup", target: nil), now: at(10, 30))
  auto.switchNow(now: at(10, 31))
  tracking.reload(now: at(10, 31))
  check(tracking.running?.isMeeting == true, "a meeting")
  expectEqual(tracking.runningTarget, toSitu)
  expectEqual(tracking.running?.note, "Standup", "titled for the call")
  expectEqual(tracking.running?.start, at(10, 30), "from when the call began")
  expectEqual(auto.switched?.meeting, "Standup", "it says so")
  auto.dismissSwitched()
  auto.observeMeeting(nil, now: at(10, 45))
  tracking.reload(now: at(10, 46))
  check(tracking.running?.isMeeting == false, "back to work")
  expectEqual(tracking.runningTarget, toSitu)
  expectEqual(tracking.running?.start, at(10, 45), "from when it ended")
  check(auto.switched?.ended == true, "says it ended")
  let logged = try! store.timesheet(DateInterval(start: at(0), end: at(23))).entries
    .filter(\.isMeeting)
  expectEqual(logged.count, 1, "one meeting")
  expectEqual(logged.first?.end, at(10, 45))
  // Undo keeps the meeting going; picking its project goes back to work.
  auto.undoSwitch()
  tracking.reload(now: at(10, 47))
  check(tracking.running?.isMeeting == true, "undo picks the meeting up again")
  tracking.choose(project: situ, workspace: nil, now: at(10, 50))
  tracking.reload(now: at(10, 51))
  check(tracking.running?.isMeeting == false, "work again")
  expectEqual(tracking.running?.start, at(10, 50))

  // A call for Shifty while Situ runs: it offers to log it there, and
  // waits for you.
  auto.observeMeeting(Seen(title: "Shifty sync", target: toShifty), now: at(11))
  expectEqual(auto.offer?.kind, .meeting)
  expectEqual(auto.offer?.name, "Shifty")
  expectEqual(auto.offer?.from, "Situ")
  expectEqual(auto.offer?.place, "Shifty sync")
  expectEqual(auto.offer?.arrived, at(11), "from when the call began")
  check(auto.offer?.deadline == nil, "no countdown")
  auto.tick(now: at(11, 30))
  expectEqual(tracking.runningTarget, toSitu, "it doesn't log by itself")
  // Where you work changes nothing while the call's on.
  auto.observe(toSitu, place: "situ", now: at(11, 31))
  auto.observe(toSitu, place: "situ", now: at(11, 40))
  expectEqual(auto.offer?.kind, .meeting, "still offered")
  auto.switchNow(now: at(11, 41))
  expectEqual(tracking.runningTarget, toShifty, "on Shifty")
  check(tracking.running?.isMeeting == true, "as a meeting")
  expectEqual(tracking.running?.start, at(11), "from when the call began")
  auto.observeMeeting(Seen(title: "Shifty sync", target: toShifty), now: at(11, 42))
  check(auto.offer == nil, "nothing more to offer")
  auto.dismissSwitched()

  // It ends: back to Situ, by itself.
  auto.observeMeeting(nil, now: at(12))
  expectEqual(tracking.runningTarget, toSitu, "back")
  check(tracking.running?.isMeeting == false, "as work")
  expectEqual(tracking.running?.start, at(12), "from when it ended")
  expectEqual(auto.switched?.name, "Situ")
  check(auto.switched?.ended == true, "says the meeting ended")
  auto.dismissSwitched()

  // Logged without asking, before Teams names it: named once it does,
  // and moved, whole, to the project a keyword names.
  prefs.meetingAutoLog = true
  auto.observeMeeting(Seen(title: nil, target: nil), now: at(12, 30))
  tracking.reload(now: at(12, 30))
  check(tracking.running?.isMeeting == true, "logged without asking")
  expectEqual(tracking.running?.note, AutoSwitchModel.untitled)
  expectEqual(tracking.runningTarget, toSitu)
  auto.observeMeeting(Seen(title: "Shifty sync", target: toShifty), now: at(12, 32))
  tracking.reload(now: at(12, 32))
  expectEqual(tracking.running?.note, "Shifty sync", "named")
  expectEqual(tracking.runningTarget, toShifty, "moved to the project it names")
  expectEqual(tracking.running?.start, at(12, 30), "whole")
  auto.observeMeeting(nil, now: at(12, 50))
  tracking.reload(now: at(12, 50))
  expectEqual(tracking.runningTarget, toSitu, "back to what ran before the call")
  check(tracking.running?.isMeeting == false, "as work")
  prefs.meetingAutoLog = false
  auto.dismissSwitched()

  // Keep: not offered again that call, and the place's offers aren't held
  // off.
  auto.observeMeeting(Seen(title: "Shifty sync", target: toShifty), now: at(13))
  expectEqual(auto.offer?.kind, .meeting)
  auto.keep(now: at(13, 1))
  check(auto.offer == nil, "kept")
  auto.observeMeeting(Seen(title: "Shifty sync", target: toShifty), now: at(13, 2))
  check(auto.offer == nil, "once a call")
  auto.observeMeeting(nil, now: at(13, 30))
  check(auto.offer == nil && auto.switched == nil, "nothing logged, nothing to end")
  auto.observe(toShifty, place: "shifty", now: at(13, 31))
  auto.observe(toShifty, place: "shifty", now: at(13, 32))
  expectEqual(auto.offer?.kind, .place, "a place still offers")
  auto.keep(now: at(13, 32))

  // A call ends a place's countdown.
  auto.observe(toShifty, place: "shifty", now: at(14, 10))
  auto.observe(toShifty, place: "shifty", now: at(14, 11))
  check(auto.offer?.kind == .place, "counting down")
  auto.observeMeeting(Seen(title: "Standup", target: nil), now: at(14, 11) + 2)
  expectEqual(auto.offer?.kind, .meeting, "the call takes over")
  auto.observeMeeting(nil, now: at(14, 30))

  // Off: nothing.
  prefs.meetingSwitch = false
  auto.observeMeeting(Seen(title: "Shifty sync", target: toShifty), now: at(15))
  check(auto.meeting == nil && auto.offer == nil, "off")
}

// MARK: Meetings on the timesheet

do {
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let web = try! store.createProject(name: "Web")
  let work = try! store.addEntry(project: web, workspace: nil, start: at(9), end: at(10))
  let call = try! store.addMeeting(
    project: web, workspace: nil, start: at(10), end: at(10, 30), title: "Stand up")
  let sheet = TimesheetModel(store: store, calendar: cal, now: at(12))
  sheet.reload()
  expectEqual(sheet.meetingCount(), 1)
  expectEqual(sheet.meetings(on: at(0)).map(\.id), [call])
  expectEqual(sheet.meetings(on: at(0)).first?.note, "Stand up", "titled")
  expectEqual(sheet.meetingDays, [cal.startOfDay(for: at(0))])
  expectEqual(sheet.meetingTime(now: at(12)), 30 * 60)
  expectEqual(sheet.total(now: at(12)), 90 * 60, "a meeting is time worked")
  sheet.setMeeting(sheet.sheet.entries.first(where: { $0.id == work })!, true)
  expectEqual(sheet.meetingCount(), 2, "marked as a meeting")
  sheet.setMeeting(sheet.sheet.entries.first(where: { $0.id == work })!, false)
  expectEqual(sheet.meetingCount(), 1, "and back")
  let added = sheet.addMeeting(on: at(0), now: at(12))
  let entry = sheet.sheet.entries.first { $0.id == added }
  check(entry?.isMeeting == true, "added as a meeting")
  expectEqual(entry?.projectId, web, "on the last meeting's project")
}

for name in ["shifty-tests", "shifty-tests-none"] {
  UserDefaults.standard.removePersistentDomain(forName: name)
}

// MARK: Break icons and the lunch clock link

do {
  // Lunch saved before icons reads as the fork and knife, clocked out for.
  let old = Preferences.lunch(
    from: #"{"enabled":true,"earliest_mins":180,"latest_mins":300,"minimum_mins":30}"#)!
  check(old.icon == nil, "no icon saved")
  expectEqual(old.symbol, BreakIcon.lunch)
  check(old.clockLink, "lunch is clocked out for by default")

  var rule = old
  rule.icon = "takeoutbag.and.cup.and.straw"
  rule.clockLink = false
  let back = Preferences.lunch(from: Preferences.format(rule)!)!
  expectEqual(back, rule, "icon and clock link round-trip")
  expectEqual(back.symbol, "takeoutbag.and.cup.and.straw")

  expectEqual(BreakIcon.symbol(nil, or: "cup.and.saucer"), "cup.and.saucer")
  expectEqual(BreakIcon.symbol("", or: "cup.and.saucer"), "cup.and.saucer", "empty is the default")
  expectEqual(BreakIcon.choices(including: "fork.knife").count, BreakIcon.choices.count)
  expectEqual(
    BreakIcon.choices(including: "airplane").last?.symbol, "airplane",
    "an icon picked elsewhere still shows")
  check(BreakIcon.choices.contains { $0.symbol == BreakIcon.lunch }, "lunch's default is offered")
  check(BreakIcon.choices.contains { $0.symbol == BreakIcon.rest }, "the cup is offered")
}

do {
  // A scheduled break on the clock: Wednesday Oct 28, class 11 to 2.
  var cls = ScheduledBreak(name: "Class", weekdays: [3], start: 11 * 3600, end: 14 * 3600)
  check(cls.matches(start: at(11), end: at(14), calendar: cal), "same times, its day")
  check(cls.matches(start: at(11, 30), end: at(14), calendar: cal), "cut by a later clock in")
  check(!cls.matches(start: at(11), end: at(13), calendar: cal), "moved for the day")
  check(!cls.matches(start: at(11, day: 1), end: at(14, day: 1), calendar: cal), "not its day")
  check(!cls.matches(start: at(11), end: nil, calendar: cal), "one running isn't scheduled")
  expectEqual(cls.symbol(rest: "mug"), "mug", "no icon of its own: the break icon")
  cls.icon = "graduationcap"
  expectEqual(cls.symbol(rest: "mug"), "graduationcap")
  cls.isEnabled = false
  check(!cls.matches(start: at(11), end: at(14), calendar: cal), "off")
}

do {
  // Icons and the lunch clock link live in the store, for every frontend.
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let defaults = testDefaults()
  let prefs = Preferences(defaults: defaults, store: store)
  check(prefs.lunch.clockLink, "a new store's lunch is clocked out for")
  check(prefs.breakIcon == nil, "no break icon by default")
  expectEqual(prefs.breakSymbol, BreakIcon.rest)

  prefs.lunch.isEnabled = true
  prefs.lunch.icon = "carrot"
  prefs.breakIcon = "mug"
  var cls = ScheduledBreak(name: "Class", weekdays: [3], start: 11 * 3600, end: 14 * 3600)
  cls.icon = "graduationcap"
  prefs.scheduledBreaks.append(cls)

  let presets = try! store.breakPresets()
  expectEqual(presets.map(\.icon), ["carrot", "graduationcap"], "icons stored with the presets")
  expectEqual(presets.map(\.clockLink), [true, false], "lunch offers the links, class doesn't")
  expectEqual(try! store.setting(Preferences.breakIconSetting), "mug")

  let again = Preferences(defaults: defaults, store: store)
  expectEqual(again.lunch.symbol, "carrot", "read back")
  expectEqual(again.breakSymbol, "mug")
  expectEqual(again.scheduledBreaks.first?.icon, "graduationcap")
  expectEqual(
    again.scheduledBreak(start: at(11), end: at(14), calendar: cal)?.name, "Class",
    "a break on the clock finds its scheduled break")

  // Changed from the TUI or CLI.
  try! ShiftStore(path: path).setSetting(Preferences.breakIconSetting, nil)
  again.pull()
  check(again.breakIcon == nil, "break icon cleared elsewhere")

  // Back to the default stores none.
  prefs.lunch.icon = nil
  check(try! store.breakPresets().first?.icon == nil, "default lunch icon stored as none")

  // The lunch clock link follows the clock link mode, and only with lunch
  // on and clocked out for.
  prefs.clockOutLink = URL(string: "https://example.com/clock")
  prefs.clockLinkMode = .always
  let url = URL(string: "https://example.com/clock")!
  expectEqual(prefs.clockLinkAction(for: .lunchStarts), .open(url), "lunch opens the link")
  expectEqual(prefs.clockLinkAction(for: .lunchEnds), .open(url), "and again after")
  prefs.clockLinkMode = .ask
  expectEqual(prefs.clockLinkAction(for: .lunchStarts), .ask(url), "asks when set to ask")
  prefs.lunch.clockLink = false
  expectEqual(prefs.clockLinkAction(for: .lunchStarts), .none, "lunch not clocked out for")
  expectEqual(prefs.clockLinkAction(for: .clockOut), .ask(url), "clocking out still does")
  prefs.lunch.clockLink = true
  prefs.lunch.isEnabled = false
  expectEqual(prefs.clockLinkAction(for: .lunchEnds), .none, "no lunch window, no lunch")
  check(!Preferences(defaults: defaults, store: store).lunch.isEnabled, "saved off")
  check(Preferences(defaults: defaults, store: store).lunch.clockLink, "clock link kept")

  check(ClockEvent.lunchEnds.clockingIn && ClockEvent.clockIn.clockingIn, "back in")
  check(!ClockEvent.lunchStarts.clockingIn && !ClockEvent.clockOut.clockingIn, "out")
}

do {
  // Which break is lunch, as Start and End Break see it: 9 AM, 8h.
  var rule = LunchRule()
  rule.isEnabled = true
  let m = ShiftModel()
  m.clockInTime = at(9)
  m.shiftLength = 8
  check(!m.isOnLunch(rule, now: at(10)), "not on a break")

  // A 10-minute rest before lunch isn't it, but it was while it ran.
  m.startBreak(now: at(10))
  check(m.isOnLunch(rule, now: at(10)), "the first break might be lunch")
  m.endBreak(now: at(10, 10))
  m.startBreak(now: at(12, 30))
  check(m.isOnLunch(rule, now: at(12, 30)), "the next one is lunch")
  m.endBreak(now: at(13))
  m.startBreak(now: at(15))
  check(!m.isOnLunch(rule, now: at(15)), "after lunch, a break is a break")
  check(!m.isOnLunch(nil, now: at(15)), "no rule, no lunch")
  m.endBreak(now: at(15, 10))

  // A shift too short to need lunch never has one.
  let short = ShiftModel()
  short.clockInTime = at(9)
  short.shiftLength = 4
  short.startBreak(now: at(11))
  check(!short.isOnLunch(rule, now: at(11)), "short shift")
}

do {
  // Clock out counts lunch before you take it: 9 AM, 8h, lunch at least
  // 30 min.
  var rule = LunchRule()
  rule.isEnabled = true
  let m = ShiftModel()
  m.clockInTime = at(9)
  m.shiftLength = 8
  expectEqual(m.clockOut(now: at(10)), at(17), "no lunch window, no lunch counted")
  m.lunchRule = rule
  expectEqual(m.clockOut(now: at(10)), at(17, 30), "lunch's minimum counted ahead")
  rule.minimum = 45 * 60
  m.lunchRule = rule
  expectEqual(m.clockOut(now: at(10)), at(17, 45), "as long as lunch has to be")
  rule.minimum = 30 * 60
  m.lunchRule = rule

  // A rest too short to be lunch adds to it.
  m.startBreak(now: at(10))
  m.endBreak(now: at(10, 10))
  expectEqual(m.clockOut(now: at(11)), at(17, 40), "rest, then lunch to come")

  // On lunch, clock out holds until the minimum, then moves with the clock.
  m.startBreak(now: at(12))
  expectEqual(m.clockOut(now: at(12, 15)), at(17, 40), "early in lunch")
  expectEqual(m.clockOut(now: at(12, 45)), at(17, 55), "a long lunch")
  m.endBreak(now: at(13))
  expectEqual(m.clockOut(now: at(14)), at(18, 10), "the lunch you took")
  expectEqual(m.lunchAhead(now: at(14)), 0, "none left")

  // Off, or on a shift too short to need lunch, nothing is counted.
  let short = ShiftModel()
  short.clockInTime = at(9)
  short.shiftLength = 4
  short.lunchRule = rule
  expectEqual(short.clockOut(now: at(10)), at(13), "short shift")
  rule.isEnabled = false
  m.lunchRule = rule
  m.breaks = []
  expectEqual(m.clockOut(now: at(10)), at(17), "lunch window off")
}

// MARK: Rex

do {
  expectEqual(RexFollow.hosts(" devbox, build  devbox,,"), ["devbox", "build"])
  expectEqual(RexFollow.servers(hosts: ["devbox"]), [nil, "devbox"], "this Mac's, then each host")
  expectEqual(
    RexFollow.arguments(script: "/s.lua", server: nil, cli: "/bin/shifty"),
    ["--autostart=false", "do", "/s.lua", "--all", "shifty=/bin/shifty"])
  expectEqual(
    RexFollow.arguments(script: "/s.lua", server: "devbox", cli: "/bin/shifty"),
    [
      "--autostart=false", "-S", "devbox", "do", "/s.lua", "--all", "shifty=/bin/shifty",
      "server=devbox",
    ])
  check(RexFollow.isRex("com.superlogical.rex.server"), "Rex Server is Rex")
  check(!RexFollow.isRex("com.superlogical.rexx"), "another app isn't")
  check(!RexFollow.isRex(nil), "nothing in front")
  check(ShiftStore.rexScript(cli: "/bin/shifty").contains("'/bin/shifty'"), "the script calls the CLI")

  let defaults = testDefaults()
  let prefs = Preferences(defaults: defaults)
  check(!prefs.followRex, "off until you turn it on")
  prefs.followRex = true
  prefs.rexHosts = "devbox"
  let again = Preferences(defaults: defaults)
  check(again.followRex, "kept")
  expectEqual(again.rexHosts, "devbox")
}

// MARK: Breaks by day

do {
  // Off the clock, a new day starts without yesterday's breaks, once its
  // shift is over; before, the draft only rolled over 12 hours after.
  let m = ShiftModel()
  m.clockInTime = at(9, day: -1)
  m.breaks = [brk(at(12, day: -1), at(13, day: -1))]
  m.rollOverIfStale(now: at(0, 30), calendar: cal)
  expectEqual(m.clockInTime, at(9), "rolled to today just after midnight")
  check(m.breaks.isEmpty, "a new day starts without yesterday's lunch")

  let night = ShiftModel()
  night.clockInTime = at(22, day: -1)
  night.breaks = [brk(at(1), at(1, 30))]
  night.rollOverIfStale(now: at(5), calendar: cal)
  expectEqual(night.clockInTime, at(22, day: -1), "a night shift's draft waits for its clock out")
  night.rollOverIfStale(now: at(6, 30), calendar: cal)
  expectEqual(night.clockInTime, at(22), "then rolls to tonight")
  check(night.breaks.isEmpty, "with tonight's breaks")
}

do {
  // Clocking in the next morning with yesterday's lunch still in the draft
  // leaves the lunch on yesterday's shift.
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let m = ShiftModel()
  m.store = store
  m.clockInTime = at(9)
  m.breaks = [brk(at(12), at(12, 30))]
  m.clockInNow(now: at(9), calendar: cal)
  let monday = try! store.currentShift()!
  m.clockOutNow(now: at(17))
  check(!m.breaks.isEmpty, "the draft still has Monday's lunch")

  m.clockInNow(now: at(9, day: 1), calendar: cal)
  let tuesday = try! store.currentShift()!
  check(tuesday.id != monday.id, "a new shift")
  expectEqual(try! store.breaks(of: monday.id).map(\.start), [at(12)], "Monday keeps its lunch")
  check(try! store.breaks(of: tuesday.id).isEmpty, "Tuesday starts without it")
  check(m.breaks.isEmpty, "and so does the menu bar")

  // The store won't move a break to another shift under its id.
  let lunch = try! store.breaks(of: monday.id)[0]
  do {
    try store.putBreak(lunch, shift: tuesday.id, now: at(10, day: 1))
    check(false, "moving a break is refused")
  } catch let error as ShiftStore.Error {
    expectEqual(error.result, SHIFTY_CONFLICT, "moving a break is refused")
  } catch {
    check(false, "unexpected \(error)")
  }
  expectEqual(try! store.breaks(of: monday.id).count, 1, "still on Monday")
}

do {
  // One-off breaks: saved, listed, put on that day's shift, removed.
  let path = tempStorePath()
  defer { try? FileManager.default.removeItem(atPath: path) }
  let store = try! ShiftStore(path: path)
  let oneOffs = OneOffBreaksModel(store: store, calendar: cal)
  var changed = 0
  oneOffs.didChange = { changed += 1 }

  let dentist = OneOffBreaksModel.Draft(
    name: " Dentist ", icon: "cross.case", start: at(14, day: 1), end: at(15, day: 1))
  check(oneOffs.save(dentist, now: at(9)), "saved")
  expectEqual(oneOffs.breaks.map(\.name), ["Dentist"], "name trimmed")
  expectEqual(oneOffs.breaks.first?.icon, "cross.case")
  expectEqual(oneOffs.breaks.first?.start, at(14, day: 1))
  expectEqual(oneOffs.breaks.first?.end, at(15, day: 1))
  expectEqual(oneOffs.breaks(on: at(0, day: 1)).count, 1, "on its day")
  check(oneOffs.breaks(on: at(0)).isEmpty, "not today")
  expectEqual(changed, 1, "the shift hears about it")

  check(!oneOffs.save(.init(start: at(15), end: at(14)), now: at(9)), "ends first")
  expectEqual(oneOffs.error, "Ends before it starts")
  check(!oneOffs.save(.init(start: at(7), end: at(8)), now: at(9)), "already over")
  check(!oneOffs.save(.init(start: at(10), end: at(23)), now: at(9)), "over 12 hours")
  expectEqual(oneOffs.breaks.count, 1, "none of those saved")
  oneOffs.clearError()

  // Unnamed is "Break"; a new one starts at the next hour.
  let new = OneOffBreaksModel.Draft.new(on: at(0), now: at(9, 20), calendar: cal)
  expectEqual(new.start, at(10))
  expectEqual(new.end, at(11))
  check(oneOffs.save(new, now: at(9, 20)), "saved")
  expectEqual(oneOffs.breaks.map(\.name), ["Break", "Dentist"], "earliest first")
  oneOffs.delete(new.id, now: at(9, 30))
  expectEqual(oneOffs.breaks.map(\.name), ["Dentist"], "deleted")

  // Clocking in that day brings it along.
  let m = ShiftModel()
  m.store = store
  m.clockInTime = at(9, day: 1)
  m.clockInNow(now: at(9, day: 1), calendar: cal)
  let shift = try! store.currentShift()!
  expectEqual(
    try! store.breaks(of: shift.id).map(\.start), [at(14, day: 1)], "the dentist is on the shift")
  expectEqual(m.clockOut(now: at(9, day: 1)), at(18, day: 1), "and pushes clock out")
  check(oneOffs.match(start: at(14, day: 1), end: at(15, day: 1)) != nil, "named on the Breaks page")

  // Removed before it starts, it comes off the shift.
  oneOffs.delete(dentist.id, now: at(10, day: 1))
  m.pull()
  check(try! store.breaks(of: shift.id).isEmpty, "off the shift")
  check(m.breaks.isEmpty, "and the menu bar")
}

// MARK: Organizations and personal tracking

do {
  let store = try! ShiftStore(path: tempStorePath())
  let orgs = try! store.organizations()
  expectEqual(orgs.map(\.name), ["Work", "Personal"], "Work and Personal to start")
  expectEqual(orgs.map(\.tracking), [.shift, .auto])
  let work = orgs[0].id
  let own = orgs[1].id
  let api = try! store.createProject(name: "api")
  let side = try! store.createProject(name: "side", organization: own)
  let listed = try! store.projects(now: at(12))
  expectEqual(listed.organizations.count, 2, "projects come with organizations")
  expectEqual(listed.projects.first { $0.id == api }?.organizationId, work, "new projects go to Work")
  expectEqual(listed.projects.first { $0.id == side }?.organizationId, own)

  // The Projects window: by organization, moved, added, deleted.
  let p = ProjectsModel(store: store)
  p.reload(now: at(12))
  expectEqual(p.projects(in: p.organizations[0]).map(\.name), ["api"])
  expectEqual(p.projects(in: p.organizations[1]).map(\.name), ["side"])
  let acme = p.createOrganization(named: "Acme", tracking: .shift)!
  check(p.createOrganization(named: "acme", tracking: .shift) == nil, "the name's taken")
  check(p.createOrganization(named: "  ", tracking: .auto) == nil, "a blank name")
  p.clearError()
  p.move(p.project(api)!, to: p.organization(acme)!)
  expectEqual(p.organizationOf(p.project(api)!)?.name, "Acme", "moved")
  check(p.rename(p.organization(acme)!, to: "Acme Co"), "renamed")
  expectEqual(p.successor(of: p.organization(acme)!)?.name, "Work", "the first other on the shift")
  p.delete(p.organization(acme)!)
  expectEqual(p.organizations.map(\.name), ["Work", "Personal"], "deleted")
  expectEqual(p.organizationOf(p.project(api)!)?.name, "Work", "its project went to Work")
  check(p.error == nil, "no errors: \(p.error ?? "")")
  let groups = ProjectGroup.of(p.projects, in: p.organizations)
  expectEqual(groups.map(\.title), ["Work", "Personal"], "menus by organization")
  expectEqual(groups.map { $0.projects.map(\.id) }, [[api], [side]])
  expectEqual(
    ProjectGroup.of(p.projects.filter { $0.id == api }, in: p.organizations).map(\.title), [nil],
    "one group has no title")

  // The timesheet: personal time apart, one organization at a time.
  _ = try! store.addEntry(project: api, workspace: nil, start: at(9), end: at(10))
  _ = try! store.addEntry(project: side, workspace: nil, start: at(19), end: at(20, 30))
  let t = TimesheetModel(store: store, calendar: cal, now: at(12))
  t.reload()
  expectEqual(t.total(now: at(21)), 3600, "work tracked, without personal time")
  expectEqual(t.personal(now: at(21)), 5400, "personal time apart")
  expectEqual(t.totalsByProject(now: at(21)).map(\.project), [api])
  expectEqual(t.personalByProject(now: at(21)).map(\.project), [side])
  expectEqual(t.total(on: at(0), now: at(21)), 9000, "the day shows both")
  t.organizationFilter = own
  check(t.hidesShifts, "Personal has no shift")
  expectEqual(t.total(now: at(21)), 0)
  expectEqual(t.personal(now: at(21)), 5400)
  expectEqual(t.entries(on: at(0)).count, 1, "only Personal's entry")
  t.organizationFilter = work
  check(!t.hidesShifts, "Work is on the shift")
  expectEqual(t.personal(now: at(21)), 0)
  expectEqual(t.entries(on: at(0)).count, 1, "only Work's entry")
  t.organizationFilter = nil

  // Personal tracking: off the clock, staying in a personal project.
  let prefs = Preferences(defaults: testDefaults())
  prefs.autoSwitchDelay = 30
  prefs.personalIdle = 300
  let tracking = TrackingModel(store: store)
  tracking.reload(now: at(21))
  var clockedIn = false
  let personal = PersonalTracker(tracking: tracking, preferences: prefs)
  personal.isClockedIn = { clockedIn }
  let toSide = ShiftStore.Target(project: side)
  check(tracking.isPersonal(side) && !tracking.isPersonal(api), "which projects are personal")

  personal.observe(toSide, now: at(21))
  check(tracking.running == nil, "not before the delay")
  personal.observe(toSide, now: at(21) + 31)
  expectEqual(tracking.runningTarget, toSide, "started by itself")
  expectEqual(tracking.running?.start, at(21), "from when you got there")
  check(personal.hasTimer, "personal tracking has the timer")

  let blog = try! store.createProject(name: "blog", organization: own)
  tracking.reload(now: at(21, 5))
  let toBlog = ShiftStore.Target(project: blog)
  personal.observe(toBlog, now: at(21, 10))
  personal.observe(toBlog, now: at(21, 10) + 31)
  expectEqual(tracking.runningTarget, toBlog, "another personal project moves it")
  expectEqual(tracking.running?.start, at(21, 10))

  personal.observe(nil, now: at(21, 20))
  expectEqual(tracking.runningTarget, toBlog, "somewhere unlinked keeps it running")

  personal.observe(toBlog, idle: 400, now: at(21, 30))
  check(tracking.running == nil, "going idle stops it")
  let day = DateInterval(start: at(0), end: at(23, 59))
  let idleStop = try! store.timesheet(day).entries.first { $0.projectId == blog }?.end
  expectEqual(idleStop, at(21, 30) - 400, "at the last touch")

  personal.observe(toBlog, now: at(22))
  personal.observe(toBlog, now: at(22) + 31)
  expectEqual(tracking.running?.start, at(22), "back again, from coming back")

  personal.observe(.init(project: api), now: at(22, 10))
  check(tracking.running != nil, "a work project doesn't stop it at once")
  personal.observe(.init(project: api), now: at(22, 10) + 31)
  check(tracking.running == nil, "staying in a work project stops it")

  personal.observe(toSide, now: at(22, 20))
  personal.observe(toSide, now: at(22, 20) + 31)
  check(tracking.running != nil, "running again")
  clockedIn = true
  personal.observe(toSide, now: at(22, 25))
  check(tracking.running == nil, "clocking in stops it")
  tracking.choose(project: side, workspace: nil, now: at(22, 26))
  personal.observe(nil, idle: 1000, now: at(22, 27))
  check(tracking.running != nil, "one you start on the clock is yours")
  check(!personal.hasTimer, "and auto-switch's to move")
  tracking.stop(now: at(22, 28))
  clockedIn = false

  personal.observe(toSide, now: at(23))
  personal.observe(toSide, now: at(23) + 31)
  check(tracking.running != nil, "running once more")
  personal.pause(now: at(23, 5))
  check(tracking.running == nil, "sleep or lock stops it")

  prefs.personalTracking = false
  personal.observe(toSide, now: at(23, 10))
  personal.observe(toSide, now: at(23, 10) + 31)
  check(tracking.running == nil, "off, it does nothing")
}

// MARK: Week totals by organization

do {
  let store = try! ShiftStore(path: tempStorePath())
  let orgs = try! store.organizations()
  let work = orgs[0].id
  let acme = try! store.createOrganization(name: "Acme")
  let api = try! store.createProject(name: "api")
  let site = try! store.createProject(name: "site", organization: acme)
  let side = try! store.createProject(name: "side", organization: orgs[1].id)
  _ = try! store.addEntry(project: api, workspace: nil, start: at(9), end: at(10))
  _ = try! store.addEntry(project: site, workspace: nil, start: at(10), end: at(12))
  _ = try! store.addEntry(project: nil, workspace: nil, start: at(12), end: at(12, 30))
  _ = try! store.addEntry(project: side, workspace: nil, start: at(19), end: at(20))
  let t = TimesheetModel(store: store, calendar: cal, now: at(12))
  t.reload()
  let groups = t.byOrganization(t.totalsByProject(now: at(21)))
  expectEqual(
    groups.map { $0.organization?.name }, ["Acme", "Work", nil], "most first, no project last")
  expectEqual(groups.map(\.seconds), [7200, 3600, 1800])
  expectEqual(groups.map { $0.projects.map(\.project) }, [[site], [api], [nil]])
  let personal = t.byOrganization(t.personalByProject(now: at(21)))
  expectEqual(personal.map { $0.organization?.name }, [nil], "one organization isn't grouped")
  expectEqual(personal.first?.projects.map(\.project), [side])
  t.organizationFilter = work
  let shown = t.byOrganization(t.totalsByProject(now: at(21)))
  expectEqual(shown.map { $0.organization?.name }, [nil], "one organization shown isn't grouped")
  expectEqual(shown.first?.projects.map(\.project), [api, nil])
}

print("\(count - failures)/\(count) checks passed")
exit(failures == 0 ? 0 : 1)
