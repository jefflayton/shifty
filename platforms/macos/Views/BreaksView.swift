import SwiftUI

/// The main window's Breaks page: the week's breaks by day, with lunch
/// marked and days without one flagged; one-off breaks, like the dentist on
/// Thursday; and the lunch window, scheduled breaks and the break icon. It
/// shares the timesheet's week.
struct BreaksView: View {
  @Bindable var model: TimesheetModel
  @Bindable var oneOffs: OneOffBreaksModel
  @Bindable var preferences: Preferences
  /// The menu bar's shift, for adding a scheduled break to it today.
  let shift: ShiftModel?
  /// The one-off break being added or edited.
  @State private var editing: Editing?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      let now = context.date
      Form {
        if let error = model.error ?? oneOffs.error {
          Section {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
          }
        }
        let days = breakDays
        if days.isEmpty {
          Section {
            Text("No shifts or one-off breaks this week.")
              .foregroundStyle(.secondary)
          } header: {
            Text("This Week")
          }
        }
        ForEach(days, id: \.self) { day in
          BreakDay(
            model: model, oneOffs: oneOffs, preferences: preferences, day: day, now: now)
        }
        OneOffBreaks(oneOffs: oneOffs, preferences: preferences, now: now) { draft, isNew in
          editing = Editing(draft: draft, isNew: isNew)
        }
        BreakSettings(preferences: preferences, shift: shift)
      }
      .formStyle(.grouped)
      .frame(maxWidth: 720)
      .frame(maxWidth: .infinity)
      .navigationTitle("Breaks · \(WeekTitle.range(model.week))")
      .navigationSubtitle(subtitle(now: now))
      .toolbar { toolbar(now: now) }
    }
    .sheet(item: $editing) { editing in
      OneOffBreakEditor(
        oneOffs: oneOffs, draft: editing.draft, isNew: editing.isNew,
        restSymbol: preferences.breakSymbol)
    }
    .onChange(of: model.week) { _, week in oneOffs.reload(week: week) }
  }

  /// Days with a shift or a one-off break.
  private var breakDays: [Date] {
    model.days.filter { !model.shifts(on: $0).isEmpty || !oneOffs.breaks(on: $0).isEmpty }
  }

  private func subtitle(now: Date) -> String {
    let shifts = model.days.flatMap { model.shifts(on: $0) }
    guard !shifts.isEmpty else { return "No shifts" }
    let count = shifts.reduce(0) { $0 + $1.breaks.count }
    var parts = [
      "\(count) \(count == 1 ? "break" : "breaks")",
      TimesheetFormat.duration(model.onBreak(now: now)),
    ]
    let missed = shifts.filter { model.lunch(of: $0, now: now)?.status(now: now) == .missed }.count
    if missed > 0 { parts.append("\(missed) without lunch") }
    return parts.joined(separator: " · ")
  }

  /// Today if the week is this one or past, else the week's first day.
  private func addDay(now: Date) -> Date {
    let today = model.calendar.startOfDay(for: now)
    return model.week.start > today ? model.week.start : today
  }

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
      Button {
        editing = Editing(
          draft: .new(on: addDay(now: now), now: now, calendar: model.calendar), isNew: true)
      } label: {
        Label("Add Break", systemImage: "plus")
      }
      .help("Add a break on one day, like an appointment")
    }
  }

  struct Editing: Identifiable {
    var draft: OneOffBreaksModel.Draft
    var isNew: Bool
    var id: UUID { draft.id }
  }
}

/// One day's breaks: what each was, when, and whether lunch was taken.
private struct BreakDay: View {
  let model: TimesheetModel
  let oneOffs: OneOffBreaksModel
  let preferences: Preferences
  let day: Date
  let now: Date

