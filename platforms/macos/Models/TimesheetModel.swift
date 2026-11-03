import Foundation
import Observation

/// A week of shifts and time entries from the store, for the main window's
/// timesheet: add time after the fact (a meeting, offline work), fix times,
/// reassign projects, move a clock in or out. The CLI and TUI write the same
/// rows.
@Observable final class TimesheetModel: ProjectNames {
  /// Midnight starting the week shown.
  private(set) var weekStart: Date
  private(set) var sheet = ShiftStore.Timesheet()
  /// Times being edited that don't make a valid entry yet, by entry.
  private(set) var drafts: [UUID: Draft] = [:]
  /// The last store error, shown until the next successful change.
  private(set) var error: String?

  @ObservationIgnored let store: ShiftStore
  @ObservationIgnored let calendar: Calendar
  /// Work days and lunch; without them every day shows and there's no
  /// lunch window.
  @ObservationIgnored let preferences: Preferences?
  /// Called after each write, so the popover picks up a clock in or break
  /// moved here before it saves over it.
  @ObservationIgnored var didChange: (() -> Void)?

  /// An entry's, shift's, or break's start and end as typed. Kept out of
  /// the store until the end comes after the start.
  struct Draft: Equatable {
    var start: Date
    var end: Date
  }

  /// No entry is longer than this; an end that would make one is a typo.
  static let maxEntry: TimeInterval = 16 * 60 * 60

  init(
    store: ShiftStore, preferences: Preferences? = nil, calendar: Calendar = .current,
    now: Date = Date()
  ) {
    self.store = store
    self.preferences = preferences
    self.calendar = calendar
    weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
  }

  var week: DateInterval {
    DateInterval(start: weekStart, end: calendar.date(byAdding: .day, value: 7, to: weekStart)!)
  }

  var days: [Date] {
    (0..<7).map { calendar.date(byAdding: .day, value: $0, to: weekStart)! }
  }

  /// The days shown: the ones you work, and any other with time on it.
  var visibleDays: [Date] { days.filter { isWorkDay($0) || hasTime(on: $0) } }

  /// Days folded or opened by hand, by their start. Others are open only
  /// if they're today.
  private(set) var folded: Set<Date> = []
  private(set) var opened: Set<Date> = []

  /// Whether a day is folded down to its header: every day but today, until
  /// you open it. One with nothing on it has nothing to fold.
  func isCollapsed(_ day: Date, now: Date = Date()) -> Bool {
    guard hasTime(on: day) else { return false }
    let d = calendar.startOfDay(for: day)
    if folded.contains(d) { return true }
    if opened.contains(d) { return false }
    return !calendar.isDate(d, inSameDayAs: now)
  }

  /// Folds a day, or opens it. With `all`, every day with time follows it,
  /// as Option-click does for disclosure rows.
  func toggleCollapsed(_ day: Date, all: Bool = false, now: Date = Date()) {
    let fold = !isCollapsed(day, now: now)
    let targets = all ? days.filter { hasTime(on: $0) } : [day]
    for d in targets.map(calendar.startOfDay(for:)) {
      if fold {
        folded.insert(d)
        opened.remove(d)
      } else {
        opened.insert(d)
        folded.remove(d)
      }
    }
  }

  /// Opens a day, e.g. to jump to it from the week strip.
  func expand(_ day: Date) {
    let d = calendar.startOfDay(for: day)
    opened.insert(d)
    folded.remove(d)
  }

  /// Days off with nothing on them.
  var hiddenDays: [Date] { days.filter { !isWorkDay($0) && !hasTime(on: $0) } }

  func isWorkDay(_ day: Date) -> Bool {
    preferences?.isWorkDay(day, calendar: calendar) ?? true
  }

  func hasTime(on day: Date) -> Bool { !entries(on: day).isEmpty || !shifts(on: day).isEmpty }

  func reload() {
    do {
      let fresh = try store.timesheet(week)
      if fresh != sheet { sheet = fresh }
    } catch {
      self.error = "Couldn't read the timesheet (\(error))."
    }
  }

