import AppKit
import Sparkle
import SwiftUI

struct PopoverView: View {
  @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
  private let updater: SPUUpdater

  @Bindable var model: ShiftModel
  @Bindable var preferences: Preferences
  let loginItem: LoginItem

  init(updater: SPUUpdater, model: ShiftModel, preferences: Preferences, loginItem: LoginItem) {
    self.updater = updater
    self.model = model
    self.preferences = preferences
    self.loginItem = loginItem

    // Create our view model for our CheckForUpdatesView
    self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ShiftSummaryView(model: model)

      FormSection("Shift") {
        FormRow("Clock in") {
          HStack(spacing: 6) {
            DatePicker(
              "Clock in", selection: $model.clockInTime, displayedComponents: .hourAndMinute
            )
            .datePickerStyle(.field)
            .labelsHidden()
            .fixedSize()
            Button("Now") { model.clockInTime = Date() }
              .controlSize(.small)
          }
        }
        FormRow("Length") {
          HStack(spacing: 6) {
            TextField("Length", value: $model.shiftLength, format: .number)
              .labelsHidden()
              .multilineTextAlignment(.trailing)
              .frame(width: 40)
            Text("hours").foregroundStyle(.secondary)
            Stepper("Length", value: $model.shiftLength, in: 0.25...24, step: 0.25)
              .labelsHidden()
          }
        }
      }

      FormSection("Breaks") {
        HStack(spacing: 4) {
          if !model.isOnBreak {
            Button("Start Break") { model.startBreak() }
              .buttonStyle(.borderless)
              .font(.subheadline)
              .foregroundStyle(.tint)
              .help("Start a break now; end it when you're back")
          }
          AddButton(help: "Add a break") { model.breaks.append(Interval()) }
        }
      } content: {
        if let start = model.breakStart {
          OngoingBreakRow(start: start) { model.endBreak() }
        } else if model.breaks.isEmpty {
          Text("No breaks").foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        ForEach($model.breaks) { $brk in
          BreakRow(brk: $brk) {
            let id = brk.id
            model.breaks.removeAll { $0.id == id }
          }
        }
      }

      AlarmsSection(model: model)

      VStack(alignment: .leading, spacing: 2) {
        Divider().padding(.bottom, 4)
        MenuRowButton("Check for Updates…", action: updater.checkForUpdates)
          .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
        MenuRowMenu("Settings") {
          Picker("Menu Bar Shows", selection: $preferences.menuBarDisplay) {
            ForEach(MenuBarDisplay.allCases) { Text($0.label).tag($0) }
          }
          Toggle(
            "Open at Login",
            isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
        }
        MenuRowButton("Quit Shifty", shortcut: "⌘Q") { NSApp.terminate(nil) }
      }
      .padding(.horizontal, -6)
    }
    .padding(14)
    .frame(width: 320)
    .onAppear {
      // Nothing observes the clock, so check for a finished shift on open.
      model.rollOverIfStale()
      // Login items can also be changed in System Settings.
      loginItem.refresh()
    }
  }
}

/// The clock-out time, how far away it is, and the shift at a glance.
struct ShiftSummaryView: View {
  let model: ShiftModel

  var body: some View {
    // Inside the timeline: during a break, clock out moves with the clock.
    TimelineView(.periodic(from: .now, by: 30)) { context in
      let clockOut = model.clockOut(now: context.date)
      let breaks = model.breaks(now: context.date)

      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .lastTextBaseline) {
          VStack(alignment: .leading, spacing: 0) {
            Text("Clock out")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Text(clockOut, style: .time)
              .font(.system(size: 34, weight: .semibold, design: .rounded))
              .monospacedDigit()
              .contentTransition(.numericText())
          }
          Spacer()
          Text(ShiftSummary.relative(clockOut, now: context.date))
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }

        ShiftBar(
          clockIn: model.clockInTime,
          clockOut: clockOut,
          breaks: ShiftSummary.breakSpans(breaks, clockIn: model.clockInTime, clockOut: clockOut),
          now: context.date
        )

        HStack {
          Text(model.clockInTime, style: .time)
          Spacer()
          let onBreak = ShiftSummary.breakSeconds(
            breaks, clockIn: model.clockInTime, clockOut: clockOut)
          if onBreak > 0 {
            Text("\(ShiftSummary.duration(onBreak)) on break")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
      }
      .animation(.snappy, value: clockOut)
    }
  }
}

/// The break you're on now: when it started, how long it's been, and a way
/// to end it.
struct OngoingBreakRow: View {
  let start: Date
  let onEnd: () -> Void

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      HStack(spacing: 6) {
        Image(systemName: "cup.and.saucer.fill")
          .foregroundStyle(.secondary)
          .help("On break")
        Text("Since \(start, style: .time)")
        Spacer()
        Text(ShiftSummary.duration(context.date.timeIntervalSince(start)))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .fixedSize()
        Button("End", action: onEnd)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
          .help("End the break now")
      }
    }
  }
}

struct BreakRow: View {
  @Binding var brk: Interval
  let onRemove: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        RemoveButton(help: "Remove break", action: onRemove)
        DatePicker("Start", selection: $brk.inDate, displayedComponents: .hourAndMinute)
          .datePickerStyle(.field)
          .labelsHidden()
          .fixedSize()
        Text("to").foregroundStyle(.secondary)
        DatePicker("End", selection: $brk.outDate, displayedComponents: .hourAndMinute)
          .datePickerStyle(.field)
          .labelsHidden()
          .fixedSize()
        Spacer()
        if brk.isValid {
          let (start, end) = ShiftTimes.anchor(brk, clockIn: brk.inDate)
          Text(ShiftSummary.duration(end.timeIntervalSince(start)))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize()
        }
      }
      if !brk.isValid {
        Text("A break must be between 1 minute and 12 hours.")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .padding(.vertical, brk.isValid ? 0 : 6)
  }
}
