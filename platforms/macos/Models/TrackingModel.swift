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
  /// project stops, so its time stays where it was, and a new one starts.
  func choose(project: UUID?, workspace: UUID?, now: Date = Date()) {
    reload(now: now)
    if let running {
      if running.projectId == project && running.workspaceId == workspace { return }
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