  // MARK: Navigation

  func showWeek(containing date: Date) {
    let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? weekStart
    guard start != weekStart else { return }
    weekStart = start
    drafts = [:]
    reload()
  }

  func previousWeek() { showWeek(containing: calendar.date(byAdding: .day, value: -7, to: weekStart)!) }
  func nextWeek() { showWeek(containing: calendar.date(byAdding: .day, value: 7, to: weekStart)!) }

  // MARK: Reading

  /// The entries that start on `day`, oldest first. One that started before
  /// the week shows on its first day.
  func entries(on day: Date) -> [ShiftStore.Entry] {
    sheet.entries.filter { calendar.isDate(max($0.start, weekStart), inSameDayAs: day) }
  }

  /// An entry's start and end as shown: its draft if it's being edited. A
  /// running entry has no end.
  func times(of entry: ShiftStore.Entry) -> (start: Date, end: Date?) {
    if let d = drafts[entry.id] { return (d.start, d.end) }
    return (entry.start, entry.end)
  }

  /// The shifts clocked in on `day`. One from before the week shows on its
  /// first day.
  func shifts(on day: Date) -> [ShiftStore.SheetShift] {
    sheet.shifts.filter { calendar.isDate(max($0.start, weekStart), inSameDayAs: day) }
  }

  func times(of shift: ShiftStore.SheetShift) -> (start: Date, end: Date?) {
    if let d = drafts[shift.id] { return (d.start, d.end) }
    return (shift.start, shift.end)
  }

  func times(of brk: ShiftStore.SheetBreak) -> (start: Date, end: Date?) {
    if let d = drafts[brk.id] { return (d.start, d.end) }
    return (brk.start, brk.end)
  }

  /// A shift's work: clock in to clock out (or `now`), less its breaks.
  func work(of shift: ShiftStore.SheetShift, now: Date) -> [(Date, Date)] {
    let end = max(shift.end ?? now, shift.start)
    return Spans.subtract([(shift.start, end)], shift.breaks.map { ($0.start, $0.end ?? now) })
  }

  /// When the shift you're on is due to end: its length of work after
  /// clock in, breaks pushing it later. An ended shift's clock out.
  func expectedEnd(of shift: ShiftStore.SheetShift, now: Date) -> Date {
    if let end = shift.end { return end }
    return ShiftTimes.afterWork(
      shift.length, clockIn: shift.start,
      breaks: shift.breaks.map { ($0.start, $0.end ?? max(now, $0.start)) })
  }

  /// Time worked on a shift, its breaks not counted.
  func worked(_ shift: ShiftStore.SheetShift, now: Date) -> TimeInterval {
    Spans.total(work(of: shift, now: now))
  }

  /// Time on break during a shift.
  func onBreak(_ shift: ShiftStore.SheetShift, now: Date) -> TimeInterval {
    max(0, (shift.end ?? now).timeIntervalSince(shift.start) - worked(shift, now: now))
  }

  /// Time worked on a shift that no entry covers.
  func untracked(_ shift: ShiftStore.SheetShift, now: Date) -> TimeInterval {
    let tracked = sheet.entries.map { ($0.start, $0.end ?? now) }
    return Spans.total(Spans.subtract(work(of: shift, now: now), tracked))
  }

  func worked(on day: Date, now: Date) -> TimeInterval {
    shifts(on: day).reduce(0) { $0 + worked($1, now: now) }
  }

  /// Time worked this week, on every shift.
  func worked(now: Date) -> TimeInterval {
    sheet.shifts.reduce(0) { $0 + worked($1, now: now) }
  }

  func untracked(now: Date) -> TimeInterval {
    sheet.shifts.reduce(0) { $0 + untracked($1, now: now) }
  }

  func onBreak(now: Date) -> TimeInterval {
    sheet.shifts.reduce(0) { $0 + onBreak($1, now: now) }
  }

