import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Every project, to rename, recolor, or delete, with how much each has
/// been used.
struct ProjectsView: View {
  @Bindable var model: ProjectsModel
  @State private var selection: UUID?
  /// The project the delete confirmation is for.
  @State private var deleting: ShiftStore.Project?

  var body: some View {
    List(selection: $selection) {
      ForEach(model.projects) { project in
        ProjectRow(model: model, project: project) { deleting = project }
          .tag(project.id)
      }
    }
    .listStyle(.inset)
    .overlay {
      if model.projects.isEmpty {
        ContentUnavailableView {
          Label("No Projects", systemImage: "folder")
        } description: {
          Text("Projects sort your time by what it's for. Pick one on any entry in the timesheet.")
        } actions: {
          Button("New Project") { NewProjectPrompt.run(create: model.create(named:)) }
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .font(.callout)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.vertical, 8)
          .background(.bar)
      }
    }
    .onDeleteCommand {
      deleting = model.projects.first { $0.id == selection }
    }
    .navigationTitle("Projects")
    .navigationSubtitle(
      model.projects.count == 1 ? "1 project" : "\(model.projects.count) projects")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          if let id = NewProjectPrompt.run(create: model.create(named:)) { selection = id }
        } label: {
          Label("New Project", systemImage: "plus")
        }
        .keyboardShortcut("n", modifiers: .command)
        .help("New project (⌘N)")
      }
    }
    .alert(
      "Delete \u{201C}\(deleting?.name ?? "")\u{201D}?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      presenting: deleting
    ) { project in
      Button("Delete Project", role: .destructive) { model.delete(project) }
      Button("Cancel", role: .cancel) {}
    } message: { project in
      Text(
        ProjectRow.deleteMessage(
          usage: model.usage(of: project.id), workspaces: model.workspaces(of: project.id)))
    }
  }
}

struct ProjectRow: View {
  let model: ProjectsModel
  let project: ShiftStore.Project
  /// Asks to delete it.
  let onDelete: () -> Void

  @State private var name = ""
  @State private var hovered = false
  @FocusState private var nameFocused: Bool

  var body: some View {
    let usage = model.usage(of: project.id)
    let workspaces = model.workspaces(of: project.id)

    HStack(spacing: 12) {
      SwatchButton(model: model, project: project)

      VStack(alignment: .leading, spacing: 2) {
        TextField("Name", text: $name)
          .textFieldStyle(.plain)
          .font(.body.weight(.medium))
          .focused($nameFocused)
          .onSubmit(commit)
        let client = project.clientId.flatMap { model.client($0)?.name }
        let links = model.links(of: project.id)
        if client != nil || !workspaces.isEmpty || !links.isEmpty {
          HStack(spacing: 10) {
            if let client { Text(client) }
            if !workspaces.isEmpty {
              Label(workspaces.map(\.name).joined(separator: ", "), systemImage: "folder")
                .labelStyle(.titleAndIcon)
                .help("Workspaces")
            }
            if !links.isEmpty {
              Label(links.map(LinkName.name).joined(separator: ", "), systemImage: "link")
                .labelStyle(.titleAndIcon)
                .help(
                  "Auto-switch tracks this project in "
                    + links.map(LinkName.detail).joined(separator: ", "))
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        }
      }

      Spacer(minLength: 12)

      VStack(alignment: .trailing, spacing: 2) {
        if let usage {
          Text(TimesheetFormat.duration(TimeInterval(usage.seconds)))
            .font(.system(.body, design: .rounded).weight(.medium))
            .monospacedDigit()
          Text("Last used \(Self.lastUsed(usage.lastUsed))")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text("No time yet")
            .foregroundStyle(.tertiary)
        }
      }

      LinkMenu(model: model, project: project)
        .opacity(hovered ? 1 : 0)
        .accessibilityHidden(!hovered)

      Button(action: onDelete) {
        Image(systemName: "trash").foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .help("Delete this project")
      .opacity(hovered ? 1 : 0)
      .accessibilityHidden(!hovered)
    }
    // One height for every row, caption line or not. The list measures a
    // row once, so a row that gains or loses its caption (a link added or
    // moved) would keep its old height and clip or float.
    .frame(height: 38)
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .contextMenu {
      Button("Rename") { nameFocused = true }
      LinkMenu.items(model: model, project: project)
      Divider()
      Button("Delete…", role: .destructive, action: onDelete)
    }
    .onAppear { name = project.name }
    .onChange(of: project.name) { _, new in
      if !nameFocused { name = new }
    }
    .onChange(of: nameFocused) { _, focused in
      if !focused { commit() }
    }
  }

  private func commit() {
    if !model.rename(project, to: name) { name = project.name }
  }

  static func lastUsed(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    if calendar.isDate(date, inSameDayAs: now) { return "today" }
    if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) {
      return "yesterday"
    }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
      return date.formatted(.dateTime.month(.abbreviated).day())
    }
    return date.formatted(.dateTime.month(.abbreviated).day().year())
  }

  static func deleteMessage(usage: ShiftStore.Usage?, workspaces: [ShiftStore.Workspace]) -> String {
    var parts: [String] = []
    if let usage, usage.seconds > 0 {
      parts.append(
        "Its \(TimesheetFormat.duration(TimeInterval(usage.seconds))) of time stays on your timesheet, under No project."
      )
    } else {
      parts.append("It has no time recorded.")
    }
    if !workspaces.isEmpty {
      parts.append(
        workspaces.count == 1
          ? "Its workspace \u{201C}\(workspaces[0].name)\u{201D} is deleted too."
          : "Its \(workspaces.count) workspaces are deleted too.")
    }
    return parts.joined(separator: " ")
  }
}

/// A project's color; click to pick another.
struct SwatchButton: View {
  let model: ProjectsModel
  let project: ShiftStore.Project

