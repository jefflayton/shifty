import AppKit
import SwiftUI

/// The main window: the week at a glance as a strip of day bars, then its
/// shifts and entries by day, editable in place, with totals by project and
/// client. A project's color carries through all three. Days you don't work
/// stay out of the way unless there's time on them.
struct TimesheetView: View {
  @Bindable var model: TimesheetModel
  /// The week's totals, in the inspector.
  @AppStorage("timesheet.showsTotals") private var showsTotals = true
  /// The rows have the keyboard: arrows move the selection, Delete deletes.
  @FocusState private var rowsFocused: Bool

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      let now = context.date
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            WeekStrip(model: model, now: now) { day in
              withAnimation(.snappy) {
                model.expand(day)
                proxy.scrollTo(day, anchor: .top)
              }
            }
            .padding(.bottom, 6)
            if let error = model.error {
              Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
            }
            ForEach(model.visibleDays, id: \.self) { day in
              DaySection(
                model: model, day: day, now: now, isFocused: rowsFocused,
                focus: { rowsFocused = true }
              )
              .id(day)
            }
          }
          .padding(20)
          // A click on nothing in particular clears the selection.
          .background {
            Color.clear
              .contentShape(Rectangle())
              .onTapGesture {
                model.selection = nil
                rowsFocused = true
              }
          }
        }
        .focusable()
        .focused($rowsFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
          switch direction {
          case .up: model.moveSelection(by: -1, now: now)
          case .down: model.moveSelection(by: 1, now: now)
          default: return
          }
          if let selection = model.selection {
            withAnimation(.snappy) { proxy.scrollTo(selection, anchor: nil) }
          }
        }
        .onDeleteCommand { model.deleteSelection(now: now) }
        .onCopyCommand {
          guard let selection = model.selection, let text = model.text(of: selection, now: now)
          else { return [] }
          return [NSItemProvider(object: text as NSString)]
        }
        .onKeyPress(.return) {
          guard let selection = model.selection else { return .ignored }
          model.editRequest = selection
          return .handled
        }
        .onKeyPress(.escape) {
          guard model.selection != nil else { return .ignored }
          model.selection = nil
          return .handled
        }
      }
      .navigationTitle(WeekTitle.range(model.week))
      .navigationSubtitle("\(TimesheetFormat.duration(model.total(now: now))) tracked")
      .toolbar { toolbar(now: now) }
      .inspector(isPresented: $showsTotals) {
        WeekTotals(model: model, now: now)
          .inspectorColumnWidth(min: 220, ideal: 260, max: 360)
      }
    }
  }

  /// Week paging like Calendar's, the days you work, and the totals.
  @ToolbarContentBuilder private func toolbar(now: Date) -> some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      ControlGroup {
        Button(action: model.previousWeek) {
          Label("Previous Week", systemImage: "chevron.left")
        }
        .keyboardShortcut(.leftArrow, modifiers: .command)
        .help("Previous week (⌘←)")
        Button("Today") { model.showWeek(containing: now) }
        .keyboardShortcut("t", modifiers: .command)
        .help("Go to this week (⌘T)")
        Button(action: model.nextWeek) {
          Label("Next Week", systemImage: "chevron.right")
        }
        .keyboardShortcut(.rightArrow, modifiers: .command)
        .help("Next week (⌘→)")
      }
    }
    ToolbarItem(placement: .primaryAction) {
      AddMenu(model: model, day: addDay(now: now), now: now) { item in
        model.selection = item
        rowsFocused = true
      }
    }
    ToolbarItem(placement: .primaryAction) {
      WorkDaysMenu(model: model)
    }
    ToolbarItem(placement: .primaryAction) {
      Button {
        showsTotals.toggle()
      } label: {
        Label("Totals", systemImage: "sidebar.trailing")
      }
      .keyboardShortcut("i", modifiers: [.command, .option])
      .help(showsTotals ? "Hide the week's totals (⌥⌘I)" : "Show the week's totals (⌥⌘I)")
    }
  }
}

extension TimesheetView {
  /// Where the toolbar's + adds: the selected row's day, else today if
  /// it's this week, else the first day shown.
  fileprivate func addDay(now: Date) -> Date {
    if let selection = model.selection, let day = model.day(of: selection) { return day }
    if model.week.contains(now) { return model.calendar.startOfDay(for: now) }
    return model.visibleDays.first ?? model.week.start
  }
}

enum WeekTitle {
  /// "Oct 26 – Nov 1".
  static func range(_ week: DateInterval) -> String {
    let last = week.end.addingTimeInterval(-1)
    return "\(week.start.formatted(.dateTime.month(.abbreviated).day())) – "
      + last.formatted(.dateTime.month(.abbreviated).day())
  }
}

/// Which days the timesheet shows. A day off with time on it shows anyway.
struct WorkDaysMenu: View {
  let model: TimesheetModel

