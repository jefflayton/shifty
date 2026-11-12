import SwiftUI

/// The main window's Meetings page: the week's meetings by day, each a row
/// like the timesheet's, its title in the note; how Teams calls are logged;
/// and the last call's window titles, to link a keyword in one to a
/// project. It shares the timesheet's week.
struct MeetingsView: View {
  @Bindable var model: TimesheetModel
  @Bindable var preferences: Preferences
  /// The last call's titles come from here; nil without auto-switch.
  let autoSwitch: AutoSwitchModel?

  var body: some View {
    TimelineView(.periodic(from: .now, by: 30)) { context in
      let now = context.date
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
              .font(.callout)
          }
          if model.meetingDays.isEmpty {
            ContentUnavailableView {
              Label("No Meetings This Week", systemImage: "video")
            } description: {
              Text(
                "Teams calls you log show up here, as does time you mark as a meeting on the timesheet. A meeting is time worked on its project, with its title as the note."
              )
            } actions: {
              Button("Add Meeting") { _ = model.addMeeting(on: addDay(now: now), now: now) }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
          }
          ForEach(model.meetingDays, id: \.self) { day in
            MeetingDay(model: model, day: day, now: now)
          }
          TeamsCalls(model: model, preferences: preferences, autoSwitch: autoSwitch)
        }
        .padding(20)
      }
      .navigationTitle("Meetings · \(WeekTitle.range(model.week))")
      .navigationSubtitle(subtitle(now: now))
      .toolbar { toolbar(now: now) }
    }
  }

  private func subtitle(now: Date) -> String {
    let count = model.meetingCount()
    guard count > 0 else { return "No meetings" }
    return "\(count) \(count == 1 ? "meeting" : "meetings") · "
      + TimesheetFormat.duration(model.meetingTime(now: now))
  }

  /// Today if it's this week, else the week's first day.
  private func addDay(now: Date) -> Date {
    model.week.contains(now) ? model.calendar.startOfDay(for: now) : model.week.start
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
        _ = model.addMeeting(on: addDay(now: now), now: now)
      } label: {
        Label("Add Meeting", systemImage: "plus")
      }
      .help("Add a meeting you didn't log")
    }
  }
}

/// One day's meetings, with how long they ran.
private struct MeetingDay: View {
  let model: TimesheetModel
  let day: Date
  let now: Date

  var body: some View {
    let (title, detail) = DaySection.title(day, now: now)
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(title).font(.headline)
        Text(detail).foregroundStyle(.secondary)
        Spacer()
        Text(TimesheetFormat.duration(model.meetingTime(on: day, now: now)))
          .font(.system(.body, design: .rounded).weight(.medium))
          .monospacedDigit()
          .help("In meetings")
      }
      .padding(.horizontal, 6)
      GroupedRows(minRowHeight: 38, rowInset: 10) {
        ForEach(model.meetings(on: day)) { entry in
          EntryRow(model: model, entry: entry, now: now)
            .padding(.vertical, 2)
        }
      }
    }
  }
}

/// How Teams calls are logged, and the last call's window titles: what a
/// project's keyword has to match for the call to log there.
private struct TeamsCalls: View {
  let model: TimesheetModel
  @Bindable var preferences: Preferences
  let autoSwitch: AutoSwitchModel?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Teams Calls").font(.headline).padding(.horizontal, 6)
      GroupedRows {
        Toggle("Offer to log Teams calls as meetings", isOn: $preferences.meetingSwitch)
          .disabled(!preferences.autoSwitch)
        Toggle("Log them without asking", isOn: $preferences.meetingAutoLog)
          .disabled(!preferences.autoSwitch || !preferences.meetingSwitch)
      }
      Text(
        preferences.autoSwitch
          ? "A call goes on the project a keyword in its title names, else on the running timer's. When it ends, what ran before picks up again. Spaces and dashes don't matter: “stand up” matches Standup and Stand-up."
          : "Turn on auto-switch in Settings to log Teams calls."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 6)

      if let titles = autoSwitch?.callTitles, !titles.isEmpty {
        Text("Last Call's Windows").font(.headline).padding(.horizontal, 6).padding(.top, 10)
        GroupedRows {
          ForEach(titles, id: \.self) { title in
            CallTitleRow(model: model, title: title)
          }
        }
        Text(
          "What Teams called its windows during your last call. A keyword has to be in one of these; if the meeting's name isn't, Teams didn't show it."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
      }
    }
  }
}

/// One of a call's window titles, with a menu to link its name to a
/// project as a keyword.
private struct CallTitleRow: View {
  let model: TimesheetModel
  let title: String

  var body: some View {
    let name = Meetings.name(fromTitle: title)
    HStack {
      Text(title)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
      Spacer()
      if let name {
        Menu("Add Keyword") {
          Section("Link “\(name)” to") {
            ForEach(model.sheet.projects) { project in
              Button(project.name) { model.link(keyword: name, to: project.id) }
            }
          }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Log calls named “\(name)” on a project")
      }
    }
  }
}
