import AppKit
import Sparkle
import SwiftUI

struct PopoverView: View {
  @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
  private let updater: SPUUpdater

  @Bindable var model: ShiftModel
  @Bindable var preferences: Preferences
  let loginItem: LoginItem
  /// The running timer; nil without the store.
  let tracking: TrackingModel?
  /// Following where you work; nil without the store.
  let autoSwitch: AutoSwitchModel?
  /// Opens the main window; nil without the store.
  let openTimesheet: (() -> Void)?
  let openSettings: () -> Void
  /// After Clock In or Out, or starting or ending lunch, from here, for
  /// the clock link.
  let clocked: (ClockEvent) -> Void

  init(
    updater: SPUUpdater, model: ShiftModel, preferences: Preferences, loginItem: LoginItem,
    tracking: TrackingModel? = nil, autoSwitch: AutoSwitchModel? = nil,
    openTimesheet: (() -> Void)? = nil,
    openSettings: @escaping () -> Void, clocked: @escaping (ClockEvent) -> Void = { _ in }
  ) {
    self.updater = updater
    self.model = model
    self.preferences = preferences
    self.loginItem = loginItem
    self.tracking = tracking
    self.autoSwitch = autoSwitch
    self.openTimesheet = openTimesheet
    self.openSettings = openSettings
    self.clocked = clocked

    // Create our view model for our CheckForUpdatesView
    self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      ShiftSummaryView(
        model: model, lunch: preferences.lunch, showsWeekGoal: preferences.weeklyGoal != nil)

      ShiftActions(model: model, preferences: preferences, clocked: clocked)

      FormSection("Shift") {
        if model.isClockedIn {
          Label("Clocked in", systemImage: "circle.fill")
            .labelStyle(StatusLabelStyle())
            .help("This shift is tracked, shared with the TUI and CLI")
        }
      } content: {
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

      if let tracking {
        TrackingSection(tracking: tracking, autoSwitch: autoSwitch)
      }

      FormSection("Breaks") {
        AddButton(help: "Add a break") { model.breaks.append(Interval()) }
      } content: {
        if let start = model.breakStart {
          let lunch = model.isOnLunch(preferences.lunch)
          OngoingBreakRow(
            start: start, symbol: lunch ? preferences.lunch.symbol : preferences.breakSymbol,
            isLunch: lunch)
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

      AlarmsSection(model: model, preferences: preferences)

      VStack(alignment: .leading, spacing: 2) {
        Divider().padding(.bottom, 4)
        if let openTimesheet {
          MenuRowButton("Open Timesheet…", action: openTimesheet)
        }
        MenuRowButton("Check for Updates…", action: updater.checkForUpdates)
          .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
        MenuRowButton("Settings…", shortcut: "⌘,", action: openSettings)
        MenuRowButton("Quit Shifty", shortcut: "⌘Q") { NSApp.terminate(nil) }
      }
      .padding(.horizontal, -6)
    }
    .padding(14)
    .frame(width: 320)
    // A break or clock out stops the timer. The shift saves to the store in
    // a task queued when it changed, so read after that.
    .onChange(of: model.breakStart) { Task { @MainActor in tracking?.reload() } }
    .onChange(of: model.isClockedIn) { Task { @MainActor in tracking?.reload() } }
    .onAppear {
      // Nothing observes the clock, so check for a finished shift on open.
      model.rollOverIfStale()
      tracking?.reload()
      // Login items can also be changed in System Settings.
      loginItem.refresh()
    }
  }
}

/// The clock-out time, how far away it is, and the shift at a glance.
struct ShiftSummaryView: View {
  let model: ShiftModel
  let lunch: LunchRule
  /// Whether there's a weekly goal to show the week against.
  var showsWeekGoal = false

  var body: some View {
    // Inside the timeline: during a break, clock out moves with the clock.
    TimelineView(.periodic(from: .now, by: 30)) { context in
      let clockOut = model.clockOut(now: context.date)
      let breaks = model.breaks(now: context.date)
      let plan = model.lunch(lunch, now: context.date)

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
          let over = model.isClockedIn && context.date.timeIntervalSince(clockOut) >= 60
          Text(
            ShiftSummary.relative(clockOut, now: context.date, isClockedIn: model.isClockedIn)
          )
          .font(.callout)
          .foregroundStyle(over ? AnyShapeStyle(OverStyle.color) : AnyShapeStyle(.secondary))
          .monospacedDigit()
        }

        ShiftBar(
          clockIn: model.clockInTime,
          clockOut: clockOut,
          breaks: ShiftSummary.breakSpans(breaks, clockIn: model.clockInTime, clockOut: clockOut),
          lunch: plan.flatMap {
            ShiftSummary.span($0, clockIn: model.clockInTime, clockOut: clockOut, now: context.date)
          },
          lunchBreak: plan.flatMap {
            ShiftSummary.lunchBreak(
              $0, clockIn: model.clockInTime, clockOut: clockOut, now: context.date)
          },
          now: context.date,
          showsOver: model.isClockedIn
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

        if let plan {
          LunchStatus(plan: plan, now: context.date, symbol: lunch.symbol)
            .font(.caption)
        }

        if showsWeekGoal, let goal = model.weekGoal(now: context.date) {
          WeekGoalStatus(goal: goal)
            .font(.caption)
        }
      }
      .animation(.snappy, value: clockOut)
    }
  }
}

/// This week against the weekly goal: worked of the goal, then what's left,
/// or when today's shift gets you there.
struct WeekGoalStatus: View {
  let goal: ShiftStore.WeekGoal

