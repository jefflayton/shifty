import AppKit
import SwiftUI

/// The main window: the week at a glance as a strip of day bars, then its
/// entries by day, editable in place, with totals by project and client.
/// A project's color carries through all three.
struct TimesheetView: View {
  @Bindable var model: TimesheetModel

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      let now = context.date
      ScrollViewReader { proxy in
        VStack(spacing: 0) {
          WeekHeader(model: model, now: now)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 12)
          WeekStrip(model: model, now: now) { day in
            withAnimation(.snappy) { proxy.scrollTo(day, anchor: .top) }
          }
          .padding(.horizontal, 24)
          .padding(.bottom, 16)
          Divider()
          HStack(alignment: .top, spacing: 0) {
            ScrollView {
              VStack(alignment: .leading, spacing: 14) {
                if let error = model.error {
                  Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                }
                ForEach(model.days, id: \.self) { day in
                  DaySection(model: model, day: day, now: now)
                    .id(day)
                }
              }
              .padding(20)
            }
            Divider()
            WeekTotals(model: model, now: now)
              .frame(width: 240)
          }
        }
      }
    }
    .frame(minWidth: 820, minHeight: 520)
  }
}

struct WeekHeader: View {
  let model: TimesheetModel
  let now: Date

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(Self.range(model.week))
        .font(.title2.weight(.semibold))
      HStack(spacing: 2) {
        Button(action: model.previousWeek) {
          Image(systemName: "chevron.left").frame(width: 22, height: 22)
        }
        .help("Previous week")
        Button(action: model.nextWeek) {
          Image(systemName: "chevron.right").frame(width: 22, height: 22)
        }
        .help("Next week")
      }
      .buttonStyle(.borderless)
      .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
      if !model.week.contains(now) {
        Button("This Week") { model.showWeek(containing: now) }
          .controlSize(.small)
          .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
      }
      Spacer()
      Text(TimesheetFormat.duration(model.total(now: now)))
        .font(.system(size: 28, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .contentTransition(.numericText())
        .help("Time this week")
    }
  }

  /// "Oct 26 – Nov 1".
  static func range(_ week: DateInterval) -> String {
    let last = week.end.addingTimeInterval(-1)
    return "\(week.start.formatted(.dateTime.month(.abbreviated).day())) – "
      + last.formatted(.dateTime.month(.abbreviated).day())
  }
}

/// The week at a glance: a bar per day, stacked by project, on a shared
/// scale with a faint line at a full day. Clicking a day jumps to it.
struct WeekStrip: View {
  let model: TimesheetModel
  let now: Date
  let select: (Date) -> Void

  static let barHeight: CGFloat = 72
  /// The scale tops out at a full day unless a day runs longer.
  static let fullDay: TimeInterval = 8 * 60 * 60

  var body: some View {
    let scale = max(Self.fullDay, model.days.map { model.total(on: $0, now: now) }.max() ?? 0)
    HStack(alignment: .bottom, spacing: 6) {
      ForEach(model.days, id: \.self) { day in
        DayColumn(model: model, day: day, now: now, scale: scale) { select(day) }
      }
    }
    .background(alignment: .top) {
      // The full-day line, at the height a full day reaches.
      Rectangle()
        .fill(.quaternary)
        .frame(height: 1)
        .padding(.top, 6 + Self.barHeight * (1 - Self.fullDay / scale))
        .allowsHitTesting(false)
    }
  }
}

struct DayColumn: View {
  let model: TimesheetModel
  let day: Date
  let now: Date
  let scale: TimeInterval
  let action: () -> Void

  @State private var hovered = false

