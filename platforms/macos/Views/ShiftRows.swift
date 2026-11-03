import SwiftUI

/// A day at a glance: the shift on top (work solid, breaks as gaps, the
/// rest of the shift you're on faded), the time tracked to projects beneath
/// it, and the lunch window behind both. Where the two lanes differ is time
/// on shift that no project has.
struct DayTimeline: View {
  let model: TimesheetModel
  let day: Date
  let now: Date

  static let labelWidth: CGFloat = 52
  private typealias Lane = (y: CGFloat, height: CGFloat)
  private static let shiftLane: Lane = (6, 8)
  private static let entryLane: Lane = (20, 10)
  private static let height: CGFloat = 50

  var body: some View {
    let shifts = model.shifts(on: day)
    let entries = model.entries(on: day)
    let lunches = shifts.compactMap { model.lunch(of: $0, now: now) }
    let ends = shifts.map { model.expectedEnd(of: $0, now: now) }
    let range = Self.range(
      shifts: shifts, ends: ends, entries: entries, lunches: lunches, now: now)

    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        Text("Shift").frame(height: 14)
        Text("Tracked").frame(height: 14)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .frame(width: Self.labelWidth, height: Self.height, alignment: .topLeading)
      .padding(.top, Self.shiftLane.y - 3)

      Canvas { context, size in
        draw(
          in: &context, size: size, range: range, shifts: shifts, entries: entries,
          lunches: lunches)
      }
      .frame(height: Self.height)
    }
    .padding(.vertical, 8)
    .accessibilityElement()
    .accessibilityLabel(Self.summary(model: model, shifts: shifts, lunches: lunches, now: now))
  }

  private func draw(
    in context: inout GraphicsContext, size: CGSize, range: DateInterval,
    shifts: [ShiftStore.SheetShift], entries: [ShiftStore.Entry], lunches: [LunchPlan]
  ) {
    let width = size.width
    func x(_ date: Date) -> CGFloat {
      CGFloat(date.timeIntervalSince(range.start) / range.duration) * width
    }
    func bar(_ from: Date, _ to: Date, lane: Lane) -> Path {
      let rect = CGRect(
        x: x(from), y: lane.y, width: max(2, x(to) - x(from)), height: lane.height)
      return Path(roundedRect: rect, cornerRadius: lane.height / 3, style: .continuous)
    }

    // Hours: a hairline each, labeled as often as fits.
    let hours = Int(range.duration / 3600)
    let every = [1, 2, 3, 4, 6].first { width / CGFloat(hours) * CGFloat($0) >= 46 } ?? 6
    for h in 0...hours {
      let t = range.start.addingTimeInterval(TimeInterval(h * 3600))
      let px = x(t)
      context.fill(
        Path(CGRect(x: px - 0.25, y: 0, width: 0.5, height: Self.entryLane.y + Self.entryLane.height + 4)),
        with: .style(.quaternary))
      if h % every == 0 {
        let label = Text(t.formatted(.dateTime.hour()))
          .font(.caption2)
          .foregroundStyle(.secondary)
        context.draw(
          label, at: CGPoint(x: min(max(px, 14), width - 14), y: Self.height),
          anchor: .bottom)
      }
    }

    // The lunch window, behind both lanes.
    for lunch in lunches {
      let rect = CGRect(
        x: x(lunch.opens), y: 1, width: x(lunch.closes) - x(lunch.opens),
        height: Self.entryLane.y + Self.entryLane.height + 2)
      let tint = lunch.status(now: now) == .missed || lunch.status(now: now) == .late
        ? Color.red : LunchStyle.color
      context.fill(
        Path(roundedRect: rect, cornerRadius: 4, style: .continuous),
        with: .color(tint.opacity(0.13)))
      context.fill(
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1.5)),
        with: .color(tint.opacity(0.7)))
    }

    for shift in shifts {
      for (from, to) in model.work(of: shift, now: now) {
        context.fill(bar(from, to, lane: Self.shiftLane), with: .color(.primary.opacity(0.45)))
      }
      if shift.end == nil {
        let end = model.expectedEnd(of: shift, now: now)
        if end > now {
          context.fill(bar(now, end, lane: Self.shiftLane), with: .color(.primary.opacity(0.15)))
        }
      }
      for brk in shift.breaks {
        // A break is the gap in the shift, outlined.
        let path = bar(brk.start, brk.end ?? now, lane: Self.shiftLane)
        context.stroke(path, with: .style(.tertiary), lineWidth: 1)
      }
    }

    for entry in entries {
      context.fill(
        bar(entry.start, entry.end ?? now, lane: Self.entryLane),
        with: .color(ProjectColor.color(entry.projectId, in: model)))
    }

    if range.contains(now) {
      let px = x(now)
      context.fill(
        Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: Self.entryLane.y + Self.entryLane.height + 4)),
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

  static func summary(
    model: TimesheetModel, shifts: [ShiftStore.SheetShift], lunches: [LunchPlan], now: Date
  ) -> String {
    var parts = shifts.map { shift in
      let start = shift.start.formatted(date: .omitted, time: .shortened)
      let end = shift.end?.formatted(date: .omitted, time: .shortened) ?? "now"
      return "Shift \(start) to \(end)"
    }
    parts += lunches.map {
      "Lunch window \($0.opens.formatted(date: .omitted, time: .shortened)) to "
        + $0.closes.formatted(date: .omitted, time: .shortened)
    }
    return parts.isEmpty ? "Tracked time" : parts.joined(separator: ", ")
  }
}

