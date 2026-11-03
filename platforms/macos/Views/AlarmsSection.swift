import SwiftUI

struct AlarmsSection: View {
  @Bindable var model: ShiftModel
  let preferences: Preferences

  var body: some View {
    FormSection("Alarms") {
      Menu {
        Button("At clock out") { add(.beforeClockOut(minutes: 0)) }
        Button("15 min before clock out") { add(.beforeClockOut(minutes: 15)) }
        Button("At a set time") { add(.atTime(model.clockOut)) }
        Section("Lunch") {
          Button("When lunch opens") { add(.lunchOpens) }
          Button("15 min before lunch closes") { add(.beforeLunchCloses(minutes: 15)) }
        }
      } label: {
        Image(systemName: "plus")
          .font(.subheadline.weight(.semibold))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Add an alarm")
    } content: {
      if model.alarms.isEmpty {
        Text("Get a reminder before you clock out, or for lunch.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      let clockOut = model.clockOut
      let lunch = model.lunch(preferences.lunch, now: Date())
      ForEach($model.alarms) { $rule in
        AlarmRow(
          rule: $rule,
          fireDate: rule.fireDate(clockIn: model.clockInTime, clockOut: clockOut, lunch: lunch),
          idle: rule.isLunch ? preferences.lunch.quietReason(lunch) : nil,
          paused: model.isOnBreak && rule.followsClockOut,
          onRemove: {
            let id = rule.id
            model.alarms.removeAll { $0.id == id }
          }
        )
      }
    }
  }

  private func add(_ trigger: AlarmRule.Trigger) {
    model.alarms.append(AlarmRule(trigger: trigger))
    // A lunch alarm needs the lunch window; it's off until asked for.
    if case .lunchOpens = trigger { preferences.lunch.isEnabled = true }
    if case .beforeLunchCloses = trigger { preferences.lunch.isEnabled = true }
    AlarmController.shared.requestPermission()
  }
}

struct AlarmRow: View {
  @Binding var rule: AlarmRule
  /// nil for a lunch alarm that won't ring on this shift.
  let fireDate: Date?
  /// Why a lunch alarm won't ring, when it won't.
  let idle: String?
  /// Waiting for a break to end, when clock out is known again.
  let paused: Bool
  let onRemove: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      RemoveButton(help: "Remove alarm", action: onRemove)

      Group {
        switch rule.trigger {
        case .beforeClockOut(let minutes):
          Text(minutes == 0 ? "At clock out" : "\(minutes) min before")
            .monospacedDigit()
            .fixedSize()
          Stepper("Minutes before clock out", value: minutesBefore, in: 0...240, step: 5)
            .labelsHidden()
        case .atTime:
          Text("At").fixedSize()
          DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
            .datePickerStyle(.field)
            .labelsHidden()
            .fixedSize()
        case .lunchOpens:
          Label("Lunch opens", systemImage: "fork.knife")
            .fixedSize()
            .help("Rings when the lunch window opens, unless you've had lunch")
        case .beforeLunchCloses(let minutes):
          Label(minutes == 0 ? "Lunch closes" : "\(minutes) min left", systemImage: "fork.knife")
            .monospacedDigit()
            .fixedSize()
            .help("Rings before the lunch window closes, unless you've had lunch")
          Stepper("Minutes before lunch closes", value: lunchMinutes, in: 0...120, step: 5)
            .labelsHidden()
        }
      }
      .opacity(rule.isEnabled ? 1 : 0.5)

      Spacer()

      // A set-time alarm's picker already shows when it rings.
      if paused {
        Text("After break")
          .foregroundStyle(.secondary)
          .fixedSize()
          .opacity(rule.isEnabled ? 1 : 0.5)
      } else if showsFireDate, let fireDate {
        Text(fireDate, style: .time)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .fixedSize()
          .opacity(rule.isEnabled ? 1 : 0.5)
      } else if let idle {
        Text(idle)
          .foregroundStyle(.secondary)
          .fixedSize()
          .opacity(rule.isEnabled ? 1 : 0.5)
      }

      Toggle("Enabled", isOn: $rule.isEnabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
  }

  private var minutesBefore: Binding<Int> {
    Binding(
      get: {
        if case .beforeClockOut(let minutes) = rule.trigger { minutes } else { 0 }
      },
      set: { rule.trigger = .beforeClockOut(minutes: $0) }
    )
  }

  /// A set-time alarm's picker already shows when it rings.
  private var showsFireDate: Bool {
    if case .atTime = rule.trigger { false } else { true }
  }

  private var lunchMinutes: Binding<Int> {
    Binding(
      get: {
        if case .beforeLunchCloses(let minutes) = rule.trigger { minutes } else { 0 }
      },
      set: { rule.trigger = .beforeLunchCloses(minutes: $0) }
    )
  }

  private var time: Binding<Date> {
    Binding(
      get: {
        if case .atTime(let date) = rule.trigger { date } else { Date() }
      },
      set: { rule.trigger = .atTime($0) }
    )
  }
}