  var body: some View {
    let total = model.total(on: day, now: now)
    let isToday = Calendar.current.isDate(day, inSameDayAs: now)
    let isFuture = day > now

    Button(action: action) {
      VStack(spacing: 6) {
        bar(total: total)
          .frame(width: 36, height: WeekStrip.barHeight, alignment: .bottom)
        VStack(spacing: 1) {
          Text(day.formatted(.dateTime.weekday(.abbreviated)))
            .font(.callout.weight(isToday ? .semibold : .regular))
            .foregroundStyle(isToday ? Color.accentColor : isFuture ? .secondary : .primary)
          Text(total > 0 ? TimesheetFormat.duration(total) : " ")
            .font(.system(.caption, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
      }
      .padding(.top, 6)
      .padding(.bottom, 4)
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
      .background(
        hovered ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 }
    .help("Show \(day.formatted(.dateTime.weekday(.wide)))")
    .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day()))
    .accessibilityValue(TimesheetFormat.duration(total))
  }

  /// Segments bottom up, biggest project first; an empty day is a stub.
  @ViewBuilder private func bar(total: TimeInterval) -> some View {
    if total <= 0 {
      Capsule().fill(.quaternary).frame(height: 3)
    } else {
      let rows = model.totalsByProject(on: day, now: now)
      VStack(spacing: 1.5) {
        ForEach(Array(rows.reversed().enumerated()), id: \.offset) { _, row in
          Rectangle()
            .fill(ProjectColor.color(row.project, in: model))
            .frame(height: max(2, WeekStrip.barHeight * row.seconds / scale))
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
  }
}

struct DaySection: View {
  let model: TimesheetModel
  let day: Date
  let now: Date

  var body: some View {
    let entries = model.entries(on: day)
    let (title, detail) = Self.title(day, now: now)
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(title)
          .font(.headline)
          .foregroundStyle(entries.isEmpty ? .secondary : .primary)
        Text(detail)
          .foregroundStyle(.secondary)
        Spacer()
        if entries.isEmpty {
          Text("No time")
            .foregroundStyle(.tertiary)
        } else {
          Text(TimesheetFormat.duration(model.total(on: day, now: now)))
            .font(.system(.body, design: .rounded).weight(.medium))
            .monospacedDigit()
        }
        AddButton(help: "Add an hour on this day") { model.addEntry(on: day, now: now) }
          .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
      }
      .padding(.horizontal, 6)

      if !entries.isEmpty {
        GroupedRows(minRowHeight: 38) {
          ForEach(entries) { entry in
            EntryRow(model: model, entry: entry, now: now)
          }
        }
      }
    }
  }

  /// ("Today", "Friday, Oct 30"), ("Yesterday", …), or ("Wednesday", "Oct 28").
  static func title(_ day: Date, now: Date, calendar: Calendar = .current) -> (String, String) {
    let full = day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    if calendar.isDate(day, inSameDayAs: now) { return ("Today", full) }
    if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: y) {
      return ("Yesterday", full)
    }
    return (
      day.formatted(.dateTime.weekday(.wide)), day.formatted(.dateTime.month(.abbreviated).day())
    )
  }
}

struct EntryRow: View {
  let model: TimesheetModel
  let entry: ShiftStore.Entry
  let now: Date

  @State private var note = ""
  @State private var hovered = false
  @FocusState private var noteFocused: Bool

  var body: some View {
    let times = model.times(of: entry)
    let invalid = times.end.map { !TimesheetModel.isValid(start: times.start, end: $0) } ?? false
    let running = entry.end == nil

    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        Capsule()
          .fill(ProjectColor.color(entry.projectId, in: model))
          .frame(width: 4, height: 22)

        HStack(spacing: 4) {
          DatePicker(
            "Start", selection: Binding(get: { times.start }, set: { model.setStart(entry, to: $0) }),
            displayedComponents: .hourAndMinute
          )
          .datePickerStyle(.field)
          .labelsHidden()
          .fixedSize()
          Text("–").foregroundStyle(.secondary)
          if let end = times.end {
            DatePicker(
              "End", selection: Binding(get: { end }, set: { model.setEnd(entry, to: $0) }),
              displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.field)
            .labelsHidden()
            .fixedSize()
          } else {
            RunningLabel()
          }
        }
        // A running entry's "now" is narrower than a time; keep the columns.
        .frame(minWidth: 146, alignment: .leading)

        Text(TimesheetFormat.duration((times.end ?? now).timeIntervalSince(times.start)))
          .font(.system(.body, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(invalid ? .red : running ? .primary : .secondary)
          .frame(width: 62, alignment: .trailing)

        ProjectPicker(model: model, entry: entry)
          .frame(width: 170, alignment: .leading)

        TextField("Add a note", text: $note)
          .textFieldStyle(.plain)
          .focused($noteFocused)
          .onSubmit { model.setNote(entry, to: note) }

        if running {
          Button { model.stop(entry) } label: {
            Label("Stop", systemImage: "stop.fill")
          }
          .controlSize(.small)
          .help("Stop this timer now")
        }

        Button { model.delete(entry) } label: {
          Image(systemName: "trash")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Delete this time")
        .opacity(hovered ? 1 : 0)
        .accessibilityHidden(!hovered)
      }
      if invalid {
        Text("Times must be in order and at most 16 hours apart. This isn't saved yet.")
          .font(.caption)
          .foregroundStyle(.red)
          .padding(.leading, 14)
      }
    }
    .padding(.vertical, invalid ? 6 : 0)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .contextMenu {
      if running { Button("Stop") { model.stop(entry) } }
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

/// "now", with a dot that breathes while the timer runs.
struct RunningLabel: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dim = false

  var body: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(.green)
        .frame(width: 7, height: 7)
        .opacity(dim ? 0.35 : 1)
      Text("now")
    }
    .help("Running")
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 1.2).repeatForever()) { dim = true }
    }
  }
}

