import SwiftUI

/// What the running timer is for, and a menu to pick a project to track.
struct TrackingSection: View {
  let tracking: TrackingModel

  var body: some View {
    let running = tracking.running
    FormSection("Tracking") {
      if running != nil {
        Button("Stop") { tracking.stop() }
          .buttonStyle(.borderless)
          .font(.subheadline)
          .foregroundStyle(.tint)
          .help("Stop the timer now; the TUI and CLI see it too")
      }
    } content: {
      HStack(spacing: 8) {
        Circle()
          .fill(running == nil ? Color.clear : ProjectColor.color(running?.projectId, in: tracking))
          .overlay(Circle().strokeBorder(.tertiary, lineWidth: running == nil ? 1 : 0))
          .frame(width: 8, height: 8)
        TrackingMenu(tracking: tracking)
        Spacer(minLength: 8)
        if let running {
          TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(ShiftSummary.duration(context.date.timeIntervalSince(running.start)))
              .font(.system(.body, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(.secondary)
          }
          .help("Since \(running.start.formatted(date: .omitted, time: .shortened))")
        }
      }
    }
  }
}

/// The projects to track, with workspaces as submenus.
struct TrackingMenu: View {
  let tracking: TrackingModel

  var body: some View {
    let running = tracking.running
    Menu {
      if running?.projectId == nil && !tracking.projects.isEmpty {
        // Says what picking does, since it differs by state.
        Text(running == nil ? "Start Tracking" : "Assign This Timer To")
      }
      ForEach(tracking.projects) { project in
        let workspaces = tracking.workspaces(of: project.id)
        if workspaces.isEmpty {
          item(project.name, project: project.id, workspace: nil)
        } else {
          Menu(project.name) {
            item(project.name, project: project.id, workspace: nil)
            Divider()
            ForEach(workspaces) { ws in
              item(ws.name, project: project.id, workspace: ws.id)
            }
          }
        }
      }
      if running == nil {
        Divider()
        Button("Start Without a Project") { tracking.choose(project: nil, workspace: nil) }
      }
      Divider()
      Button("New Project…") {
        // Let the menu close first; a modal from inside it doesn't take keys.
        DispatchQueue.main.async {
          if let id = NewProjectPrompt.run(create: tracking.createProject(named:)) {
            tracking.choose(project: id, workspace: nil)
          }
        }
      }
    } label: {
      Text(title(running))
        .lineLimit(1)
    }
    .menuStyle(.borderlessButton)
    .fixedSize(horizontal: false, vertical: true)
    .help(running == nil ? "Start tracking a project" : "Change what this timer is for")
  }

  private func title(_ running: ShiftStore.Entry?) -> String {
    // A menu's label can't be dimmed, so the idle one says what it does.
    guard let running else { return "Start tracking…" }
    return tracking.label(project: running.projectId, workspace: running.workspaceId)
      ?? "No project"
  }

  /// A project or workspace; checked if it's what the timer is for.
  private func item(_ title: String, project: UUID, workspace: UUID?) -> some View {
    let current =
      tracking.running.map { $0.projectId == project && $0.workspaceId == workspace } ?? false
    return Toggle(
      title,
      isOn: Binding(
        get: { current },
        set: { _ in tracking.choose(project: project, workspace: workspace) }))
  }
}