  @State private var picking = false
  @State private var hovered = false

  var body: some View {
    let color = ProjectColor.color(project.id, in: model)
    Button { picking = true } label: {
      Circle()
        .fill(color)
        .frame(width: 18, height: 18)
        .overlay(Circle().strokeBorder(.primary.opacity(hovered ? 0.35 : 0.1), lineWidth: 1))
        .padding(3)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .help("Change color")
    .accessibilityLabel("Color")
    .popover(isPresented: $picking, arrowEdge: .bottom) {
      ColorChoices(model: model, project: project)
    }
  }
}

/// The palette, the project's default, and any color at all.
struct ColorChoices: View {
  let model: ProjectsModel
  let project: ShiftStore.Project

  var body: some View {
    let current = ProjectColor.color(project.id, in: model)
    VStack(alignment: .leading, spacing: 12) {
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 8), count: 4), spacing: 8) {
        ForEach(ProjectColor.paletteHex, id: \.self) { hex in
          let chosen = project.color?.caseInsensitiveCompare(hex) == .orderedSame
          Button { model.setColor(project, to: hex) } label: {
            Circle()
              .fill(ProjectColor.parse(hex)!)
              .frame(width: 22, height: 22)
              .padding(2)
              .overlay(Circle().strokeBorder(chosen ? Color.primary : .clear, lineWidth: 2))
              .contentShape(Circle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(hex)
        }
      }
      Divider()
      Button("Custom Color…") {
        CustomColor.shared.pick(NSColor(current)) { [model, project] in
          model.setColor(project, to: ProjectColor.hex(Color(nsColor: $0)))
        }
      }
      .buttonStyle(.link)
      if project.color != nil {
        Button("Use Default Color") { model.setColor(project, to: nil) }
          .buttonStyle(.link)
      }
    }
    .padding(14)
    .fixedSize()
  }
}

/// The system color panel, applying what's picked to one project. Outlives
/// the popover that opened it.
@MainActor
final class CustomColor: NSObject {
  static let shared = CustomColor()
  private var apply: ((NSColor) -> Void)?

  func pick(_ initial: NSColor, apply: @escaping (NSColor) -> Void) {
    self.apply = nil
    let panel = NSColorPanel.shared
    panel.showsAlpha = false
    panel.isContinuous = true
    panel.color = initial
    self.apply = apply
    panel.setTarget(self)
    panel.setAction(#selector(changed(_:)))
    panel.makeKeyAndOrderFront(nil)
  }

  @objc private func changed(_ panel: NSColorPanel) { apply?(panel.color) }
}

/// Linking a project to the repos, folders, and apps auto-switch tracks it
/// in.
struct LinkMenu: View {
  let model: ProjectsModel
  let project: ShiftStore.Project

  var body: some View {
    Menu {
      Self.items(model: model, project: project)
    } label: {
      Image(systemName: "link")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Link a repo, folder, or app")
  }

  @ViewBuilder static func items(model: ProjectsModel, project: ShiftStore.Project) -> some View {
    Button("Link Repo or Folder…") {
      if let dir = pick(directory: true) { model.link(dir: dir, to: project.id) }
    }
    Button("Link App…") {
      if let app = pick(directory: false), let id = Bundle(path: app)?.bundleIdentifier {
        model.link(app: id, to: project.id)
      }
    }
    let links = model.links(of: project.id)
    if !links.isEmpty {
      Menu("Unlink") {
        ForEach(links) { link in
          Button(LinkName.detail(link)) { model.unlink(link) }
        }
      }
    }
  }

  /// A folder, or an app in Applications.
  private static func pick(directory: Bool) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = directory
    panel.canChooseFiles = !directory
    panel.allowsMultipleSelection = false
    if directory {
      panel.message = "Choose a repo or folder. Auto-switch tracks this project in it."
      panel.prompt = "Link"
    } else {
      panel.message = "Choose an app. Auto-switch tracks this project in it."
      panel.prompt = "Link"
      panel.allowedContentTypes = [.applicationBundle]
      panel.directoryURL = URL(fileURLWithPath: "/Applications")
    }
    guard panel.runModal() == .OK else { return nil }
    return panel.url?.path
  }
}

/// How a link reads: a repo by name, a folder by name, an app by its name.
enum LinkName {
  static func name(_ link: ShiftStore.Link) -> String {
    switch link.provider {
    case "app": return appName(link.externalId)
    case "situ": return "Situ \(link.kind)"
    default: return (link.externalId as NSString).lastPathComponent
    }
  }

  /// The whole of it: `github.com/o/r`, a folder's path, an app's name.
  static func detail(_ link: ShiftStore.Link) -> String {
    switch link.provider {
    case "app": return appName(link.externalId)
    case "situ": return "Situ \(link.kind) \(link.externalId)"
    case "folder": return (link.externalId as NSString).abbreviatingWithTildeInPath
    default: return link.externalId
    }
  }

  static func appName(_ bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
      return bundleID
    }
    return FileManager.default.displayName(atPath: url.path)
      .replacingOccurrences(of: ".app", with: "")
  }
}