/// Which project, and optionally workspace, an entry is for.
struct ProjectPicker: View {
  let model: TimesheetModel
  let entry: ShiftStore.Entry

  var body: some View {
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
        .foregroundStyle(entry.projectId == nil ? .secondary : .primary)
    }
    .menuStyle(.borderlessButton)
    .fixedSize(horizontal: false, vertical: true)
  }
}

/// The sidebar: where the week's time went.
struct WeekTotals: View {
  let model: TimesheetModel
  let now: Date

  var body: some View {
    let total = model.total(now: now)
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        let byProject = model.totalsByProject(now: now)
        TotalsList(title: "Projects") {
          if byProject.isEmpty {
            Text("Time you add shows up here by project.")
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          ForEach(byProject, id: \.project) { row in
            TotalRow(
              color: ProjectColor.color(row.project, in: model),
              name: model.label(project: row.project, workspace: nil) ?? "No project",
              secondary: row.project == nil, seconds: row.seconds, of: total)
          }
        }

        let byClient = model.totalsByClient(now: now)
        if byClient.contains(where: { $0.client != nil }) {
          TotalsList(title: "Clients") {
            ForEach(byClient, id: \.client) { row in
              TotalRow(
                color: .secondary, name: row.client.flatMap { model.client($0)?.name } ?? "No client",
                secondary: row.client == nil, seconds: row.seconds, of: total)
            }
          }
        }
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 20)
    }
  }
}

struct TotalsList<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
      content
    }
  }
}

/// A name and its time, over a bar showing its share of the week.
struct TotalRow: View {
  let color: Color
  let name: String
  let secondary: Bool
  let seconds: TimeInterval
  let total: TimeInterval

  init(color: Color, name: String, secondary: Bool, seconds: TimeInterval, of total: TimeInterval) {
    self.color = color
    self.name = name
    self.secondary = secondary
    self.seconds = seconds
    self.total = total
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Text(name)
          .foregroundStyle(secondary ? .secondary : .primary)
          .lineLimit(1)
        Spacer()
        Text(TimesheetFormat.duration(seconds))
          .font(.system(.body, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .fixedSize()
      }
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(.quinary)
          Capsule()
            .fill(color)
            .frame(width: max(4, geo.size.width * CGFloat(total > 0 ? seconds / total : 0)))
        }
      }
      .frame(height: 4)
    }
    .accessibilityElement(children: .combine)
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

enum ProjectColor {
  /// For projects without a color of their own, picked by age so a
  /// project keeps its color as others are added. Mid tones that hold up
  /// in light and dark.
  static let palette: [Color] = ([
    0x4A90E2, 0xF08A3C, 0x34A770, 0x9B6BE0, 0xE0598B, 0x22A6A6, 0xD9A520, 0x7D8BA6,
  ] as [UInt32]).map(rgb)

  /// Unassigned time.
  static let none = Color.secondary.opacity(0.45)

  static func color(_ project: UUID?, in model: TimesheetModel) -> Color {
    guard let project else { return none }
    if let own = model.project(project)?.color.flatMap(parse) { return own }
    guard let rank = model.rank(of: project) else { return none }
    return palette[rank % palette.count]
  }

  /// A `#rrggbb` color.
  static func parse(_ hex: String) -> Color? {
    guard hex.count == 7, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16)
    else { return nil }
    return rgb(v)
  }

  private static func rgb(_ v: UInt32) -> Color {
    Color(
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
