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

print("\(count - failures)/\(count) checks passed")
exit(failures == 0 ? 0 : 1)