  /// Where lunch falls on a shift, if the lunch window is on and the shift
  /// is long enough to need one. The shift you're on counts its length; an
  /// ended one what you worked.
  func lunch(of shift: ShiftStore.SheetShift, now: Date) -> LunchPlan? {
    guard let rule = preferences?.lunch.active else { return nil }
    return rule.plan(
      clockIn: shift.start, worked: shift.end == nil ? shift.length : worked(shift, now: now),
      breaks: shift.breaks.map { .init(start: $0.start, end: $0.end) }, now: now)
  }

  /// Seconds of `entry` inside the week, a running one counted up to `now`.
  func seconds(of entry: ShiftStore.Entry, now: Date) -> TimeInterval {
    let end = min(entry.end ?? now, now, week.end)
    return max(0, end.timeIntervalSince(max(entry.start, weekStart)))
  }

  func total(on day: Date, now: Date) -> TimeInterval {
    entries(on: day).reduce(0) { $0 + seconds(of: $1, now: now) }
  }

  func total(now: Date) -> TimeInterval {
    sheet.entries.reduce(0) { $0 + seconds(of: $1, now: now) }
  }

  /// Time per project this week, most first. nil is unassigned.
  func totalsByProject(now: Date) -> [(project: UUID?, seconds: TimeInterval)] {
    var totals: [UUID?: TimeInterval] = [:]
    for e in sheet.entries { totals[e.projectId, default: 0] += seconds(of: e, now: now) }
    // Ties by id, so equal rows don't swap places between redraws.
    return totals.map { ($0.key, $0.value) }.sorted {
      $0.seconds != $1.seconds
        ? $0.seconds > $1.seconds : ($0.project?.uuidString ?? "~") < ($1.project?.uuidString ?? "~")
    }
  }

  /// Time per client this week, most first. nil is projects with no client
  /// and unassigned time.
  func totalsByClient(now: Date) -> [(client: UUID?, seconds: TimeInterval)] {
    var totals: [UUID?: TimeInterval] = [:]
    for e in sheet.entries {
      totals[e.projectId.flatMap { project($0)?.clientId }, default: 0] += seconds(of: e, now: now)
    }
    return totals.map { ($0.key, $0.value) }.sorted {
      $0.seconds != $1.seconds
        ? $0.seconds > $1.seconds : ($0.client?.uuidString ?? "~") < ($1.client?.uuidString ?? "~")
    }
  }

  /// Time per project on `day`, in the order of `totalsByProject`, so a
  /// project stacks in the same place every day.
  func totalsByProject(on day: Date, now: Date) -> [(project: UUID?, seconds: TimeInterval)] {
    var totals: [UUID?: TimeInterval] = [:]
    for e in entries(on: day) { totals[e.projectId, default: 0] += seconds(of: e, now: now) }
    return totalsByProject(now: now).compactMap { row in
      totals[row.project].map { (row.project, $0) }
    }
  }

  func rank(of project: UUID) -> Int? { sheet.projects.rank(of: project) }

  func project(_ id: UUID) -> ShiftStore.Project? { sheet.projects.first { $0.id == id } }
  func client(_ id: UUID) -> ShiftStore.Client? { sheet.clients.first { $0.id == id } }

  func workspaces(of project: UUID) -> [ShiftStore.Workspace] {
    sheet.workspaces.filter { $0.projectId == project }
  }

  /// `project / workspace`, `project`, or nil for unassigned time.
  func label(project: UUID?, workspace: UUID?) -> String? {
    guard let project else { return nil }
    let name = self.project(project)?.name ?? "Archived project"
    guard let workspace, let ws = sheet.workspaces.first(where: { $0.id == workspace }) else {
      return name
    }
    return "\(name) / \(ws.name)"
  }

  // MARK: Editing

  /// Adds an hour on `day`: after its last entry, or ending now today.
  @discardableResult
  func addEntry(on day: Date, now: Date = Date()) -> UUID? {
    let (start, end) = slot(on: day, now: now)
    return write {
      try store.addEntry(project: nil, workspace: nil, start: start, end: end)
    }
  }

