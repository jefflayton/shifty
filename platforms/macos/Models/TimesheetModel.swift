import Foundation
import Observation

/// A week of time entries from the store, for the main window's timesheet:
/// add time after the fact (a meeting, offline work), fix times, reassign
/// projects. The CLI and TUI write the same entries.
@Observable final class TimesheetModel {
  /// Midnight starting the week shown.
  private(set) var weekStart: Date
  private(set) var sheet = ShiftStore.Timesheet()
  /// Times being edited that don't make a valid entry yet, by entry.
  private(set) var drafts: [UUID: Draft] = [:]
  /// The last store error, shown until the next successful change.
  private(set) var error: String?

  @ObservationIgnored let store: ShiftStore
  @ObservationIgnored let calendar: Calendar

  /// An entry's start and end as typed. Kept out of the store until the end
  /// comes after the start.
  struct Draft: Equatable {
    var start: Date
    var end: Date
  }

  /// No entry is longer than this; an end that would make one is a typo.
  static let maxEntry: TimeInterval = 16 * 60 * 60

  init(store: ShiftStore, calendar: Calendar = .current, now: Date = Date()) {
    self.store = store
    self.calendar = calendar
    weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
  }

  var week: DateInterval {
    DateInterval(start: weekStart, end: calendar.date(byAdding: .day, value: 7, to: weekStart)!)
  }

  var days: [Date] {
    (0..<7).map { calendar.date(byAdding: .day, value: $0, to: weekStart)! }
  }

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

  /// A project's place among all projects, oldest first, for picking it a
  /// color that stays put as projects are added. Ids are UUIDv7, so they
  /// sort by creation.
  func rank(of project: UUID) -> Int? {
    sheet.projects.map(\.id).sorted { $0.uuidString < $1.uuidString }.firstIndex(of: project)
  }

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

  /// Runs a store write, then reloads; a failure is shown, not thrown.
  @discardableResult
  private func write<T>(_ body: () throws -> T) -> T? {
    do {
      let value = try body()
      error = nil
      reload()
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

  static func roundedToQuarter(_ date: Date, calendar: Calendar) -> Date {
    let c = calendar.dateComponents([.hour, .minute], from: date)
    let minutes = ((c.hour ?? 0) * 60 + (c.minute ?? 0) + 7) / 15 * 15
    return calendar.startOfDay(for: date).addingTimeInterval(TimeInterval(minutes * 60))
  }
}
