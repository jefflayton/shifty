import Foundation
import Observation

/// The running timer, for the menu bar: what it's for, and picking a
/// project to track. The TUI and CLI start and stop the same timer.
@Observable final class TrackingModel: ProjectNames {
  /// The running entry, if any.
  private(set) var running: ShiftStore.Entry?
  private(set) var projects: [ShiftStore.Project] = []
  private(set) var workspaces: [ShiftStore.Workspace] = []

  @ObservationIgnored let store: ShiftStore
  /// Runs after a change here: starting a timer ends a break, which the
  /// shift needs to pick up.
  @ObservationIgnored var didChange: (() -> Void)?

  init(store: ShiftStore) {
    self.store = store
  }

  func reload(now: Date = Date()) {
    do {
      let sheet = try store.timesheet(DateInterval(start: now, duration: 1))
      let fresh = sheet.entries.first { $0.end == nil }
      if fresh != running { running = fresh }
      if sheet.projects != projects { projects = sheet.projects }
      if sheet.workspaces != workspaces { workspaces = sheet.workspaces }
    } catch {
      log("tracking reload:", error)
    }
  }

  /// Stops the timer where a planned break (like a class) began, once one
  /// has, as Start Break does. `breaks` are the shift's, on the clock. Only
  /// writes when there's something to stop.
  func stopForBreaks(_ breaks: [(start: Date, end: Date)], now: Date = Date()) {
    guard let running,
      breaks.contains(where: { $0.start > running.start && $0.start <= now })
    else { return }
    do {
      if try store.stopForBreaks(now: now) {
        reload(now: now)
        didChange?()
      }
    } catch {
      log("stop for breaks:", error)
    }
  }

  func project(_ id: UUID) -> ShiftStore.Project? { projects.first { $0.id == id } }
  func rank(of project: UUID) -> Int? { projects.rank(of: project) }

  func workspaces(of project: UUID) -> [ShiftStore.Workspace] {
    workspaces.filter { $0.projectId == project }
  }

  /// `project / workspace`, `project`, or nil for unassigned time.
  func label(project: UUID?, workspace: UUID?) -> String? {
    guard let project else { return nil }
    let name = self.project(project)?.name ?? "Archived project"
    guard let workspace, let ws = workspaces.first(where: { $0.id == workspace }) else {
      return name
    }
    return "\(name) / \(ws.name)"
  }

  /// Tracks `project` (and `workspace`) from now on. A running timer with
  /// no project gets this one, time so far included; one for another
  /// project, or a meeting, stops, so its time stays where it was, and a
  /// new one starts.
  func choose(project: UUID?, workspace: UUID?, now: Date = Date()) {
    reload(now: now)
    if let running {
      // Picking a meeting's own project goes back to work on it.
      if running.projectId == project && running.workspaceId == workspace && !running.isMeeting {
        return
      }
      if running.projectId == nil {
        write {
          try store.editEntry(
            running.id, project: project, workspace: workspace, start: running.start, end: nil,
            note: running.note)
        }
        return
      }
    }
    write { try store.startEntry(project: project, workspace: workspace, now: now) }
  }

  /// The running entry's project, or nil if nothing runs or it has none.
  var runningTarget: ShiftStore.Target? {
    running?.projectId.map { ShiftStore.Target(project: $0, workspace: running?.workspaceId) }
  }

  /// Moves the running timer to `target` from `since` (clamped to after it
  /// started, and not past `now`): the running entry ends there and a new
  /// one starts. An unassigned timer gets the project instead, all of it.
  /// Returns what puts it back, or nil if nothing changed.
  func switchTo(_ target: ShiftStore.Target, since: Date, now: Date = Date()) -> (() -> Void)? {
    reload(now: now)
    guard let old = running, runningTarget != target else { return nil }
    if old.projectId == nil {
      let done: Void? = write {
        try store.editEntry(
          old.id, project: target.project, workspace: target.workspace, start: old.start,
          end: nil, note: old.note)
      }
      guard done != nil else { return nil }
      return { [weak self] in
        self?.write {
          try self?.store.editEntry(
            old.id, project: nil, workspace: nil, start: old.start, end: nil, note: old.note)
        }
      }
    }
    let at = min(now, max(since, old.start.addingTimeInterval(1)))
    guard
      let new = write({
        try store.startEntry(project: target.project, workspace: target.workspace, now: at)
      })
    else { return nil }
    return { [weak self] in
      self?.write {
        guard let self else { return }
        try self.store.deleteEntry(new)
        try self.store.editEntry(
          old.id, project: old.projectId, workspace: old.workspaceId, start: old.start, end: nil,
          note: old.note)
      }
    }
  }