  var body: some View {
    let shifts = model.shifts(on: day)
    let (title, detail) = DaySection.title(day, now: now)
    Section {
      ForEach(shifts) { shift in rows(of: shift) }
      // One-offs that no shift has: still to come, or a day you didn't work.
      ForEach(waiting(shifts)) { brk in
        BreaksPageRow(
          name: brk.name, symbol: BreakIcon.symbol(brk.icon, or: preferences.breakSymbol),
          start: brk.start, end: brk.end, now: now,
          note: brk.end > now ? "Planned" : "Not on a shift")
      }
    } header: {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(title)
        Text(detail).foregroundStyle(.secondary).fontWeight(.regular)
        Spacer()
        if !shifts.isEmpty {
          Text(TimesheetFormat.duration(shifts.reduce(0) { $0 + model.onBreak($1, now: now) }))
            .monospacedDigit()
            .help("On break")
        }
      }
    }
  }

  /// A shift's breaks, then how lunch went if that's worth saying.
  @ViewBuilder private func rows(of shift: ShiftStore.SheetShift) -> some View {
    let lunch = model.lunch(of: shift, now: now)
    ForEach(shift.breaks) { brk in line(for: brk, lunch: lunch) }
    if let lunch, let note = LunchNote(lunch.status(now: now), plan: lunch) {
      note
    } else if shift.breaks.isEmpty {
      Text("No breaks").foregroundStyle(.secondary)
    }
  }

  private func line(for brk: ShiftStore.SheetBreak, lunch: LunchPlan?) -> BreaksPageRow {
    let t = model.times(of: brk)
    let (name, symbol) = describe(start: t.start, end: t.end, lunch: lunch)
    return BreaksPageRow(name: name, symbol: symbol, start: t.start, end: t.end, now: now)
  }

  /// This day's one-offs that aren't on one of its shifts.
  private func waiting(_ shifts: [ShiftStore.SheetShift]) -> [ShiftStore.OneOffBreak] {
    oneOffs.breaks(on: day).filter { one in
      !shifts.contains { shift in
        shift.breaks.contains { abs(($0.end ?? now).timeIntervalSince(one.end)) < 60 }
      }
    }
  }

  /// What a break was: lunch, a one-off, a scheduled break, or a break.
  private func describe(start: Date, end: Date?, lunch: LunchPlan?) -> (String, String) {
    if let lunch = lunch?.lunch, lunch.start == start { return ("Lunch", BreakIcon.lunch) }
    if let one = oneOffs.match(start: start, end: end) {
      return (one.name, BreakIcon.symbol(one.icon, or: preferences.breakSymbol))
    }
    if let scheduled = preferences.scheduledBreaks.first(where: {
      $0.matches(start: start, end: end, calendar: model.calendar)
    }) {
      let name = scheduled.name.isEmpty ? "Break" : scheduled.name
      return (name, scheduled.symbol(rest: preferences.breakSymbol))
    }
    return ("Break", preferences.breakSymbol)
  }
}

/// A break: its icon and name, its times, and how long it ran.
private struct BreaksPageRow: View {
  let name: String
  let symbol: String
  let start: Date
  let end: Date?
  let now: Date
  var note: String? = nil

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
        .frame(width: 18)
      Text(name)
      if let note {
        Text(note).foregroundStyle(.secondary).font(.callout)
      }
      Spacer()
      Text(times)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      Text(TimesheetFormat.duration(max(0, (end ?? now).timeIntervalSince(start))))
        .monospacedDigit()
        .frame(minWidth: 56, alignment: .trailing)
    }
  }

  private var times: String {
    let s = start.formatted(date: .omitted, time: .shortened)
    let e = end?.formatted(date: .omitted, time: .shortened) ?? "now"
    return "\(s) – \(e)"
  }
}

/// How lunch went on a shift, when it's worth saying: missed, late, or
/// still to take.
private struct LunchNote: View {
  let status: LunchPlan.Status
  let plan: LunchPlan

  init?(_ status: LunchPlan.Status, plan: LunchPlan) {
    if status == .taken || status == .onLunch { return nil }
    self.status = status
    self.plan = plan
  }