  func slot(on day: Date, now: Date) -> (Date, Date) {
    if let last = entries(on: day).last {
      let start = last.end ?? now
      return (start, start.addingTimeInterval(3600))
    }
    if calendar.isDate(day, inSameDayAs: now) {
      let end = Self.roundedToQuarter(now, calendar: calendar)
      return (end.addingTimeInterval(-3600), end)
    }
    let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
    return (start, start.addingTimeInterval(3600))
  }

  /// Moves the start, keeping the day; the end follows to stay after it.
  func setStart(_ entry: ShiftStore.Entry, to time: Date) {
    let entry = latest(entry)
    let current = times(of: entry)
    let start = ShiftTimes.on(current.start, timeOf: time, calendar: calendar)
    edit(entry, start: start, end: current.end.map { endTime in
      Self.end(after: start, timeOf: endTime, calendar: calendar)
    })
  }

  /// Sets the end's time of day. An end at or before the start is the next
  /// day, like a shift past midnight.
  func setEnd(_ entry: ShiftStore.Entry, to time: Date) {
    let entry = latest(entry)
    let start = times(of: entry).start
    edit(entry, start: start, end: Self.end(after: start, timeOf: time, calendar: calendar))
  }

  func setProject(_ entry: ShiftStore.Entry, project: UUID?, workspace: UUID?) {
    let entry = latest(entry)
    write {
      try store.editEntry(
        entry.id, project: project, workspace: workspace, start: entry.start, end: entry.end,
        note: entry.note)
    }
  }

  func setNote(_ entry: ShiftStore.Entry, to note: String) {
    let entry = latest(entry)
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    let value = trimmed.isEmpty ? nil : trimmed
    guard value != entry.note else { return }
    write {
      try store.editEntry(
        entry.id, project: entry.projectId, workspace: entry.workspaceId, start: entry.start,
        end: entry.end, note: value)
    }
  }

  func stop(_ entry: ShiftStore.Entry, now: Date = Date()) {
    let entry = latest(entry)
    guard entry.end == nil else { return }
    write {
      try store.editEntry(
        entry.id, project: entry.projectId, workspace: entry.workspaceId, start: entry.start,
        end: max(now, entry.start.addingTimeInterval(1)), note: entry.note)
    }
  }

  func delete(_ entry: ShiftStore.Entry) {
    drafts[entry.id] = nil
    write { try store.deleteEntry(entry.id) }
  }

  /// Whether a draft's times can be saved.
  static func isValid(start: Date, end: Date) -> Bool {
    let length = end.timeIntervalSince(start)
    return length > 0 && length <= maxEntry
  }

  // MARK: Shifts

  /// Records a shift on `day` that you forgot to clock in for: around the
  /// day's tracked time, or 9 to 5. Never in the future.
  @discardableResult
  func addShift(on day: Date, now: Date = Date()) -> UUID? {
    guard let slot = shiftSlot(on: day, now: now) else { return nil }
    return write { try store.addShift(start: slot.0, end: slot.1) }
  }

  func shiftSlot(on day: Date, now: Date) -> (Date, Date)? {
    let entries = entries(on: day)
    var start =
      entries.first.map { Self.roundedToQuarter($0.start, calendar: calendar, up: false) }
      ?? calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
    var end =
      entries.map { $0.end ?? now }.max().map { Self.roundedToQuarter($0, calendar: calendar, up: true) }
      ?? start.addingTimeInterval(8 * 3600)
    end = min(end, now)
    if end <= start {
      guard calendar.isDate(day, inSameDayAs: now) else { return nil }
      start = now.addingTimeInterval(-3600)
      end = now
    }
    return (start, end)
  }

