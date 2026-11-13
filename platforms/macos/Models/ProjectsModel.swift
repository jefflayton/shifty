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

/// Projects by organization, for menus: each organization's in turn, with
/// its name when there's more than one. A project whose organization is
/// gone goes with the first on the shift, as the core has it.
struct ProjectGroup: Identifiable {
  /// The organization's; nil for projects none has.
  var id: UUID?
  /// Nil when everything's in one group.
  var title: String?
  var projects: [ShiftStore.Project]

  static func of(
    _ projects: [ShiftStore.Project], in organizations: [ShiftStore.Organization]
  ) -> [ProjectGroup] {
    let fallback = organizations.first { $0.tracking == .shift } ?? organizations.first
    var groups = organizations.map { org in
      ProjectGroup(id: org.id, title: org.name, projects: [])
    }
    var loose: [ShiftStore.Project] = []
    for project in projects {
      let org =
        project.organizationId.flatMap { id in organizations.first { $0.id == id } } ?? fallback
      if let org, let i = groups.firstIndex(where: { $0.id == org.id }) {
        groups[i].projects.append(project)
      } else {
        loose.append(project)
      }
    }
    if !loose.isEmpty { groups.append(ProjectGroup(id: nil, title: nil, projects: loose)) }
    groups.removeAll { $0.projects.isEmpty }
    if groups.count == 1 { groups[0].title = nil }
    return groups
  }
}

/// Every project, to rename, recolor, or delete. The CLI and TUI see the
/// same ones.
@Observable final class ProjectsModel: ProjectNames {
  private(set) var list = ShiftStore.Projects()
  /// What's linked to each project: repos, folders, and apps.
  private(set) var links: [ShiftStore.Link] = []
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
      let freshLinks = try store.links()
      if freshLinks != links { links = freshLinks }
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

  /// Creates a project in `organization` (nil: the default one), or
  /// returns the one that already has that name.
  @discardableResult
  func create(named name: String, in organization: UUID? = nil) -> UUID? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    if let existing = existing(named: name) { return existing.id }
    return write { try store.createProject(name: name, organization: organization) }
  }

  // MARK: Organizations

  var organizations: [ShiftStore.Organization] { list.organizations }

  func organization(_ id: UUID) -> ShiftStore.Organization? {
    list.organizations.first { $0.id == id }
  }

  /// Where new projects go, and a project without one belongs: the first
  /// organization on the shift, else the first.
  var defaultOrganization: ShiftStore.Organization? {
    list.organizations.first { $0.tracking == .shift } ?? list.organizations.first
  }

  func organizationOf(_ project: ShiftStore.Project) -> ShiftStore.Organization? {
    if let id = project.organizationId, let org = organization(id) { return org }
    return defaultOrganization
  }

  func projects(in organization: ShiftStore.Organization) -> [ShiftStore.Project] {
    list.projects.filter { self.organizationOf($0)?.id == organization.id }
  }

  /// Moves `project`, and its time, to `organization`.
  func move(_ project: ShiftStore.Project, to organization: ShiftStore.Organization) {
    guard organizationOf(project)?.id != organization.id else { return }
    write { try store.moveProject(project.id, to: organization.id) }
  }

  /// Adds an organization. Nil if the name is empty or taken.
  @discardableResult
  func createOrganization(named name: String, tracking: ShiftStore.Tracking) -> UUID? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      error = "An organization needs a name."
      return nil
    }
    if let other = existingOrganization(named: name) {
      error = "There's already an organization called \u{201C}\(other.name)\u{201D}."
      return nil
    }
    return write { try store.createOrganization(name: name, tracking: tracking) }
  }

  /// Renames `organization`. False if the name is empty or taken.
  @discardableResult
  func rename(_ organization: ShiftStore.Organization, to name: String) -> Bool {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let org = self.organization(organization.id), name != org.name else { return true }
    guard !name.isEmpty else {
      error = "An organization needs a name."
      return false
    }
    if let other = existingOrganization(named: name), other.id != org.id {
      error = "There's already an organization called \u{201C}\(other.name)\u{201D}."
      return false
    }
    return write {
      try store.editOrganization(org.id, name: name, tracking: org.tracking, color: org.color)
    } != nil
  }

  /// Puts `organization` on the shift, or has it track itself: its time is
  /// then personal, never worked.
  func setTracking(_ organization: ShiftStore.Organization, to tracking: ShiftStore.Tracking) {
    guard let org = self.organization(organization.id), org.tracking != tracking else { return }
    write { try store.editOrganization(org.id, name: org.name, tracking: tracking, color: org.color) }
  }

  /// Where a deleted organization's projects go: the first other one on
  /// the shift, else the first other. Nil for the only one.
  func successor(of organization: ShiftStore.Organization) -> ShiftStore.Organization? {
    let others = list.organizations.filter { $0.id != organization.id }
    return others.first { $0.tracking == .shift } ?? others.first
  }

  /// Deletes `organization`; its projects and their time move to its
  /// successor.
  func delete(_ organization: ShiftStore.Organization) {
    guard let to = successor(of: organization) else {
      error = "\(organization.name) is the only organization."
      return
    }
    write { try store.deleteOrganization(organization.id, moveTo: to.id) }
  }

  private func existingOrganization(named name: String) -> ShiftStore.Organization? {
    list.organizations.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
  }

  func clearError() { error = nil }

  func links(of project: UUID) -> [ShiftStore.Link] {
    links.filter { $0.projectId == project }
  }

  /// Links the repo or folder at `dir` to `project`. Returns what it linked
  /// by: its Situ ids, its git remote, or its path.
  @discardableResult
  func link(dir: String, to project: UUID) -> ShiftStore.Via? {
    write { try store.link(dir: dir, to: .init(project: project)) }
  }

  func link(app bundleID: String, to project: UUID) {
    write { try store.link(app: bundleID, to: .init(project: project)) }
  }

  /// Links a keyword to `project`: a window titled with it, like a Rex
  /// session or tab, is the project's. False if it can't be one.
  @discardableResult
  func link(keyword: String, to project: UUID) -> Bool {
    let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !word.isEmpty, word.utf8.count <= 64, !word.contains(where: \.isNewline) else {
      error = "A keyword is 1 to 64 characters on one line."
      return false
    }
    return write { try store.link(keyword: word, to: .init(project: project)) } != nil
  }

  /// Removes `link` from its project; other projects linked to the same
  /// repo, folder, or app keep theirs.
  func unlink(_ link: ShiftStore.Link) {
    write { try store.unlink(link) }
  }

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