  var body: some View {
    HStack {
      Label {
        Text(
          "\(TimesheetFormat.duration(goal.worked)) of \(TimesheetFormat.duration(goal.goal)) this week"
        )
      } icon: {
        Image(systemName: goal.isMet ? "checkmark.circle.fill" : "target")
      }
      Spacer()
      Text(goal.detail)
        .foregroundStyle(
          goal.isMet || goal.leftAfterClockOut == 0
            ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }
    .foregroundStyle(.secondary)
    .monospacedDigit()
    .help(goal.helpText)
  }
}

/// The break you're on now: when it started and how long it's been. End
/// Break above ends it.
struct OngoingBreakRow: View {
  let start: Date
  var symbol = BreakIcon.rest
  var isLunch = false

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      HStack(spacing: 6) {
        Image(systemName: symbol)
          .symbolVariant(.fill)
          .foregroundStyle(.secondary)
          .help(isLunch ? "On lunch" : "On break")
        Text("Since \(start, style: .time)")
        Spacer()
        Text(ShiftSummary.duration(context.date.timeIntervalSince(start)))
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .fixedSize()
      }
    }
  }
}

/// The shift's two big actions, side by side under the clock-out time:
/// Clock In or Out, and Start or End Break.
struct ShiftActions: View {
  let model: ShiftModel
  let preferences: Preferences
  /// After Clock In or Out, or starting or ending lunch, for the clock link.
  let clocked: (ClockEvent) -> Void

  var body: some View {
    HStack(spacing: 8) {
      // Without the store there's nothing to clock in to.
      if model.store != nil {
        if model.isClockedIn {
          Button {
            model.clockOutNow()
            clocked(.clockOut)
          } label: {
            Label("Clock Out", systemImage: "stop.fill").frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .help("End the shift now; the TUI and CLI see it too")
        } else {
          Button {
            model.clockInNow()
            clocked(.clockIn)
          } label: {
            Label("Clock In", systemImage: "play.fill").frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .help("Start the shift now and track it, shared with the TUI and CLI")
        }
      }
      if model.isOnBreak {
        let lunch = model.isOnLunch(preferences.lunch)
        Button {
          // Lunch you clocked out for, you clock back in from. Read before
          // the break ends, while it's still the one you're on.
          let backFromLunch = lunch && model.isClockedIn
          model.endBreak()
          if backFromLunch { clocked(.lunchEnds) }
        } label: {
          Label(
            lunch ? "End Lunch" : "End Break",
            systemImage: lunch ? preferences.lunch.symbol : preferences.breakSymbol
          )
          .symbolVariant(.fill)
          .frame(maxWidth: .infinity)
        }
        .help(lunch ? "End lunch now" : "End the break now")
      } else {
        Button {
          model.startBreak()
          // The break that counts as lunch is clocked out for.
          if model.isClockedIn && model.isOnLunch(preferences.lunch) { clocked(.lunchStarts) }
        } label: {
          Label("Start Break", systemImage: preferences.breakSymbol).frame(maxWidth: .infinity)
        }
        .help("Start a break now; end it when you're back")
      }
    }
    .controlSize(.large)
  }
}

/// A small colored dot before a section heading's status text.
struct StatusLabelStyle: LabelStyle {
  var color: Color = .green

  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 5) {
      configuration.icon
        .font(.system(size: 6))
        .foregroundStyle(color)
      configuration.title
        .font(.subheadline)
        .foregroundStyle(.secondary)
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
