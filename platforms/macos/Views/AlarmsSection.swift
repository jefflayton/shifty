import SwiftUI

struct AlarmsSection: View {
  @Bindable var model: ShiftModel

  var body: some View {
    FormSection("Alarms") {
      Menu {
        Button("At clock out") { add(.beforeClockOut(minutes: 0)) }
        Button("15 min before clock out") { add(.beforeClockOut(minutes: 15)) }
        Button("At a set time") { add(.atTime(model.clockOut)) }
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
        Text("Get a reminder before you clock out.")
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      let clockOut = model.clockOut
      ForEach($model.alarms) { $rule in
        AlarmRow(
          rule: $rule,
          fireDate: rule.fireDate(clockIn: model.clockInTime, clockOut: clockOut),
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
    AlarmController.shared.requestPermission()
  }
}

struct AlarmRow: View {
  @Binding var rule: AlarmRule
  let fireDate: Date
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
        }
      }
      .opacity(rule.isEnabled ? 1 : 0.5)

      Spacer()

      // A set-time alarm's picker already shows when it rings.
      if case .beforeClockOut = rule.trigger {
        Text(fireDate, style: .time)
          .foregroundStyle(.secondary)
          .monospacedDigit()
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

  private var time: Binding<Date> {
    Binding(
      get: {
        if case .atTime(let date) = rule.trigger { date } else { Date() }
      },
      set: { rule.trigger = .atTime($0) }
    )
  }
}
