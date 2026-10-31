import Foundation
import Observation

/// What the project views need to name and color a project.
protocol ProjectNames {
  func project(_ id: UUID) -> ShiftStore.Project?
  /// The project's place among all projects, for its default color.
  func rank(of project: UUID) -> Int?
}

extension Array where Element == ShiftStore.Project {
  /// A project's place among these, oldest first, so a default color stays
  /// put as projects are added. Ids are UUIDv7, so they sort by creation.
  func rank(of project: UUID) -> Int? {
    map(\.id).sorted { $0.uuidString < $1.uuidString }.firstIndex(of: project)
  }
}

/// Every project, to rename, recolor, or delete. The CLI and TUI see the
/// same ones.
@Observable final class ProjectsModel: ProjectNames {
  private(set) var list = ShiftStore.Projects()
  /// The last problem, shown until the next successful change.
  private(set) var error: String?

  @ObservationIgnored let store: ShiftStore

  init(store: ShiftStore) {
    self.store = store
  }

  var projects: [ShiftStore.Project] { list.projects }

  func reload(now: Date = Date()) {
    do {
      let fresh = try store.projects(now: now)
      if fresh != list { list = fresh }
    } catch {
      self.error = "Couldn't read your projects (\(error))."
    }
  }

  func project(_ id: UUID) -> ShiftStore.Project? { list.projects.first { $0.id == id } }
  func rank(of project: UUID) -> Int? { list.projects.rank(of: project) }
  func client(_ id: UUID) -> ShiftStore.Client? { list.clients.first { $0.id == id } }
  func usage(of project: UUID) -> ShiftStore.Usage? { list.usage.first { $0.projectId == project } }

  func workspaces(of project: UUID) -> [ShiftStore.Workspace] {
    list.workspaces.filter { $0.projectId == project }
  }

  /// Renames `project`. Returns whether the name was taken: an empty name
  /// or one another project has is refused.
  @discardableResult
  func rename(_ project: ShiftStore.Project, to name: String) -> Bool {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let project = self.project(project.id), name != project.name else { return true }
    guard !name.isEmpty else {
      error = "A project needs a name."
      return false
    }
    if let other = existing(named: name), other.id != project.id {
      error = "There's already a project called \u{201C}\(other.name)\u{201D}."
      return false
    }
    return write {
      try store.editProject(project.id, name: name, client: project.clientId, color: project.color)
    } != nil
  }

  /// Sets `project`'s color (`#rrggbb`), or nil to go back to its default.
  func setColor(_ project: ShiftStore.Project, to hex: String?) {
    guard let project = self.project(project.id), hex != project.color else { return }
    write {
      try store.editProject(project.id, name: project.name, client: project.clientId, color: hex)
    }
  }

  /// Deletes `project` and its workspaces; its time stays, unassigned.
  func delete(_ project: ShiftStore.Project) {
    write { try store.deleteProject(project.id) }
  }

  /// Creates a project, or returns the one that already has that name.
  @discardableResult
  func create(named name: String) -> UUID? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    if let existing = existing(named: name) { return existing.id }
    return write { try store.createProject(name: name) }
  }

  func clearError() { error = nil }

  private func existing(named name: String) -> ShiftStore.Project? {
    list.projects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
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
}
