import SwiftUI

/// Settings that don't fit in the popover: the days you work, the lunch
/// window, and the menu bar.
struct SettingsView: View {
  @Bindable var preferences: Preferences
  let loginItem: LoginItem

  var body: some View {
    Form {
      Section {
        WeekdayPicker(days: $preferences.workDays)
      } header: {
        Text("Days You Work")
      } footer: {
        Text("The timesheet hides other days unless they have time on them.")
          .foregroundStyle(.secondary)
      }

      Section {
        Toggle("Lunch window", isOn: $preferences.lunch.isEnabled)
        if preferences.lunch.isEnabled {
          LunchSettings(rule: $preferences.lunch)
        }
      } header: {
        Text("Lunch")
      } footer: {
        Text(
          "Counted in time worked. In California, for example, a 30-minute meal break has to start before the end of the fifth hour of work."
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
        LabeledContent("Clock-out link") {
          HStack {
            Text(preferences.clockOutLink?.absoluteString ?? "None")
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
            Button("Change…") { ClockOutLinkPrompt.run(preferences: preferences) }
          }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .fixedSize(horizontal: false, vertical: true)
    .onAppear { loginItem.refresh() }
  }
}

/// The lunch window's bounds, what counts as lunch, and the reminder.
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
    Toggle(
      "Remind me",
      isOn: Binding(
        get: { rule.remindAt != nil },
        set: { on in
          let middle = ((rule.earliest + rule.latest) / 2 / Self.quarter).rounded() * Self.quarter
          rule.remindAt = on ? middle : nil
        }))
    if let remind = rule.remindAt {
      DurationStepper(
        "Remind after",
        value: Binding(get: { remind }, set: { rule.remindAt = $0 }),
        in: rule.earliest...rule.latest, step: Self.quarter, suffix: "of work")
    }
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