  var body: some View {
    if let preferences = model.preferences {
      let hidden = model.hiddenDays
      Menu {
        Section("Days You Work") {
          ForEach(model.days, id: \.self) { day in
            let iso = Preferences.isoWeekday(day, calendar: model.calendar)
            Toggle(
              day.formatted(.dateTime.weekday(.wide)),
              isOn: Binding(
                get: { preferences.workDays.contains(iso) },
                set: { on in
                  if on { preferences.workDays.insert(iso) } else { preferences.workDays.remove(iso) }
                }))
          }
        }
      } label: {
        Label(
          hidden.isEmpty
            ? "All Days"
            : "\(hidden.count) Day\(hidden.count == 1 ? "" : "s") Hidden",
          systemImage: hidden.isEmpty ? "calendar" : "calendar.badge.minus")
      }
      .help("Choose the days you work; the others are hidden when they have no time")
    }
  }
}

/// The week at a glance: a bar per day, stacked by project, inside an
/// outline of the time on shift, on a shared scale with a faint line at a
/// full day. Clicking a day jumps to it.
struct WeekStrip: View {
  let model: TimesheetModel
  let now: Date
  let select: (Date) -> Void

  static let barHeight: CGFloat = 72
  /// The scale tops out at a full day unless a day runs longer.
  static let fullDay: TimeInterval = 8 * 60 * 60