  /// Starts a timer for `target` from `since` (not past `now`) when none
  /// runs. Returns what takes it back, or nil if one was running.
  func start(_ target: ShiftStore.Target, since: Date, now: Date = Date()) -> (() -> Void)? {
    reload(now: now)
    guard running == nil,
      let new = write({
        try store.startEntry(
          project: target.project, workspace: target.workspace, now: min(since, now))
      })
    else { return nil }
    return { [weak self] in self?.write { try self?.store.deleteEntry(new) } }
  }

  /// Logs a meeting titled `title` for `target` from `since`, when the
  /// call began (clamped to after the running entry started, and not past
  /// `now`): the running entry ends there, even if it's for the same
  /// project, and the meeting runs from then. An unassigned timer gets the
  /// project for its time so far. A meeting logged since `since`, for this
  /// call, moves to `target` instead. Returns what puts it back, or nil if
  /// nothing changed: a meeting for `target` already runs.
  func startMeeting(
    _ target: ShiftStore.Target?, title: String, since: Date, now: Date = Date()
  ) -> (() -> Void)? {
    reload(now: now)
    let old = running
    if let old, old.isMeeting, runningTarget == target { return nil }
    // A meeting logged for this call moves, whole, rather than splitting.
    if let old, old.isMeeting, old.start >= since, let target {
      let done: Void? = write {
        try store.editEntry(
          old.id, project: target.project, workspace: target.workspace, start: old.start,
          end: nil, note: title)
      }
      guard done != nil else { return nil }
      return { [weak self] in
        self?.write {
          try self?.store.editEntry(
            old.id, project: old.projectId, workspace: old.workspaceId, start: old.start,
            end: nil, note: old.note)
        }
      }
    }
    let at = old.map { min(now, max(since, $0.start.addingTimeInterval(1))) } ?? min(since, now)
    guard
      let new = write({ () throws -> UUID in
        if let old, old.projectId == nil, let target {
          try store.editEntry(
            old.id, project: target.project, workspace: target.workspace, start: old.start,
            end: nil, note: old.note)
        }
        return try store.startMeeting(
          project: target?.project, workspace: target?.workspace, title: title, at: at)
      })
    else { return nil }
    return { [weak self] in
      self?.write {
        guard let self else { return }
        try self.store.deleteEntry(new)
        guard let old else { return }
        try self.store.editEntry(
          old.id, project: old.projectId, workspace: old.workspaceId, start: old.start, end: nil,
          note: old.note)
      }
    }
  }

  /// Ends the running meeting at `end` (clamped to after it started, and
  /// not past `now`) and, with `resume`, starts a timer for `back` from
  /// then: what ran before the call. Returns what puts it back, or nil if
  /// no meeting runs.
  func endMeeting(
    at end: Date, resume: Bool, back: ShiftStore.Target?, now: Date = Date()
  ) -> (() -> Void)? {
    reload(now: now)
    guard let meeting = running, meeting.isMeeting else { return nil }
    let at = min(now, max(end, meeting.start.addingTimeInterval(1)))
    guard
      let new = write({ () throws -> UUID? in
        guard resume else {
          try store.stopEntry(now: at)
          return nil
        }
        return try store.startEntry(project: back?.project, workspace: back?.workspace, now: at)
      })
    else { return nil }
    return { [weak self] in
      self?.write {
        guard let self else { return }
        if let new { try self.store.deleteEntry(new) }
        try self.store.editEntry(
          meeting.id, project: meeting.projectId, workspace: meeting.workspaceId,
          start: meeting.start, end: nil, note: meeting.note)
      }
    }
  }

  /// Retitles the running meeting, once its title is known.
  func retitleMeeting(_ title: String, now: Date = Date()) {
    reload(now: now)
    guard let meeting = running, meeting.isMeeting, meeting.note != title else { return }
    write {
      try store.editEntry(
        meeting.id, project: meeting.projectId, workspace: meeting.workspaceId,
        start: meeting.start, end: nil, note: title)
    }
  }

  func stop(now: Date = Date()) {
    write { try store.stopEntry(now: now) }
  }

  /// Creates a project, or returns the one that already has that name.
  func createProject(named name: String) -> UUID? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    if let existing = projects.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
      return existing.id
    }
    return write { try store.createProject(name: name) }
  }

  @discardableResult
  private func write<T>(_ body: () throws -> T) -> T? {
    defer {
      reload()
      didChange?()
    }
    do {
      return try body()
    } catch {
      log("tracking:", error)
      return nil
    }
  }
}
