import SwiftUI

/// A day's shifts: clock in and out with their breaks on one line each,
/// over a timeline where project time sits on the shift, so time on shift
/// that no project has shows as bare shift.
struct ShiftBlock: View {
  let model: TimesheetModel
  let day: Date
  let shifts: [ShiftStore.SheetShift]
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(shifts) { shift in
        ShiftLine(model: model, shift: shift, now: now)
      }
      DayTimeline(model: model, day: day, now: now)
        .padding(.leading, 26)
    }
    .padding(.vertical, 8)
  }
}

/// One shift: clock in and out (editable), time worked, its breaks, and
/// what's worth knowing about it.
struct ShiftLine: View {
  let model: TimesheetModel
  let shift: ShiftStore.SheetShift
  let now: Date

  @State private var hovered = false
  @State private var confirmingDelete = false

  var body: some View {
    let times = model.times(of: shift)
    let invalid = times.end.map { !TimesheetModel.isValid(start: times.start, end: $0) } ?? false
    let open = shift.end == nil
    let lunch = model.lunch(of: shift, now: now)

    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        Image(systemName: "clock")
          .foregroundStyle(.secondary)
          .frame(width: 16)
          .help("Clock in and out")

        HStack(spacing: 4) {
          TimeField("Clock in", times.start, set: { model.setStart(shift, to: $0) })
          Text("–").foregroundStyle(.secondary)
          if let end = times.end {
            TimeField("Clock out", end, set: { model.setEnd(shift, to: $0) })
          } else {
            RunningLabel()
          }
        }
        .frame(minWidth: 146, alignment: .leading)

        Text(TimesheetFormat.duration(model.worked(shift, now: now)))
          .font(.system(.body, design: .rounded).weight(.medium))
          .monospacedDigit()
          .foregroundStyle(invalid ? .red : .primary)
          .frame(width: 62, alignment: .trailing)
          .help("Worked, breaks not counted")

        let over = model.over(shift, now: now)
        if over > 0 {
          Text("+" + TimesheetFormat.duration(over))
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(OverStyle.color)
            .help("Past the shift's \(TimesheetFormat.duration(shift.length))")
        }

        HStack(spacing: 6) {
          ForEach(shift.breaks) { brk in
            BreakChip(
              model: model, shift: shift, brk: brk, lunch: lunch,
              now: now)
          }
        }

        Spacer(minLength: 8)

        ShiftNote(model: model, shift: shift, lunch: lunch, now: now)

        if open {
          Button("Clock Out") { model.clockOut() }
            .controlSize(.small)
            .help("End the shift now")
        }
        Button { confirmingDelete = true } label: {
          Image(systemName: "trash").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Delete this shift")
        .opacity(hovered ? 1 : 0)
        .accessibilityHidden(!hovered)
      }
      if invalid {
        Text("Clock out must come after clock in, within 16 hours. This isn't saved yet.")
          .font(.caption)
          .foregroundStyle(.red)
          .padding(.leading, 26)
      }
    }
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .contextMenu {
      if open { Button("Clock Out") { model.clockOut() } }
      Button("Add Break") { model.addBreak(to: shift) }
      Divider()
      Button("Delete Shift…", role: .destructive) { confirmingDelete = true }
    }
    .alert("Delete this shift?", isPresented: $confirmingDelete) {
      Button("Delete Shift", role: .destructive) { model.delete(shift) }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        open
          ? "You'll be clocked out, and the shift and its breaks are removed. Time tracked to projects stays."
          : "The shift and its breaks are removed. Time tracked to projects stays.")
    }
  }
}

/// The one thing to say about a shift, most pressing first: lunch, then
/// time no project has.
struct ShiftNote: View {
  let model: TimesheetModel
  let shift: ShiftStore.SheetShift
  let lunch: LunchPlan?
  let now: Date

  var body: some View {
    let untracked = model.untracked(shift, now: now)
    Group {
      if let lunch, LunchStatus.hasNote(lunch, now: now) {
        LunchStatus(plan: lunch, now: now)
      } else if untracked >= 60 {
        Text("\(TimesheetFormat.duration(untracked)) untracked")
          .foregroundStyle(.secondary)
          .help("Time on shift with no project entry")
      }
    }
    .lineLimit(1)
    .fixedSize()
  }
}

/// A break on the shift line: its times, or "Lunch" for the one that was.
/// Click to change or remove it.
struct BreakChip: View {
  let model: TimesheetModel
  let shift: ShiftStore.SheetShift
  let brk: ShiftStore.SheetBreak
  let lunch: LunchPlan?
  let now: Date

  @State private var editing = false

