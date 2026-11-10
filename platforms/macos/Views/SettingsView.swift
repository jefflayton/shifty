import SwiftUI

/// The Settings window's tabs.
enum SettingsTab: CaseIterable {
  case general, breaks, autoSwitch, clockLinks

  var title: String {
    switch self {
    case .general: "General"
    case .breaks: "Breaks"
    case .autoSwitch: "Auto-Switch"
    case .clockLinks: "Clock Links"
    }
  }

  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .breaks: "cup.and.saucer"
    case .autoSwitch: "arrow.triangle.swap"
    case .clockLinks: "link"
    }
  }
}

/// One tab of the Settings window: the days you work, the menu bar and
/// alarms; breaks (the lunch window and scheduled ones); or the clock links.
struct SettingsPane: View {
  let tab: SettingsTab
  @Bindable var preferences: Preferences
  let loginItem: LoginItem
  /// The menu bar's shift, for adding a scheduled break to it today.
  var shift: ShiftModel? = nil
  @State private var tool = CommandLineTool.status

  var body: some View {
    Form {
      switch tab {
      case .general: general
      case .breaks: breaks
      case .autoSwitch: AutoSwitchSettings(preferences: preferences)
      case .clockLinks: clockLinks
      }
    }
    .formStyle(.grouped)
    .scrollDisabled(tab != .breaks)
    .frame(width: 520)
    // Breaks grow with each scheduled one, so that tab scrolls; the others
    // are as tall as what's in them.
    .frame(height: tab == .breaks ? 560 : nil)
    .fixedSize(horizontal: false, vertical: tab != .breaks)
    // While the window resizes to another tab, stay at its top.
    .frame(maxHeight: .infinity, alignment: .top)
  }

