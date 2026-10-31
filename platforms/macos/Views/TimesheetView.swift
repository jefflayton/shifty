import AppKit
import SwiftUI

/// The main window: a week of entries by day, editable in place, with
/// totals by project and client.
struct TimesheetView: View {
  @Bindable var model: TimesheetModel

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      let now = context.date
      VStack(spacing: 0) {
        WeekHeader(model: model, now: now)
          .padding(.horizontal, 20)
          .padding(.vertical, 12)
        Divider()
        HStack(alignment: .top, spacing: 0) {
          ScrollView {
            VStack(alignment: .leading, spacing: 18) {
              if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                  .foregroundStyle(.red)
                  .font(.callout)
              }
              ForEach(model.days, id: \.self) { day in
                DaySection(model: model, day: day, now: now)
              }
            }
            .padding(20)
          }
          Divider()
          WeekTotals(model: model, now: now)
            .frame(width: 220)
        }
      }
    }
    .frame(minWidth: 760, minHeight: 480)
  }
}

struct WeekHeader: View {
  let model: TimesheetModel
  let now: Date

  var body: some View {
    HStack(spacing: 10) {
      Button(action: model.previousWeek) { Image(systemName: "chevron.left") }
        .help("Previous week")
      Button(action: model.nextWeek) { Image(systemName: "chevron.right") }
        .help("Next week")
      Text(Self.range(model.week))
        .font(.title2.weight(.semibold))
      if !model.week.contains(now) {
        Button("This Week") { model.showWeek(containing: now) }
      }
      Spacer()
      Text(ShiftSummary.duration(model.total(now: now)))
        .font(.title2.weight(.semibold))
        .monospacedDigit()
        .contentTransition(.numericText())
    }
    .buttonStyle(.borderless)
  }

  /// "Oct 26 – Nov 1".
  static func range(_ week: DateInterval) -> String {
    let last = week.end.addingTimeInterval(-1)
    return "\(week.start.formatted(.dateTime.month(.abbreviated).day())) – "
      + last.formatted(.dateTime.month(.abbreviated).day())
  }
}

struct DaySection: View {
  let model: TimesheetModel
  let day: Date
  let now: Date

  var body: some View {
    let entries = model.entries(on: day)
    if entries.isEmpty {
      // An empty day is one line, so a week with a few busy days stays short.
      HStack {
        Text(Self.title(day, now: now))
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Text("No time")
          .font(.subheadline)
          .foregroundStyle(.tertiary)
        AddButton(help: "Add time on this day") { model.addEntry(on: day, now: now) }
      }
      .padding(.horizontal, 6)
    } else {
      section(entries)
    }
  }

  private func section(_ entries: [ShiftStore.Entry]) -> some View {
    FormSection(Self.title(day, now: now)) {
      HStack(spacing: 8) {
        let total = model.total(on: day, now: now)
        if total > 0 {
          Text(ShiftSummary.duration(total))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        AddButton(help: "Add time on this day") { model.addEntry(on: day, now: now) }
      }
    } content: {
      ForEach(entries) { entry in
        EntryRow(model: model, entry: entry, now: now)
      }
    }
  }

  /// "Today", "Yesterday", or "Wednesday, Oct 28".
  static func title(_ day: Date, now: Date, calendar: Calendar = .current) -> String {
    if calendar.isDate(day, inSameDayAs: now) { return "Today" }
    if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) {
      return "Yesterday"
    }
    return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
  }
}

struct EntryRow: View {
  let model: TimesheetModel
  let entry: ShiftStore.Entry
  let now: Date

  @State private var note = ""
  @FocusState private var noteFocused: Bool

  var body: some View {
    let times = model.times(of: entry)
    let invalid = times.end.map { !TimesheetModel.isValid(start: times.start, end: $0) } ?? false

    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        RemoveButton(help: "Delete this time") { model.delete(entry) }

        DatePicker(
          "Start", selection: Binding(get: { times.start }, set: { model.setStart(entry, to: $0) }),
          displayedComponents: .hourAndMinute
        )
        .datePickerStyle(.field)
        .labelsHidden()
        .fixedSize()
        Text("to").foregroundStyle(.secondary)
        if let end = times.end {
          DatePicker(
            "End", selection: Binding(get: { end }, set: { model.setEnd(entry, to: $0) }),
            displayedComponents: .hourAndMinute
          )
          .datePickerStyle(.field)
          .labelsHidden()
          .fixedSize()
        } else {
          HStack(spacing: 4) {
            Circle().fill(.green).frame(width: 7, height: 7)
            Text("now")
          }
          .help("Running")
        }

        Text(ShiftSummary.duration((times.end ?? now).timeIntervalSince(times.start)))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .frame(width: 80, alignment: .trailing)

        ProjectPicker(model: model, entry: entry)
          .frame(width: 170, alignment: .leading)

        TextField("Note", text: $note)
          .textFieldStyle(.plain)
          .focused($noteFocused)
          .onSubmit { model.setNote(entry, to: note) }

        if entry.end == nil {
          Button("Stop") { model.stop(entry) }
            .controlSize(.small)
            .help("Stop this timer now")
        }
      }
      if invalid {
        Text("An entry must end after it starts and last at most 16 hours.")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .padding(.vertical, invalid ? 6 : 0)
    .contextMenu {
      if entry.end == nil { Button("Stop") { model.stop(entry) } }
      Button("Delete", role: .destructive) { model.delete(entry) }
    }
    .onAppear { note = entry.note ?? "" }
    .onChange(of: entry.note) { _, new in
      if !noteFocused { note = new ?? "" }
    }
    .onChange(of: noteFocused) { _, focused in
      if !focused { model.setNote(entry, to: note) }
    }
  }
}

