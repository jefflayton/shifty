import SwiftUI

struct AlarmsSection: View {
  @Bindable var model: ShiftModel

  /// Rows for the popover's Grid.
  var body: some View {
    GridRow {
      FormLabel("Alarms")
      Menu {
        Button("At clock out") { add(.beforeClockOut(minutes: 0)) }
        Button("15 min before clock out") { add(.beforeClockOut(minutes: 15)) }
        Button("At a set time") { add(.atTime(model.clockOut)) }
      } label: {
        Image(systemName: "plus.circle")
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }

    if model.alarms.isEmpty {
      GridRow {
        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
        Text("Alarms follow your clock out time as breaks change.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }

    let clockOut = model.clockOut
    ForEach($model.alarms) { $rule in
      AlarmRow(
        rule: $rule,
        fireDate: rule.fireDate(clockIn: model.clockInTime, clockOut: clockOut),
        onDelete: {
          let id = rule.id
          model.alarms.removeAll { $0.id == id }
        }
      )
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
  let onDelete: () -> Void

  /// A GridRow: the on/off switch sits in the label column.
  var body: some View {
    GridRow {
      Toggle("", isOn: $rule.isEnabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .gridColumnAlignment(.trailing)

      HStack(spacing: 6) {
        trigger
        Spacer()

        // A set-time alarm's picker already shows when it rings.
        if case .beforeClockOut = rule.trigger {
          Text(fireDate, style: .time)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize()
        }

        Button(action: onDelete) {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
      }
      .opacity(rule.isEnabled ? 1 : 0.5)
    }
  }

  @ViewBuilder private var trigger: some View {
    switch rule.trigger {
    case .beforeClockOut(let minutes):
      Stepper(value: minutesBefore, in: 0...240, step: 5) {
        Text(minutes == 0 ? "At clock out" : "\(minutes) min before")
          .monospacedDigit()
          .fixedSize()
      }
    case .atTime:
      DatePicker("", selection: time, displayedComponents: .hourAndMinute)
        .labelsHidden()
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
