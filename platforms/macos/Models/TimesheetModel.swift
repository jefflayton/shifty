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
  /// The window's, so Edit > Undo takes back changes made here.
  @ObservationIgnored var undoManager: UndoManager?
  /// The last change registered with the undo manager, so a time typed a
  /// digit at a time undoes in one step.
  @ObservationIgnored private var lastUndo: (key: String, at: Date)?

  /// The selected shift, entry, or break.
  var selection: Item?
  /// The row whose start time should take the keyboard, as Return asks.
  var editRequest: Item?
  /// The organization whose time the timesheet shows; nil for all.
  var organizationFilter: UUID?

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

  /// Hours to work each week, if there's a goal.
  var weeklyGoal: TimeInterval? { preferences?.weeklyGoal }

  func isWorkDay(_ day: Date) -> Bool {
    preferences?.isWorkDay(day, calendar: calendar) ?? true
  }

  func hasTime(on day: Date) -> Bool { !entries(on: day).isEmpty || !shownShifts(on: day).isEmpty }

  func reload() {
    do {
      let fresh = try store.timesheet(week)
      if fresh != sheet { sheet = fresh }
    } catch {
      self.error = "Couldn't read the timesheet (\(error))."
    }
  }

  // MARK: Rows and selection

  /// Something on the timesheet you can select.
  enum Item: Hashable {
    case shift(UUID)
    case entry(UUID)
    case brk(UUID)
  }

  /// A line under a day's shift: time tracked to a project, or a break.
  enum Row: Identifiable {
    case entry(ShiftStore.Entry)
    case brk(ShiftStore.SheetBreak, shift: ShiftStore.SheetShift)

    var id: Item {
      switch self {
      case .entry(let e): .entry(e.id)
      case .brk(let b, _): .brk(b.id)
      }
    }

    var start: Date {
      switch self {
      case .entry(let e): e.start
      case .brk(let b, _): b.start
      }
    }
  }

  /// A day's entries and its shifts' breaks, in the order they started.
  func rows(on day: Date) -> [Row] {
    let breaks = shownShifts(on: day).flatMap { shift in shift.breaks.map { Row.brk($0, shift: shift) } }
    return (entries(on: day).map(Row.entry) + breaks).sorted { $0.start < $1.start }
  }

  /// Everything selectable, top to bottom, on the days that are open.
  func items(now: Date = Date()) -> [Item] {
    visibleDays.filter { !isCollapsed($0, now: now) }.flatMap { day in
      shifts(on: day).map { Item.shift($0.id) } + rows(on: day).map(\.id)
    }
  }

  /// Selects the item `offset` rows from the selection, or the first (or
  /// last) with nothing selected.
  func moveSelection(by offset: Int, now: Date = Date()) {
    let all = items(now: now)
    guard !all.isEmpty else { return }
    if let selection, let i = all.firstIndex(of: selection) {
      self.selection = all[min(max(i + offset, 0), all.count - 1)]
    } else {
      selection = offset < 0 ? all.last : all.first
    }
  }

  /// Deletes what's selected and selects what's now in its place.
  func deleteSelection(now: Date = Date()) {
    guard let selection else { return }
    let before = items(now: now)
    switch selection {
    case .shift(let id): if let shift = sheet.shifts.first(where: { $0.id == id }) { delete(shift) }
    case .entry(let id): if let entry = sheet.entries.first(where: { $0.id == id }) { delete(entry) }
    case .brk(let id): if let brk = breakAndShift(id)?.brk { delete(brk) }
    }
    let after = items(now: now)
    guard let i = before.firstIndex(of: selection), !after.isEmpty else {
      self.selection = nil
      return
    }
    self.selection = after[min(i, after.count - 1)]
  }

  /// The day an item shows on.
  func day(of item: Item) -> Date? {
    days.first { day in
      shifts(on: day).contains { .shift($0.id) == item } || rows(on: day).contains { $0.id == item }
    }
  }

  /// A break and the shift it's on.
  func breakAndShift(_ id: UUID) -> (brk: ShiftStore.SheetBreak, shift: ShiftStore.SheetShift)? {
    for shift in sheet.shifts {
      if let brk = shift.breaks.first(where: { $0.id == id }) { return (brk, shift) }
    }
    return nil
  }

  /// The selection as a line of text, for the clipboard.
  func text(of item: Item, now: Date = Date()) -> String? {
    func span(_ start: Date, _ end: Date?) -> String {
      let s = start.formatted(date: .omitted, time: .shortened)
      let e = end?.formatted(date: .omitted, time: .shortened) ?? "now"
      return "\(s) – \(e)\t\(TimesheetFormat.duration((end ?? now).timeIntervalSince(start)))"
    }
    switch item {
    case .shift(let id):
      guard let shift = sheet.shifts.first(where: { $0.id == id }) else { return nil }
      let t = times(of: shift)
      return "Shift\t\(span(t.start, t.end))"
    case .entry(let id):
      guard let entry = sheet.entries.first(where: { $0.id == id }) else { return nil }
      let t = times(of: entry)
      let project = label(project: entry.projectId, workspace: entry.workspaceId) ?? "No project"
      return ([project, span(t.start, t.end)] + (entry.note.map { [$0] } ?? []))
        .joined(separator: "\t")
    case .brk(let id):
      guard let brk = breakAndShift(id)?.brk else { return nil }
      let t = times(of: brk)
      return "Break\t\(span(t.start, t.end))"
    }
  }

  // MARK: Navigation

  func showWeek(containing date: Date) {
    let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? weekStart
    guard start != weekStart else { return }
    weekStart = start
    drafts = [:]
    selection = nil
    reload()
  }

  func previousWeek() { showWeek(containing: calendar.date(byAdding: .day, value: -7, to: weekStart)!) }
  func nextWeek() { showWeek(containing: calendar.date(byAdding: .day, value: 7, to: weekStart)!) }

  // MARK: Reading

  /// The entries that start on `day`, oldest first, of the organization
  /// shown. One that started before the week shows on its first day.
  func entries(on day: Date) -> [ShiftStore.Entry] {
    sheet.entries.filter {
      self.isShown($0) && calendar.isDate(max($0.start, weekStart), inSameDayAs: day)
    }
  }

  // MARK: Organizations

  func organization(_ id: UUID) -> ShiftStore.Organization? {
    sheet.organizations.first { $0.id == id }
  }

  /// The organization a project belongs to; nil for unassigned time.
  func organizationOf(project: UUID?) -> ShiftStore.Organization? {
    guard let project, let p = self.project(project), let org = p.organizationId else { return nil }
    return organization(org)
  }

  /// Whether an entry is personal time: its organization has no shift, so
  /// it tracks itself and never counts as worked.
  func isPersonal(_ entry: ShiftStore.Entry) -> Bool {
    organizationOf(project: entry.projectId)?.tracking == .auto
  }

  /// The organization shown, if it's still there.
  var filteredOrganization: ShiftStore.Organization? {
    organizationFilter.flatMap { self.organization($0) }
  }

  /// Whether the organization shown has no shift, so no shifts show.
  var hidesShifts: Bool { filteredOrganization?.tracking == .auto }

  /// Whether `entry` shows: it's the shown organization's, or every one
  /// shows. Unassigned time is on the clock, so it shows under shift
  /// organizations.
  func isShown(_ entry: ShiftStore.Entry) -> Bool {
    guard let shown = filteredOrganization else { return true }
    if let org = organizationOf(project: entry.projectId) { return org.id == shown.id }
    return entry.projectId == nil && shown.tracking == .shift
  }

  /// The week's entries that show.
  var shownEntries: [ShiftStore.Entry] { sheet.entries.filter { self.isShown($0) } }

  /// The shifts clocked in on `day` that show: none for an organization
  /// with no shift.
  func shownShifts(on day: Date) -> [ShiftStore.SheetShift] {
    hidesShifts ? [] : shifts(on: day)
  }

  /// The week's shifts that show.
  var shownShifts: [ShiftStore.SheetShift] { hidesShifts ? [] : sheet.shifts }

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

  /// Time worked on a shift past its length, or 0. Under a minute doesn't
  /// count, so a shift clocked out on time doesn't read "+0m".
  func over(_ shift: ShiftStore.SheetShift, now: Date) -> TimeInterval {
    let over = worked(shift, now: now) - shift.length
    return over >= 60 ? over : 0
  }

  /// Time worked this week past each shift's length.
  func over(now: Date) -> TimeInterval {
    shownShifts.reduce(0) { $0 + over($1, now: now) }
  }

  /// Time on break during a shift.
  func onBreak(_ shift: ShiftStore.SheetShift, now: Date) -> TimeInterval {
    max(0, (shift.end ?? now).timeIntervalSince(shift.start) - worked(shift, now: now))
  }

  /// Time worked on a shift that no work entry covers, whichever
  /// organization shows. Personal time on the clock isn't work tracked.
  func untracked(_ shift: ShiftStore.SheetShift, now: Date) -> TimeInterval {
    let tracked = sheet.entries.filter { !self.isPersonal($0) }.map { ($0.start, $0.end ?? now) }
    return Spans.total(Spans.subtract(work(of: shift, now: now), tracked))
  }

  func worked(on day: Date, now: Date) -> TimeInterval {
    shownShifts(on: day).reduce(0) { $0 + worked($1, now: now) }
  }

  /// Time worked this week, on every shift shown.
  func worked(now: Date) -> TimeInterval {
    shownShifts.reduce(0) { $0 + worked($1, now: now) }
  }

  func untracked(now: Date) -> TimeInterval {
    shownShifts.reduce(0) { $0 + untracked($1, now: now) }
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

  /// Time tracked on `day`, personal time too.
  func total(on day: Date, now: Date) -> TimeInterval {
    entries(on: day).reduce(0) { $0 + seconds(of: $1, now: now) }
  }

  /// Work tracked this week: personal time isn't in it.
  func total(now: Date) -> TimeInterval {
    shownEntries.filter { !self.isPersonal($0) }.reduce(0) { $0 + seconds(of: $1, now: now) }
  }

  /// Personal time this week: on organizations with no shift, never worked.
  func personal(now: Date) -> TimeInterval {
    shownEntries.filter { self.isPersonal($0) }.reduce(0) { $0 + seconds(of: $1, now: now) }
  }

  /// Work time per project this week, most first. nil is unassigned.
  func totalsByProject(now: Date) -> [(project: UUID?, seconds: TimeInterval)] {
    byProject(shownEntries.filter { !self.isPersonal($0) }, now: now)
  }

  /// Personal time per project this week, most first.
  func personalByProject(now: Date) -> [(project: UUID?, seconds: TimeInterval)] {
    byProject(shownEntries.filter { self.isPersonal($0) }, now: now)
  }

  private func byProject(_ entries: [ShiftStore.Entry], now: Date)
    -> [(project: UUID?, seconds: TimeInterval)]
  {
    var totals: [UUID?: TimeInterval] = [:]
    for e in entries { totals[e.projectId, default: 0] += seconds(of: e, now: now) }
    // Ties by id, so equal rows don't swap places between redraws.
    return totals.map { ($0.key, $0.value) }.sorted {
      $0.seconds != $1.seconds
        ? $0.seconds > $1.seconds : ($0.project?.uuidString ?? "~") < ($1.project?.uuidString ?? "~")
    }
  }

  /// Work time per client this week, most first. nil is projects with no
  /// client and unassigned time.
  func totalsByClient(now: Date) -> [(client: UUID?, seconds: TimeInterval)] {
    var totals: [UUID?: TimeInterval] = [:]
    for e in shownEntries where !isPersonal(e) {
      totals[e.projectId.flatMap { project($0)?.clientId }, default: 0] += seconds(of: e, now: now)
    }
    return totals.map { ($0.key, $0.value) }.sorted {
      $0.seconds != $1.seconds
        ? $0.seconds > $1.seconds : ($0.client?.uuidString ?? "~") < ($1.client?.uuidString ?? "~")
    }
  }

  /// Time per project on `day`, personal time too, in the week's order,
  /// so a project stacks in the same place every day.
  func totalsByProject(on day: Date, now: Date) -> [(project: UUID?, seconds: TimeInterval)] {
    var totals: [UUID?: TimeInterval] = [:]
    for e in entries(on: day) { totals[e.projectId, default: 0] += seconds(of: e, now: now) }
    return byProject(shownEntries, now: now).compactMap { row in
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
    guard
      let id = write({ try store.addEntry(project: nil, workspace: nil, start: start, end: end) })
    else { return nil }
    registerUndo("Add Time") { $0.deleteEntry(id, action: "Add Time") }
    return id
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
    var state = EntryState(latest(entry))
    state.project = project
    state.workspace = workspace
    save(entry.id, state, action: "Change Project")
  }

  func setNote(_ entry: ShiftStore.Entry, to note: String) {
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    var state = EntryState(latest(entry))
    state.note = trimmed.isEmpty ? nil : trimmed
    save(entry.id, state, action: "Change Note")
  }

  func stop(_ entry: ShiftStore.Entry, now: Date = Date()) {
    let entry = latest(entry)
    guard entry.end == nil else { return }
    var state = EntryState(entry)
    state.end = max(now, entry.start.addingTimeInterval(1))
    save(entry.id, state, action: "Stop Timer")
  }

  func delete(_ entry: ShiftStore.Entry) {
    deleteEntry(entry.id, action: "Delete Time")
  }

  /// Whether a draft's times can be saved.
  static func isValid(start: Date, end: Date) -> Bool {
    let length = end.timeIntervalSince(start)
    return length > 0 && length <= maxEntry
  }

  /// An entry's fields, to save and to put back on undo.
  struct EntryState: Equatable {
    var project: UUID?
    var workspace: UUID?
    var start: Date
    var end: Date?
    var note: String?

    init(_ entry: ShiftStore.Entry) {
      project = entry.projectId
      workspace = entry.workspaceId
      start = entry.start
      end = entry.end
      note = entry.note
    }
  }

  /// Writes an entry's fields; undo puts back what they were. Edits of the
  /// same entry's times in quick succession undo together.
  private func save(_ id: UUID, _ state: EntryState, action: String, coalesce: Bool = false) {
    guard let current = sheet.entries.first(where: { $0.id == id }) else { return }
    let old = EntryState(current)
    guard state != old else { return }
    let saved = write {
      try store.editEntry(
        id, project: state.project, workspace: state.workspace, start: state.start,
        end: state.end, note: state.note)
    }
    guard saved != nil else { return }
    registerUndo(action, key: coalesce ? "entry \(id)" : nil) { $0.save(id, old, action: action) }
  }

  private func deleteEntry(_ id: UUID, action: String) {
    drafts[id] = nil
    guard write({ try store.deleteEntry(id) }) != nil else { return }
    if case .entry(id)? = selection { selection = nil }
    registerUndo(action) { $0.restoreEntry(id, action: action) }
  }

  private func restoreEntry(_ id: UUID, action: String) {
    guard write({ try store.restoreEntry(id) }) != nil else { return }
    registerUndo(action) { $0.deleteEntry(id, action: action) }
  }

  // MARK: Shifts

  /// Records a shift on `day` that you forgot to clock in for: around the
  /// day's tracked time, or 9 to 5. Never in the future.
  @discardableResult
  func addShift(on day: Date, now: Date = Date()) -> UUID? {
    guard let slot = shiftSlot(on: day, now: now),
      let id = write({ try store.addShift(start: slot.0, end: slot.1) })
    else { return nil }
    registerUndo("Add Shift") { $0.deleteShift(id, action: "Add Shift") }
    return id
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
      setClockIn(shift.id, to: start, length: shift.targetSecs)
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
    deleteShift(shift.id, action: "Delete Shift")
  }

  private func saveShift(_ shift: ShiftStore.SheetShift, start: Date, end: Date) {
    guard Self.isValid(start: start, end: end) else {
      drafts[shift.id] = Draft(start: start, end: end)
      return
    }
    drafts[shift.id] = nil
    setTimes(shift.id, start: start, end: end)
  }

  /// Moves an ended shift; undo moves it back.
  private func setTimes(_ id: UUID, start: Date, end: Date) {
    guard let old = sheet.shifts.first(where: { $0.id == id }), let oldEnd = old.end,
      old.start != start || oldEnd != end
    else { return }
    guard write({ try store.setShiftTimes(id, start: start, end: end) }) != nil else { return }
    registerUndo("Change Shift", key: "shift \(id)") {
      $0.setTimes(id, start: old.start, end: oldEnd)
    }
  }

  /// Moves the open shift's clock in; undo moves it back.
  private func setClockIn(_ id: UUID, to start: Date, length: Int64) {
    guard let old = sheet.shifts.first(where: { $0.id == id }), old.start != start else { return }
    guard write({ try store.editShift(id, clockIn: start, lengthSeconds: length) }) != nil
    else { return }
    registerUndo("Change Shift", key: "shift \(id)") {
      $0.setClockIn(id, to: old.start, length: length)
    }
  }

  private func deleteShift(_ id: UUID, action: String) {
    drafts[id] = nil
    guard write({ try store.deleteShift(id) }) != nil else { return }
    if case .shift(id)? = selection { selection = nil }
    registerUndo(action) { $0.restoreShift(id, action: action) }
  }

  private func restoreShift(_ id: UUID, action: String) {
    guard write({ try store.restoreShift(id) }) != nil else { return }
    registerUndo(action) { $0.deleteShift(id, action: action) }
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
    let id = UUID()
    guard
      putBreak(
        id, shift: shift.id, start: start, end: start.addingTimeInterval(30 * 60),
        action: "Add Break")
    else { return nil }
    return id
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
    drafts[brk.id] = nil
    putBreak(
      brk.id, shift: shift.id, start: brk.start, end: max(now, brk.start.addingTimeInterval(60)),
      action: "End Break")
  }

  func delete(_ brk: ShiftStore.SheetBreak) {
    guard let shift = breakAndShift(brk.id)?.shift else { return }
    deleteBreak(brk.id, shift: shift.id, action: "Delete Break")
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
    putBreak(brk.id, shift: shift.id, start: start, end: end, action: "Change Break", coalesce: true)
  }

  /// Creates or replaces a break; undo puts back what was there, or
  /// deletes it if nothing was.
  @discardableResult
  private func putBreak(
    _ id: UUID, shift: UUID, start: Date, end: Date?, action: String, coalesce: Bool = false
  ) -> Bool {
    let old = breakAndShift(id)?.brk
    if let old, old.start == start, old.end == end { return true }
    guard write({ try store.putBreak(.init(id: id, start: start, end: end), shift: shift) }) != nil
    else { return false }
    registerUndo(action, key: coalesce ? "break \(id)" : nil) { model in
      if let old {
        model.putBreak(id, shift: shift, start: old.start, end: old.end, action: action)
      } else {
        model.deleteBreak(id, shift: shift, action: action)
      }
    }
    return true
  }

  private func deleteBreak(_ id: UUID, shift: UUID, action: String) {
    guard let old = breakAndShift(id)?.brk else { return }
    drafts[id] = nil
    guard write({ try store.deleteBreak(id) }) != nil else { return }
    if case .brk(id)? = selection { selection = nil }
    registerUndo(action) {
      $0.putBreak(id, shift: shift, start: old.start, end: old.end, action: action)
    }
  }

  // MARK: Undo

  /// Registers `undo` under `action`, as one step. With a `key`, another
  /// change with the same key within a few seconds joins this one, so a
  /// time typed digit by digit undoes at once.
  private func registerUndo(
    _ action: String, key: String? = nil, _ undo: @escaping (TimesheetModel) -> Void
  ) {
    guard let undoManager else { return }
    let replaying = undoManager.isUndoing || undoManager.isRedoing
    let now = Date()
    if !replaying, let key, let last = lastUndo, last.key == key,
      now.timeIntervalSince(last.at) < 3, undoManager.canUndo
    {
      lastUndo = (key, now)
      return
    }
    undoManager.registerUndo(withTarget: self) { undo($0) }
    undoManager.setActionName(action)
    lastUndo = replaying ? nil : key.map { ($0, now) }
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
    var state = EntryState(entry)
    state.start = start
    state.end = end
    // A running entry only has a start.
    if let end, !Self.isValid(start: start, end: end) {
      drafts[entry.id] = Draft(start: start, end: end)
      return
    }
    drafts[entry.id] = nil
    save(entry.id, state, action: "Change Time", coalesce: true)
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

// MARK: Meetings

extension TimesheetModel {
  /// The week's meetings that start on `day`, oldest first.
  func meetings(on day: Date) -> [ShiftStore.Entry] {
    entries(on: day).filter(\.isMeeting)
  }

  /// The days shown with a meeting on them.
  var meetingDays: [Date] { days.filter { !meetings(on: $0).isEmpty } }

  /// How many meetings the week has, and how long they ran.
  func meetingCount() -> Int { sheet.entries.filter(\.isMeeting).count }

  func meetingTime(on day: Date? = nil, now: Date) -> TimeInterval {
    let meetings = day.map { self.meetings(on: $0) } ?? sheet.entries.filter(\.isMeeting)
    return meetings.reduce(0) { $0 + seconds(of: $1, now: now) }
  }

  /// Makes an entry a meeting, its note its title, or plain work again.
  func setMeeting(_ entry: ShiftStore.Entry, _ meeting: Bool) {
    guard latest(entry).isMeeting != meeting,
      write({ try store.setMeeting(entry.id, meeting) }) != nil
    else { return }
    let action = meeting ? "Mark as Meeting" : "Not a Meeting"
    registerUndo(action) { $0.setMeeting(entry, !meeting) }
  }

  /// Adds a half-hour meeting on `day`: after its last entry, or ending
  /// now today. It goes on the project of the week's last meeting.
  @discardableResult
  func addMeeting(on day: Date, now: Date = Date()) -> UUID? {
    let (start, _) = slot(on: day, now: now)
    let end = start.addingTimeInterval(30 * 60)
    let last = sheet.entries.last(where: \.isMeeting)
    guard
      let id = write({
        try store.addMeeting(
          project: last?.projectId, workspace: last?.workspaceId, start: start, end: end,
          title: "Meeting")
      })
    else { return nil }
    registerUndo("Add Meeting") { $0.deleteEntry(id, action: "Add Meeting") }
    return id
  }

  /// Links `keyword` to `project`, so a call whose title has it logs
  /// there.
  func link(keyword: String, to project: UUID) {
    let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !word.isEmpty else { return }
    write { try store.link(keyword: word, to: .init(project: project)) }
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

enum TimesheetFormat {
  /// "7h 30m", "45m", "8h": short enough for the strip and rows.
  static func duration(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int((seconds / 60).rounded()))
    let (h, m) = (minutes / 60, minutes % 60)
    switch (h, m) {
    case (0, _): return "\(m)m"
    case (_, 0): return "\(h)h"
    default: return "\(h)h \(m)m"
    }
  }
}