  var body: some View {
    let closes = plan.closes.formatted(date: .omitted, time: .shortened)
    switch status {
    case .missed:
      Label("No lunch", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
    case .late:
      Label("Lunch was late", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    case .open:
      Label("Take lunch by \(closes)", systemImage: BreakIcon.lunch)
        .foregroundStyle(.secondary)
    default:
      Label(
        "Lunch from \(plan.opens.formatted(date: .omitted, time: .shortened)) to \(closes)",
        systemImage: BreakIcon.lunch
      )
      .foregroundStyle(.secondary)
    }
  }
}

/// One-off breaks still to come, with Add, Edit and Remove.
private struct OneOffBreaks: View {
  let oneOffs: OneOffBreaksModel
  let preferences: Preferences
  let now: Date
  let edit: (OneOffBreaksModel.Draft, _ isNew: Bool) -> Void

  var body: some View {
    Section {
      ForEach(oneOffs.upcoming(now: now)) { brk in
        HStack(spacing: 8) {
          RemoveButton(help: "Remove this break") { oneOffs.delete(brk.id) }
          Image(systemName: BreakIcon.symbol(brk.icon, or: preferences.breakSymbol))
            .foregroundStyle(.secondary)
            .frame(width: 18)
          Text(brk.name)
          Spacer()
          Text(when(brk))
            .foregroundStyle(.secondary)
            .monospacedDigit()
          Button("Edit") { edit(.init(brk), false) }
        }
      }
      Button("Add One-Off Break") {
        edit(.new(on: now, now: now, calendar: oneOffs.calendar), true)
      }
    } header: {
      Text("One-Off Breaks")
    } footer: {
      Text(
        "A break on one day only, like an appointment. It goes on that day's shift when you clock in, or straight away if you're on it, and pushes clock out later. The TUI and CLI see it too."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// "Thu, Nov 12, 2:00 – 3:00 PM"
  private func when(_ brk: ShiftStore.OneOffBreak) -> String {
    let day = brk.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    let s = brk.start.formatted(date: .omitted, time: .shortened)
    let e = brk.end.formatted(date: .omitted, time: .shortened)
    return "\(day), \(s) – \(e)"
  }
}

/// Adds or edits a one-off break: its day, times, name and icon.
private struct OneOffBreakEditor: View {
  let oneOffs: OneOffBreaksModel
  @State private var draft: OneOffBreaksModel.Draft
  let isNew: Bool
  let restSymbol: String
  @State private var problem: String?
  @Environment(\.dismiss) private var dismiss

  init(
    oneOffs: OneOffBreaksModel, draft: OneOffBreaksModel.Draft, isNew: Bool, restSymbol: String
  ) {
    self.oneOffs = oneOffs
    _draft = State(initialValue: draft)
    self.isNew = isNew
    self.restSymbol = restSymbol
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        TextField("Name", text: $draft.name, prompt: Text("Like Dentist"))
        SymbolPicker("Icon", symbol: $draft.icon, fallback: restSymbol)
        DatePicker("Day", selection: day, displayedComponents: .date)
        DatePicker("Starts", selection: start, displayedComponents: .hourAndMinute)
        DatePicker("Ends", selection: end, displayedComponents: .hourAndMinute)
        if let problem {
          Label(problem, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
        }
      }
      .formStyle(.grouped)
      HStack {
        if !isNew {
          Button("Delete", role: .destructive) {
            oneOffs.delete(draft.id)
            dismiss()
          }
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(isNew ? "Add" : "Save") {
          if oneOffs.save(draft) {
            dismiss()
          } else {
            problem = oneOffs.error
            oneOffs.clearError()
          }
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding(16)
    }
    .frame(width: 400)
  }

  private var calendar: Calendar { oneOffs.calendar }

  /// The day; the times keep their time of day.
  private var day: Binding<Date> {
    Binding(
      get: { draft.start },
      set: { new in
        let length = draft.end.timeIntervalSince(draft.start)
        draft.start = ShiftTimes.on(new, timeOf: draft.start, calendar: calendar)
        draft.end = draft.start.addingTimeInterval(length)
      })
  }

  /// Moving the start keeps the length.
  private var start: Binding<Date> {
    Binding(
      get: { draft.start },
      set: { new in
        let length = draft.end.timeIntervalSince(draft.start)
        draft.start = ShiftTimes.on(draft.start, timeOf: new, calendar: calendar)
        draft.end = draft.start.addingTimeInterval(length)
      })
  }

  /// An end before the start is the next morning's.
  private var end: Binding<Date> {
    Binding(
      get: { draft.end },
      set: { new in
        var end = ShiftTimes.on(draft.start, timeOf: new, calendar: calendar)
        if end <= draft.start { end = calendar.date(byAdding: .day, value: 1, to: end) ?? end }
        draft.end = end
      })
  }
}