enum LunchStyle {
  /// The lunch window, wherever it's drawn. Warm, and not one of the project
  /// palette's colors.
  static let color = Color(red: 0.93, green: 0.62, blue: 0.16)
}

/// A shift on the timesheet: clock in and out, editable, with what it adds
/// up to.
struct ShiftRow: View {
  let model: TimesheetModel
  let shift: ShiftStore.SheetShift
  let now: Date

  @State private var hovered = false
  @State private var confirmingDelete = false

  var body: some View {
    let times = model.times(of: shift)
    let invalid = times.end.map { !TimesheetModel.isValid(start: times.start, end: $0) } ?? false
    let open = shift.end == nil
    let worked = model.worked(shift, now: now)
    let untracked = model.untracked(shift, now: now)
    let lunch = model.lunch(of: shift, now: now)

    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        Image(systemName: "clock")
          .foregroundStyle(.secondary)
          .frame(width: 16)
          .help("Clock in and out")

        HStack(spacing: 4) {
          TimeField(
            "Clock in", times.start, set: { model.setStart(shift, to: $0) })
          Text("–").foregroundStyle(.secondary)
          if let end = times.end {
            TimeField("Clock out", end, set: { model.setEnd(shift, to: $0) })
          } else {
            RunningLabel()
          }
        }
        .frame(minWidth: 146, alignment: .leading)

        Text(TimesheetFormat.duration(worked))
          .font(.system(.body, design: .rounded).weight(.medium))
          .monospacedDigit()
          .foregroundStyle(invalid ? .red : .primary)
          .frame(width: 62, alignment: .trailing)
          .help("Worked, breaks not counted")

        Text(open ? "On shift" : "Shift")
          .fontWeight(.medium)
          .frame(width: 170, alignment: .leading)

        // Side by side, or stacked when the window is narrow.
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) { details(lunch: lunch, untracked: untracked) }
          VStack(alignment: .leading, spacing: 0) { details(lunch: lunch, untracked: untracked) }
            .font(.caption)
        }
        .lineLimit(1)

        Spacer(minLength: 0)

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
    .padding(.vertical, invalid ? 6 : 0)
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

  @ViewBuilder private func details(lunch: LunchPlan?, untracked: TimeInterval) -> some View {
    if let lunch { LunchStatus(plan: lunch, now: now).fixedSize() }
    if untracked >= 60 {
      Text("\(TimesheetFormat.duration(untracked)) untracked")
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("Time on shift with no project entry")
    }
  }
}

/// A break during a shift. The one that counts as lunch says so.
struct SheetBreakRow: View {
  let model: TimesheetModel
  let shift: ShiftStore.SheetShift
  let brk: ShiftStore.SheetBreak
  let now: Date

  @State private var hovered = false

  var body: some View {
    let times = model.times(of: brk)
    let invalid =
      times.end.map { !TimesheetModel.isValidBreak(start: times.start, end: $0) } ?? false
    let running = brk.end == nil
    let lunch = model.lunch(of: shift, now: now)
    let isLunch = lunch?.lunch?.start == brk.start

    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 10) {
        Image(systemName: isLunch ? "fork.knife" : "cup.and.saucer")
          .foregroundStyle(.secondary)
          .frame(width: 16)

        HStack(spacing: 4) {
          TimeField("Break start", times.start, set: { model.setStart(brk, of: shift, to: $0) })
          Text("–").foregroundStyle(.secondary)
          if let end = times.end {
            TimeField("Break end", end, set: { model.setEnd(brk, of: shift, to: $0) })
          } else {
            RunningLabel()
          }
        }
        .frame(minWidth: 146, alignment: .leading)

        Text(TimesheetFormat.duration((times.end ?? now).timeIntervalSince(times.start)))
          .font(.system(.body, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(invalid ? .red : .secondary)
          .frame(width: 62, alignment: .trailing)

        Text(isLunch ? "Lunch" : "Break")
          .foregroundStyle(.secondary)
          .frame(width: 170, alignment: .leading)

        if isLunch, let lunch, lunch.status(now: now) == .late {
          Label("Started after \(lunch.closes.formatted(date: .omitted, time: .shortened))",
            systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .lineLimit(1)
        }

        Spacer(minLength: 0)

        if running {
          Button("End Break") { model.endBreak(brk, of: shift) }
            .controlSize(.small)
            .help("End the break now")
        }
        Button { model.delete(brk) } label: {
          Image(systemName: "trash").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Delete this break")
        .opacity(hovered ? 1 : 0)
        .accessibilityHidden(!hovered)
      }
      if invalid {
        Text("A break must end after it starts, within 12 hours. This isn't saved yet.")
          .font(.caption)
          .foregroundStyle(.red)
          .padding(.leading, 26)
      }
    }
    .padding(.vertical, invalid ? 6 : 0)
    .contentShape(Rectangle())
    .onHover { hovered = $0 }
    .contextMenu {
      if running { Button("End Break") { model.endBreak(brk, of: shift) } }
      Button("Delete", role: .destructive) { model.delete(brk) }
    }
  }
}

/// Where lunch stands on a shift, when there's something to say.
struct LunchStatus: View {
  let plan: LunchPlan
  let now: Date

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