  @ViewBuilder private var general: some View {
    Section {
      WeekdayPicker(days: $preferences.workDays)
    } header: {
      Text("Days You Work")
    } footer: {
      Text("The timesheet hides other days unless they have time on them.")
        .foregroundStyle(.secondary)
    }

    Section {
      CommandLineToolRow(status: $tool)
    } header: {
      Text("Command Line")
    } footer: {
      Text(
        "Track time, link repos, and see your day from a terminal, with the same data as the menu bar. Installing links the command in \(CommandLineTool.directory) to the one inside Shifty, so updates keep it current."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }

    Section("Menu Bar") {
      Picker("Menu bar shows", selection: $preferences.menuBarDisplay) {
        ForEach(MenuBarDisplay.allCases) { Text($0.label).tag($0) }
      }
      Toggle(
        "Open at login",
        isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
    }

    Section {
      DurationStepper(
        "Snooze for", value: $preferences.snoozeLength, in: Preferences.snoozeRange,
        step: 60)
    } header: {
      Text("Alarms")
    } footer: {
      Text("How long an alarm's Snooze button waits before it rings again. Add alarms from the menu bar.")
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var breaks: some View {
    Section {
      Toggle("Lunch window", isOn: $preferences.lunch.isEnabled)
      if preferences.lunch.isEnabled {
        LunchSettings(rule: $preferences.lunch)
      }
    } header: {
      Text("Lunch")
    } footer: {
      Text(
        "Counted in time worked. In California, for example, a 30-minute meal break has to start before the end of the fifth hour of work. Add lunch alarms from the menu bar."
      )
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }

    if preferences.hasStore {
      Section {
        ForEach($preferences.scheduledBreaks) { $brk in
          ScheduledBreakEditor(
            brk: $brk,
            // A break made today otherwise waits for tomorrow's shift.
            addToday: shift.flatMap { shift in
              shift.todayBreak(for: brk, now: Date()) == nil
                ? nil : { shift.addToday(brk) }
            }
          ) {
            let id = brk.id
            preferences.scheduledBreaks.removeAll { $0.id == id }
          }
        }
        Button("Add Scheduled Break") {
          preferences.scheduledBreaks.append(ScheduledBreak(name: ""))
        }
      } header: {
        Text("Scheduled Breaks")
      } footer: {
        Text(
          "Breaks at set times on set days, like a class. Each goes on your shift when a new day's shift starts, and pushes clock out later; Add to Today puts a new one on today's. Move or delete one for the day in the menu bar or on the timesheet. Add break alarms from the menu bar."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder private var clockLinks: some View {
    Section {
      LabeledContent(preferences.separateClockInLink == nil ? "Clock link" : "Clock-out link") {
        LinkValue(link: preferences.clockOutLink) {
          ClockLinkPrompt.run(.clockOut, preferences: preferences)
        }
      }
      Toggle(
        "Separate clock-in link",
        isOn: Binding(
          get: { preferences.separateClockInLink != nil },
          set: { on in
            if on {
              ClockLinkPrompt.run(.clockIn, preferences: preferences)
            } else {
              preferences.separateClockInLink = nil
            }
          }))
      if preferences.separateClockInLink != nil {
        LabeledContent("Clock-in link") {
          LinkValue(link: preferences.separateClockInLink) {
            ClockLinkPrompt.run(.clockIn, preferences: preferences)
          }
        }
      }
      Picker("Open link when clocking in or out", selection: $preferences.clockLinkMode) {
        ForEach(ClockLinkMode.allCases) { Text($0.label).tag($0) }
      }
      .disabled(preferences.clockOutLink == nil && preferences.separateClockInLink == nil)
    } footer: {
      Text(
        "A page to open when you clock in or out from the menu bar, like your timeclock. An alarm's Clock Out button opens it too."
      )
      .foregroundStyle(.secondary)
    }
  }
}

/// The lunch window's bounds and what counts as lunch. Reminders are alarms,
/// set in the menu bar.
struct LunchSettings: View {
  @Binding var rule: LunchRule

  private static let quarter: TimeInterval = 15 * 60

  var body: some View {
    DurationStepper(
      "Opens after", value: $rule.earliest, in: 0...(rule.latest - Self.quarter),
      step: Self.quarter, suffix: "of work")
    DurationStepper(
      "Closes after", value: $rule.latest, in: (rule.earliest + Self.quarter)...(12 * 3600),
      step: Self.quarter, suffix: "of work")
    DurationStepper(
      "Lunch is a break of at least", value: $rule.minimum, in: (5 * 60)...(2 * 3600),
      step: 5 * 60)
  }
}

/// One scheduled break: its name, days, and times.
struct ScheduledBreakEditor: View {
  @Binding var brk: ScheduledBreak
  /// Puts it on today's shift; nil when it doesn't fit there.
  var addToday: (() -> Void)? = nil
  let onRemove: () -> Void
  var calendar: Calendar = .current

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        RemoveButton(help: "Remove this break", action: onRemove)
        TextField("Name", text: $brk.name, prompt: Text("Name, like Class"))
          .labelsHidden()
          .textFieldStyle(.plain)
          .font(.body.weight(.medium))
        Spacer()
        Toggle("On", isOn: $brk.isEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
      }
      Group {
        WeekdayPicker(days: $brk.weekdays, calendar: calendar)
        HStack(spacing: 6) {
          // Hidden labels: in a Form, a control's label joins the form's
          // label column.
          DatePicker("Starts", selection: time(\.start), displayedComponents: .hourAndMinute)
            .datePickerStyle(.field)
            .labelsHidden()
            .fixedSize()
          Text("to").foregroundStyle(.secondary)
          DatePicker("Ends", selection: time(\.end), displayedComponents: .hourAndMinute)
            .datePickerStyle(.field)
            .labelsHidden()
            .fixedSize()
          Spacer()
          if !brk.isValid {
            Label("Ends before it starts", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
              .font(.callout)
          } else if brk.weekdays.isEmpty {
            Text("No days").foregroundStyle(.secondary).font(.callout)
          } else if let addToday {
            Button("Add to Today", action: addToday)
              .help("Put this break on today's shift too; otherwise it starts with the next one")
          }
        }
      }
      .opacity(brk.isEnabled ? 1 : 0.5)
    }
    .padding(.vertical, 4)
  }

  /// A time of day as today's date, for the picker.
  private func time(_ key: WritableKeyPath<ScheduledBreak, TimeInterval>) -> Binding<Date> {
    let day = calendar.startOfDay(for: Date())
    return Binding(
      get: { day.addingTimeInterval(brk[keyPath: key]) },
      set: { date in
        let c = calendar.dateComponents([.hour, .minute], from: date)
        brk[keyPath: key] = TimeInterval((c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60)
      })
  }
}

/// A length of time, stepped.
struct DurationStepper: View {
  let label: String
  @Binding var value: TimeInterval
  let range: ClosedRange<TimeInterval>
  let step: TimeInterval
  var suffix: String? = nil

  init(
    _ label: String, value: Binding<TimeInterval>, in range: ClosedRange<TimeInterval>,
    step: TimeInterval, suffix: String? = nil
  ) {
    self.label = label
    _value = value
    self.range = range
    self.step = step
    self.suffix = suffix
  }

  var body: some View {
    LabeledContent(label) {
      HStack(spacing: 6) {
        Text(TimesheetFormat.duration(value))
          .monospacedDigit()
        if let suffix { Text(suffix).foregroundStyle(.secondary) }
        Stepper(label, value: $value, in: range, step: step)
          .labelsHidden()
      }
    }
  }
}

/// A row of day buttons, in the order of the calendar's week.
struct WeekdayPicker: View {
  @Binding var days: Set<Int>
  var calendar: Calendar = .current

  var body: some View {
    HStack(spacing: 6) {
      ForEach(Preferences.weekOrder(calendar), id: \.self) { iso in
        let on = days.contains(iso)
        Button {
          if on { days.remove(iso) } else { days.insert(iso) }
        } label: {
          Text(Self.symbol(iso, calendar: calendar, style: \.shortWeekdaySymbols))
            .font(.callout.weight(on ? .semibold : .regular))
            .frame(maxWidth: .infinity, minHeight: 28)
            .foregroundStyle(on ? Color.white : .primary)
            .background(
              on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quinary),
              in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.symbol(iso, calendar: calendar, style: \.weekdaySymbols))
        .accessibilityAddTraits(on ? .isSelected : [])
      }
    }
  }

  static func symbol(_ iso: Int, calendar: Calendar, style: KeyPath<Calendar, [String]>) -> String {
    // Calendar symbols start on Sunday.
    calendar[keyPath: style][iso % 7]
  }
}

/// A link setting's value and its Change… button.
private struct LinkValue: View {
  let link: URL?
  let change: () -> Void

  var body: some View {
    HStack {
      Text(link?.absoluteString ?? "None")
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
      Button("Change…", action: change)
    }
  }
}