  /// Moves clock in, keeping the day. An ended shift's clock out follows to
  /// stay after it.
  func setStart(_ shift: ShiftStore.SheetShift, to time: Date) {
    let shift = latest(shift)
    let current = times(of: shift)
    let start = ShiftTimes.on(current.start, timeOf: time, calendar: calendar)
    guard let end = current.end else {
      write { try store.editShift(shift.id, clockIn: start, lengthSeconds: shift.targetSecs) }
      return
    }
    saveShift(shift, start: start, end: Self.end(after: start, timeOf: end, calendar: calendar))
  }

  /// Moves an ended shift's clock out. One at or before clock in is the
  /// next day, like a night shift.
  func setEnd(_ shift: ShiftStore.SheetShift, to time: Date) {
    let shift = latest(shift)
    let start = times(of: shift).start
    guard shift.end != nil else { return }
    saveShift(shift, start: start, end: Self.end(after: start, timeOf: time, calendar: calendar))
  }

  /// Clocks out of the shift you're on.
  func clockOut(now: Date = Date()) {
    write { try store.endShift(now: now) }
  }

  func delete(_ shift: ShiftStore.SheetShift) {
    drafts[shift.id] = nil
    write { try store.deleteShift(shift.id) }
  }

  private func saveShift(_ shift: ShiftStore.SheetShift, start: Date, end: Date) {
    guard Self.isValid(start: start, end: end) else {
      drafts[shift.id] = Draft(start: start, end: end)
      return
    }
    drafts[shift.id] = nil
    write { try store.setShiftTimes(shift.id, start: start, end: end) }
  }

  // MARK: Breaks

  /// Adds a half-hour break: at the lunch window if lunch is still to come,
  /// else halfway through the shift.
  @discardableResult
  func addBreak(to shift: ShiftStore.SheetShift, now: Date = Date()) -> UUID? {
    let shift = latest(shift)
    let start: Date
    if let lunch = lunch(of: shift, now: now), lunch.lunch == nil {
      start = Self.roundedToQuarter(lunch.opens, calendar: calendar, up: true)
    } else {
      let end = shift.end ?? max(now, shift.start)
      start = Self.roundedToQuarter(
        shift.start.addingTimeInterval(end.timeIntervalSince(shift.start) / 2), calendar: calendar)
    }
    let brk = ShiftStore.Break(id: UUID(), start: start, end: start.addingTimeInterval(30 * 60))
    return write {
      try store.putBreak(brk, shift: shift.id)
      return brk.id
    }
  }

  /// Moves a break's start to its first time after clock in; the end
  /// follows to stay after it.
  func setStart(_ brk: ShiftStore.SheetBreak, of shift: ShiftStore.SheetShift, to time: Date) {
    let current = times(of: brk)
    let start = ShiftTimes.anchor(time: time, clockIn: latest(shift).start, calendar: calendar)
    saveBreak(
      brk, of: shift, start: start,
      end: current.end.map { Self.end(after: start, timeOf: $0, calendar: calendar) })
  }

  func setEnd(_ brk: ShiftStore.SheetBreak, of shift: ShiftStore.SheetShift, to time: Date) {
    let start = times(of: brk).start
    saveBreak(brk, of: shift, start: start, end: Self.end(after: start, timeOf: time, calendar: calendar))
  }

  /// Ends the break you're on.
  func endBreak(_ brk: ShiftStore.SheetBreak, of shift: ShiftStore.SheetShift, now: Date = Date()) {
    saveBreak(brk, of: shift, start: brk.start, end: max(now, brk.start.addingTimeInterval(60)))
  }

  func delete(_ brk: ShiftStore.SheetBreak) {
    drafts[brk.id] = nil
    write { try store.deleteBreak(brk.id) }
  }

  /// Whether a break's times can be saved.
  static func isValidBreak(start: Date, end: Date) -> Bool {
    let length = end.timeIntervalSince(start)
    return length > 0 && length <= ShiftTimes.maxBreak
  }

