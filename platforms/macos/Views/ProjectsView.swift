import AppKit
import SwiftUI

/// Every project, to rename, recolor, or delete, with how much each has
/// been used.
struct ProjectsView: View {
  @Bindable var model: ProjectsModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HStack(alignment: .firstTextBaseline) {
          Text("Projects")
            .font(.title2.weight(.semibold))
          Spacer()
          Button {
            NewProjectPrompt.run(create: model.create(named:))
          } label: {
            Label("New Project", systemImage: "plus")
          }
        }

        if let error = model.error {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.callout)
        }

        if model.projects.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            Text("No projects yet")
              .font(.headline)
            Text(
              "Projects sort your time by what it's for. Create one here, then pick it on any entry in the timesheet."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.top, 24)
        } else {
          GroupedRows(minRowHeight: 52) {
            ForEach(model.projects) { project in
              ProjectRow(model: model, project: project)
            }
          }
          Text("Deleting a project keeps its time on the timesheet, under No project.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
        }
      }
      .frame(maxWidth: 680)
      .padding(24)
      .frame(maxWidth: .infinity)
    }
    .frame(minWidth: 820, minHeight: 520)
  }
}

struct ProjectRow: View {
  let model: ProjectsModel
  let project: ShiftStore.Project

  @State private var name = ""
  @State private var hovered = false
  @State private var confirmingDelete = false
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
        if client != nil || !workspaces.isEmpty {
          HStack(spacing: 10) {
            if let client { Text(client) }
            if !workspaces.isEmpty {
              Label(workspaces.map(\.name).joined(separator: ", "), systemImage: "folder")
                .labelStyle(.titleAndIcon)
                .help("Workspaces")
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

      Button { confirmingDelete = true } label: {
        Image(systemName: "trash").foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .help("Delete this project")
      .opacity(hovered ? 1 : 0)
      .accessibilityHidden(!hovered)
    }
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .contextMenu {
      Button("Rename") { nameFocused = true }
      Button("Delete…", role: .destructive) { confirmingDelete = true }
    }
    .onAppear { name = project.name }
    .onChange(of: project.name) { _, new in
      if !nameFocused { name = new }
    }
    .onChange(of: nameFocused) { _, focused in
      if !focused { commit() }
    }
    .alert("Delete \u{201C}\(project.name)\u{201D}?", isPresented: $confirmingDelete) {
      Button("Delete Project", role: .destructive) { model.delete(project) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(Self.deleteMessage(usage: usage, workspaces: workspaces))
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