/// Which project, and optionally workspace, an entry is for.
struct ProjectPicker: View {
  let model: TimesheetModel
  let entry: ShiftStore.Entry

  var body: some View {
    HStack(spacing: 6) {
      // Outside the menu: a menu's label drops shapes and colors.
      Circle()
        .fill(ProjectColor.color(entry.projectId.flatMap { model.project($0)?.color }))
        .frame(width: 8, height: 8)
      menu
    }
  }

  private var menu: some View {
    Menu {
      Button("No Project") { model.setProject(entry, project: nil, workspace: nil) }
      if !model.sheet.projects.isEmpty { Divider() }
      ForEach(model.sheet.projects) { project in
        let workspaces = model.workspaces(of: project.id)
        if workspaces.isEmpty {
          Button(project.name) { model.setProject(entry, project: project.id, workspace: nil) }
        } else {
          Menu(project.name) {
            Button(project.name) { model.setProject(entry, project: project.id, workspace: nil) }
            Divider()
            ForEach(workspaces) { ws in
              Button(ws.name) { model.setProject(entry, project: project.id, workspace: ws.id) }
            }
          }
        }
      }
      Divider()
      Button("New Project…") {
        // Let the menu close first; a modal from inside it doesn't take keys.
        DispatchQueue.main.async {
          if let id = NewProjectPrompt.run(model: model) {
            model.setProject(entry, project: id, workspace: nil)
          }
        }
      }
    } label: {
      Text(model.label(project: entry.projectId, workspace: entry.workspaceId) ?? "No project")
        .lineLimit(1)
    }
    .menuStyle(.borderlessButton)
    .fixedSize(horizontal: false, vertical: true)
  }
}

struct WeekTotals: View {
  let model: TimesheetModel
  let now: Date

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        let byProject = model.totalsByProject(now: now)
        FormSection("By project") {
          if byProject.isEmpty {
            Text("No time this week").foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          ForEach(byProject, id: \.project) { row in
            TotalRow(
              color: ProjectColor.color(row.project.flatMap { model.project($0)?.color }),
              name: model.label(project: row.project, workspace: nil) ?? "No project",
              secondary: row.project == nil, seconds: row.seconds)
          }
        }

        let byClient = model.totalsByClient(now: now)
        if byClient.contains(where: { $0.client != nil }) {
          FormSection("By client") {
            ForEach(byClient, id: \.client) { row in
              TotalRow(
                color: nil, name: row.client.flatMap { model.client($0)?.name } ?? "No client",
                secondary: row.client == nil, seconds: row.seconds)
            }
          }
        }
      }
      .padding(16)
    }
  }
}

struct TotalRow: View {
  let color: Color?
  let name: String
  let secondary: Bool
  let seconds: TimeInterval

  var body: some View {
    HStack(spacing: 6) {
      if let color {
        Circle().fill(color).frame(width: 8, height: 8)
      }
      Text(name)
        .foregroundStyle(secondary ? .secondary : .primary)
        .lineLimit(1)
      Spacer()
      Text(ShiftSummary.duration(seconds))
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .fixedSize()
    }
  }
}

enum ProjectColor {
  /// A project's `#rrggbb` color, or a neutral one.
  static func color(_ hex: String?) -> Color {
    guard let hex, hex.count == 7, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16)
    else { return Color.secondary.opacity(0.5) }
    return Color(
      red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255,
      blue: Double(v & 0xff) / 255)
  }
}

/// Asks for a new project's name. Returns its id, or an existing project's
/// if one already has that name.
@MainActor
enum NewProjectPrompt {
  static func run(model: TimesheetModel) -> UUID? {
    let alert = NSAlert()
    alert.messageText = "New Project"
    alert.informativeText = "Time tracked against it shows up in the TUI and CLI too."
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.placeholderString = "Name"
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    return model.createProject(named: field.stringValue)
  }
}