  private func saveBreak(
    _ brk: ShiftStore.SheetBreak, of shift: ShiftStore.SheetShift, start: Date, end: Date?
  ) {
    if let end, !Self.isValidBreak(start: start, end: end) {
      drafts[brk.id] = Draft(start: start, end: end)
      return
    }
    drafts[brk.id] = nil
    write { try store.putBreak(.init(id: brk.id, start: start, end: end), shift: shift.id) }
  }

  func createProject(named name: String) -> UUID? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    if let existing = sheet.projects.first(where: {
      $0.name.caseInsensitiveCompare(name) == .orderedSame
    }) {
      return existing.id
    }
    return write { try store.createProject(name: name) }
  }

  private func edit(_ entry: ShiftStore.Entry, start: Date, end: Date?) {
    let entry = latest(entry)
    // A running entry only has a start.
    guard let end else {
      drafts[entry.id] = nil
      write {
        try store.editEntry(
          entry.id, project: entry.projectId, workspace: entry.workspaceId, start: start,
          end: nil, note: entry.note)
      }
      return
    }
    guard Self.isValid(start: start, end: end) else {
      drafts[entry.id] = Draft(start: start, end: end)
      return
    }
    drafts[entry.id] = nil
    write {
      try store.editEntry(
        entry.id, project: entry.projectId, workspace: entry.workspaceId, start: start,
        end: end, note: entry.note)
    }
  }

  /// The entry as last read: a view may hold an older copy, and writing
  /// that back would undo a change made since.
  private func latest(_ entry: ShiftStore.Entry) -> ShiftStore.Entry {
    sheet.entries.first { $0.id == entry.id } ?? entry
  }

  private func latest(_ shift: ShiftStore.SheetShift) -> ShiftStore.SheetShift {
    sheet.shifts.first { $0.id == shift.id } ?? shift
  }

  /// Runs a store write, then reloads; a failure is shown, not thrown.
  @discardableResult
  private func write<T>(_ body: () throws -> T) -> T? {
    do {
      let value = try body()
      error = nil
      reload()
      didChange?()
      return value
    } catch {
      self.error = "Couldn't save that change (\(error))."
      reload()
      return nil
    }
  }

  static func end(after start: Date, timeOf time: Date, calendar: Calendar) -> Date {
    let end = ShiftTimes.on(start, timeOf: time, calendar: calendar)
    return end > start ? end : ShiftTimes.nextDay(end, calendar: calendar)
  }

  /// To the nearest quarter hour, or the one before or after.
  static func roundedToQuarter(_ date: Date, calendar: Calendar, up: Bool? = nil) -> Date {
    let c = calendar.dateComponents([.hour, .minute, .second], from: date)
    let exact = (c.hour ?? 0) * 60 + (c.minute ?? 0)
    let bump =
      switch up {
      case nil: 7
      case false?: 0
      case true?: (c.second ?? 0) > 0 ? 15 : 14
      }
    let minutes = (exact + bump) / 15 * 15
    return calendar.startOfDay(for: date).addingTimeInterval(TimeInterval(minutes * 60))
  }
}

/// Time spans as (start, end) pairs, for what's left of a shift once its
/// breaks, or its tracked time, are taken out.
enum Spans {
  /// `spans` with every part of `cuts` removed.
  static func subtract(_ spans: [(Date, Date)], _ cuts: [(Date, Date)]) -> [(Date, Date)] {
    var out = spans.filter { $0.0 < $0.1 }
    for (cutStart, cutEnd) in cuts where cutStart < cutEnd {
      out = out.flatMap { (start, end) -> [(Date, Date)] in
        guard cutStart < end, cutEnd > start else { return [(start, end)] }
        var left: [(Date, Date)] = []
        if start < cutStart { left.append((start, cutStart)) }
        if cutEnd < end { left.append((cutEnd, end)) }
        return left
      }
    }
    return out
  }

  /// Seconds covered; `spans` shouldn't overlap.
  static func total(_ spans: [(Date, Date)]) -> TimeInterval {
    spans.reduce(0) { $0 + max(0, $1.1.timeIntervalSince($1.0)) }
  }
}