  var body: some View {
    let days = model.visibleDays
    let scale = max(
      Self.fullDay,
      days.map { max(model.total(on: $0, now: now), model.worked(on: $0, now: now)) }.max() ?? 0)
    HStack(alignment: .bottom, spacing: 6) {
      ForEach(days, id: \.self) { day in
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
          .frame(width: 36, height: WeekStrip.barHeight + 2, alignment: .bottom)
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

  /// Segments bottom up, biggest project first, in an outline as tall as
  /// the shift; an empty day is a stub.
  @ViewBuilder private func bar(total: TimeInterval) -> some View {
    let worked = model.worked(on: day, now: now)
    if total <= 0 && worked <= 0 {
      Capsule().fill(.quaternary).frame(height: 3)
    } else {
      let rows = model.totalsByProject(on: day, now: now)
      // The shift, a lighter column the projects stack up inside.
      ZStack(alignment: .bottom) {
        if worked > 0 {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(.primary.opacity(0.12))
            .overlay(
              RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(.primary.opacity(0.25), lineWidth: 1)
            )
            .frame(height: max(4, WeekStrip.barHeight * worked / scale))
            .help("\(TimesheetFormat.duration(worked)) on shift")
        }
        VStack(spacing: 1.5) {
          ForEach(Array(rows.reversed().enumerated()), id: \.offset) { _, row in
            Rectangle()
              .fill(ProjectColor.color(row.project, in: model))
              .frame(height: max(2, WeekStrip.barHeight * row.seconds / scale))
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .padding(.horizontal, worked > 0 ? 4 : 0)
      }
    }
  }
}

struct DaySection: View {
  let model: TimesheetModel
  let day: Date
  let now: Date
  /// Whether the timesheet has the keyboard, for the selection's color.
  let isFocused: Bool
  let focus: () -> Void

  @State private var headerHovered = false

  var body: some View {
    let rows = model.rows(on: day)
    let shifts = model.shifts(on: day)
    let empty = rows.isEmpty && shifts.isEmpty
    let collapsed = model.isCollapsed(day)
    let (title, detail) = Self.title(day, now: now)
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        // Room for the chevron either way, so titles line up.
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(collapsed ? 0 : 90))
          .frame(width: 12)
          .opacity(empty ? 0 : 1)
        Text(title)
          .font(.headline)
          .foregroundStyle(empty ? .secondary : .primary)
        Text(detail)
          .foregroundStyle(.secondary)
        if !model.isWorkDay(day) {
          Text("Day off")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quinary, in: Capsule())
        }
        Spacer()
        if empty {
          Text("No time")
            .foregroundStyle(.tertiary)
        } else {
          Text(TimesheetFormat.duration(model.total(on: day, now: now)))
            .font(.system(.body, design: .rounded).weight(.medium))
            .monospacedDigit()
            .help("Tracked to projects")
        }
        // The toolbar's + adds to the selected day; this one, on hover,
        // to any day.
        AddMenu(model: model, day: day, now: now) { item in
          model.selection = item
          focus()
        }
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        .opacity(headerHovered ? 1 : 0)
      }
      .onHover { headerHovered = $0 }
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      // The header folds the day; Option-click folds or opens every day.
      // The + menu keeps its own clicks.
      .contentShape(Rectangle())
      .onTapGesture {
        guard !empty else { return }
        let all = NSEvent.modifierFlags.contains(.option)
        withAnimation(.snappy) { model.toggleCollapsed(day, all: all) }
      }
      .accessibilityElement(children: .contain)
      .accessibilityAddTraits(empty ? [] : .isButton)
      .accessibilityHint(empty ? "" : collapsed ? "Shows the day" : "Hides the day")
      .accessibilityAction {
        if !empty { withAnimation(.snappy) { model.toggleCollapsed(day) } }
      }
      .help(empty ? "" : collapsed ? "Show this day (Option-click: every day)" : "Hide this day (Option-click: every day)")

      if !empty && !collapsed {
        GroupedRows(minRowHeight: 38, rowInset: 4) {
          if !shifts.isEmpty {
            ShiftBlock(
              model: model, day: day, shifts: shifts, now: now, isFocused: isFocused, focus: focus)
          }
          ForEach(rows) { row in
            Group {
              switch row {
              case .entry(let entry):
                EntryRow(model: model, entry: entry, now: now)
              case .brk(let brk, let shift):
                BreakLine(
                  model: model, shift: shift, brk: brk, lunch: model.lunch(of: shift, now: now),
                  now: now)
              }
            }
            .selectableRow(model, row.id, isFocused: isFocused, focus: focus)
            .padding(.vertical, 2)
          }
        }
        .transition(.opacity)
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

/// The "+" on a day: an hour of project time, a shift you forgot to clock
/// in for, or a break on the day's shift.
struct AddMenu: View {
  let model: TimesheetModel
  let day: Date
  let now: Date
  /// Selects what was added.
  let added: (TimesheetModel.Item) -> Void

  var body: some View {
    let name = day.formatted(.dateTime.weekday(.wide))
    Menu {
      Section(name) {
        Button("Add Time") {
          model.expand(day)
          if let id = model.addEntry(on: day, now: now) { added(.entry(id)) }
        }
        Button("Add Shift") {
          model.expand(day)
          if let id = model.addShift(on: day, now: now) { added(.shift(id)) }
        }
        .disabled(model.shiftSlot(on: day, now: now) == nil)
        Button("Add Break") {
          guard let shift = model.shifts(on: day).last else { return }
          model.expand(day)
          if let id = model.addBreak(to: shift, now: now) { added(.brk(id)) }
        }
        .disabled(model.shifts(on: day).isEmpty)
      }
    } label: {
      Label("Add", systemImage: "plus")
    }
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Add time, a shift, or a break on \(name)")
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
          .frame(width: 16)

        HStack(spacing: 4) {
          TimeField(
            "Start", times.start, focusRequested: model.editRequest == .entry(entry.id),
            onFocused: { model.editRequest = nil }, set: { model.setStart(entry, to: $0) })
          Text("–").foregroundStyle(.secondary)
          if let end = times.end {
            TimeField("End", end, set: { model.setEnd(entry, to: $0) })
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
          .frame(width: 140, alignment: .leading)

        // The prompt shows where you're pointing, not on every row.
        TextField(
          "Note", text: $note, prompt: hovered || noteFocused ? Text("Add a note") : Text(""))
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
          .padding(.leading, 26)
      }
    }
    .padding(.vertical, invalid ? 6 : 0)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .contextMenu {
      if running { Button("Stop") { model.stop(entry) } }
      Button("Copy") { copy(model.text(of: .entry(entry.id), now: now)) }
      Divider()
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
          if let id = NewProjectPrompt.run(create: model.createProject(named:)) {
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
        VStack(alignment: .leading, spacing: 0) {
          Text("Tracked")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(TimesheetFormat.duration(total))
            .font(.system(size: 28, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)

        let worked = model.worked(now: now)
        if worked > 0 {
          TotalsList(title: "Shifts") {
            FigureRow(name: "Worked", seconds: worked)
            let over = model.over(now: now)
            if over > 0 {
              FigureRow(name: "Over", seconds: over)
                .help("Time past each shift's length")
            }
            FigureRow(name: "Untracked", seconds: model.untracked(now: now))
              .help("Time on shift with no project entry")
          }
        }

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

/// A name and its time, plain.
struct FigureRow: View {
  let name: String
  let seconds: TimeInterval

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(name)
      Spacer()
      Text(TimesheetFormat.duration(seconds))
        .font(.system(.body, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
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

enum ProjectColor {
  /// For projects without a color of their own, picked by age so a
  /// project keeps its color as others are added. Mid tones that hold up
  /// in light and dark. Also the swatches offered when picking one.
  static let paletteHex = [
    "#4A90E2", "#F08A3C", "#34A770", "#9B6BE0", "#E0598B", "#22A6A6", "#D9A520", "#7D8BA6",
  ]
  static let palette: [Color] = paletteHex.map { parse($0)! }

  /// Unassigned time.
  static let none = Color.secondary.opacity(0.45)

  static func color(_ project: UUID?, in names: some ProjectNames) -> Color {
    guard let project else { return none }
    if let own = names.project(project)?.color.flatMap(parse) { return own }
    guard let rank = names.rank(of: project) else { return none }
    return palette[rank % palette.count]
  }

  /// A `#rrggbb` color.
  static func parse(_ hex: String) -> Color? {
    guard hex.count == 7, hex.hasPrefix("#"), let v = UInt32(hex.dropFirst(), radix: 16)
    else { return nil }
    return Color(
      red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255,
      blue: Double(v & 0xff) / 255)
  }

  /// `color` as `#RRGGBB`, in sRGB.
  static func hex(_ color: Color) -> String? {
    guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
    func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
    return String(
      format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
  }
}

/// Asks for a new project's name and passes it to `create`, which returns
/// the project's id (an existing one if the name is taken).
@MainActor
enum NewProjectPrompt {
  @discardableResult
  static func run(create: (String) -> UUID?) -> UUID? {
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
    return create(field.stringValue)
  }
}