  var body: some View {
    let times = model.times(of: brk)
    let isLunch = lunch?.lunch?.start == brk.start
    let late = isLunch && lunch?.status(now: now) == .late
    let span =
      times.end.map { (times.start..<max($0, times.start)).formatted(.interval.hour().minute()) }
      ?? "since \(times.start.formatted(date: .omitted, time: .shortened))"

    Button { editing = true } label: {
      Label(span, systemImage: isLunch ? "fork.knife" : "cup.and.saucer")
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .foregroundStyle(late ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .background(.quinary, in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .fixedSize()
    .help(
      late
        ? "Lunch started after \(lunch!.closes.formatted(date: .omitted, time: .shortened))"
        : isLunch ? "Lunch" : "Break")
    .popover(isPresented: $editing, arrowEdge: .bottom) {
      BreakEditor(model: model, shift: shift, brk: brk, now: now) { editing = false }
    }
  }
}

/// Changes or removes a break.
struct BreakEditor: View {
  let model: TimesheetModel
  let shift: ShiftStore.SheetShift
  let brk: ShiftStore.SheetBreak
  let now: Date
  let done: () -> Void

  var body: some View {
    // The latest copy: the chip that opened this may hold an older one.
    let brk = model.sheet.shifts.first { $0.id == shift.id }?.breaks.first { $0.id == self.brk.id }
      ?? self.brk
    let times = model.times(of: brk)
    let invalid =
      times.end.map { !TimesheetModel.isValidBreak(start: times.start, end: $0) } ?? false

    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 4) {
        TimeField("Break start", times.start, set: { model.setStart(brk, of: shift, to: $0) })
        Text("–").foregroundStyle(.secondary)
        if let end = times.end {
          TimeField("Break end", end, set: { model.setEnd(brk, of: shift, to: $0) })
        } else {
          RunningLabel()
        }
        Text(TimesheetFormat.duration((times.end ?? now).timeIntervalSince(times.start)))
          .monospacedDigit()
          .foregroundStyle(invalid ? .red : .secondary)
          .padding(.leading, 6)
      }
      if invalid {
        Text("A break must end after it starts, within 12 hours.")
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack {
        Button("Delete Break", role: .destructive) {
          done()
          model.delete(brk)
        }
        Spacer()
        if brk.end == nil {
          Button("End Break") {
            done()
            model.endBreak(brk, of: shift)
          }
          .keyboardShortcut(.defaultAction)
        }
      }
      .controlSize(.small)
    }
    .padding(12)
    .fixedSize()
  }
}

/// A day at a glance, in one lane: the shift as a band (breaks as gaps, the
/// rest of the shift you're on faded), project time on top of it, and the
/// lunch window marked above. Bare band is time on shift no project has.
struct DayTimeline: View {
  let model: TimesheetModel
  let day: Date
  let now: Date

  private static let lane: (y: CGFloat, height: CGFloat) = (5, 12)
  private static let height: CGFloat = 32

  var body: some View {
    let shifts = model.shifts(on: day)
    let entries = model.entries(on: day)
    let lunches = shifts.compactMap { model.lunch(of: $0, now: now) }
    let ends = shifts.map { model.expectedEnd(of: $0, now: now) }
    let range = Self.range(
      shifts: shifts, ends: ends, entries: entries, lunches: lunches, now: now)

    Canvas { context, size in
      draw(
        in: &context, size: size, range: range, shifts: shifts, entries: entries,
        lunches: lunches)
    }
    .frame(height: Self.height)
    .accessibilityElement()
    .accessibilityLabel(Self.summary(shifts: shifts, lunches: lunches))
  }

  private func draw(
    in context: inout GraphicsContext, size: CGSize, range: DateInterval,
    shifts: [ShiftStore.SheetShift], entries: [ShiftStore.Entry], lunches: [LunchPlan]
  ) {
    let width = size.width
    let lane = Self.lane
    func x(_ date: Date) -> CGFloat {
      CGFloat(date.timeIntervalSince(range.start) / range.duration) * width
    }
    func bar(_ from: Date, _ to: Date, inset: CGFloat = 0) -> Path {
      let rect = CGRect(
        x: x(from), y: lane.y + inset, width: max(2, x(to) - x(from)),
        height: lane.height - inset * 2)
      return Path(roundedRect: rect, cornerRadius: (lane.height - inset * 2) / 3, style: .continuous)
    }

    // Hour labels, as often as fits.
    let hours = Int(range.duration / 3600)
    let every = [1, 2, 3, 4, 6].first { width / CGFloat(hours) * CGFloat($0) >= 52 } ?? 6
    for h in stride(from: 0, through: hours, by: every) {
      let t = range.start.addingTimeInterval(TimeInterval(h * 3600))
      let label = Text(t.formatted(.dateTime.hour())).font(.caption2).foregroundStyle(.tertiary)
      context.draw(
        label, at: CGPoint(x: min(max(x(t), 14), width - 14), y: Self.height), anchor: .bottom)
    }

    // The lunch window: a mark above the lane.
    for lunch in lunches {
      let status = lunch.status(now: now)
      let tint = status == .missed || status == .late ? Color.red : LunchStyle.color
      let rect = CGRect(x: x(lunch.opens), y: 0, width: x(lunch.closes) - x(lunch.opens), height: 2.5)
      context.fill(Path(roundedRect: rect, cornerRadius: 1.25), with: .color(tint.opacity(0.8)))
    }

    // The shift: work as a band, the rest of the shift you're on fainter.
    for shift in shifts {
      for (from, to) in model.work(of: shift, now: now) {
        context.fill(bar(from, to), with: .style(.quaternary))
      }
      if shift.end == nil {
        let end = model.expectedEnd(of: shift, now: now)
        if end > now {
          context.stroke(
            bar(now, end), with: .style(.quaternary),
            style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
      }
    }

    // Project time, on the band.
    for entry in entries {
      context.fill(
        bar(entry.start, entry.end ?? now, inset: 2),
        with: .color(ProjectColor.color(entry.projectId, in: model)))
    }

    if range.contains(now) {
      context.fill(
        Path(CGRect(x: x(now) - 0.75, y: lane.y - 3, width: 1.5, height: lane.height + 6)),
        with: .color(.red))
    }
  }

  /// Whole hours around everything on the day, at least four of them.
  static func range(
    shifts: [ShiftStore.SheetShift], ends shiftEnds: [Date], entries: [ShiftStore.Entry],
    lunches: [LunchPlan], now: Date, calendar: Calendar = .current
  ) -> DateInterval {
    let starts = shifts.map(\.start) + entries.map(\.start) + lunches.map(\.opens)
    let ends = shiftEnds + entries.map { $0.end ?? now } + lunches.map(\.closes)
    let first = starts.min() ?? now
    let last = max(ends.max() ?? now, first)
    let start = calendar.dateInterval(of: .hour, for: first)?.start ?? first
    var end = calendar.dateInterval(of: .hour, for: last)?.end ?? last
    if last == calendar.dateInterval(of: .hour, for: last)?.start { end = last }
    end = max(end, start.addingTimeInterval(4 * 3600))
    return DateInterval(start: start, end: end)
  }

  static func summary(shifts: [ShiftStore.SheetShift], lunches: [LunchPlan]) -> String {
    var parts = shifts.map { shift in
      let start = shift.start.formatted(date: .omitted, time: .shortened)
      let end = shift.end?.formatted(date: .omitted, time: .shortened) ?? "now"
      return "Shift \(start) to \(end)"
    }
    parts += lunches.map {
      "Lunch window \($0.opens.formatted(date: .omitted, time: .shortened)) to "
        + $0.closes.formatted(date: .omitted, time: .shortened)
    }
    return parts.joined(separator: ", ")
  }
}

enum LunchStyle {
  /// The lunch window, wherever it's drawn. Warm, and not one of the project
  /// palette's colors.
  static let color = Color(red: 0.93, green: 0.62, blue: 0.16)
}

/// Where lunch stands on a shift, when there's something to say.
struct LunchStatus: View {
  let plan: LunchPlan
  let now: Date

  static func hasNote(_ plan: LunchPlan, now: Date) -> Bool {
    [.upcoming, .open, .missed].contains(plan.status(now: now))
  }

  var body: some View {
    let closes = plan.closes.formatted(date: .omitted, time: .shortened)
    switch plan.status(now: now) {
    case .upcoming:
      Label(
        "Lunch \((plan.opens..<plan.closes).formatted(.interval.hour().minute()))",
        systemImage: "fork.knife"
      )
      .foregroundStyle(.secondary)
    case .open:
      Label("Lunch by \(closes)", systemImage: "fork.knife")
        .foregroundStyle(LunchStyle.color)
    case .missed:
      Label("No lunch by \(closes)", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
    case .onLunch, .taken, .late:
      EmptyView()
    }
  }
}

/// An hour-and-minute field for a time that's saved as it's changed.
struct TimeField: View {
  let label: String
  let value: Date
  let set: (Date) -> Void

  init(_ label: String, _ value: Date, set: @escaping (Date) -> Void) {
    self.label = label
    self.value = value
    self.set = set
  }

  var body: some View {
    DatePicker(label, selection: Binding(get: { value }, set: set), displayedComponents: .hourAndMinute)
      .datePickerStyle(.field)
      .labelsHidden()
      .fixedSize()
  }
}
