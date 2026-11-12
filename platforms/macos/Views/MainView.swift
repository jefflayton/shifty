import Observation
import SwiftUI

/// The main window's screens, picked in the sidebar.
enum MainScreen: String, CaseIterable, Identifiable {
  case timesheet = "Timesheet"
  case meetings = "Meetings"
  case breaks = "Breaks"
  case projects = "Projects"

  var id: Self { self }

  var symbol: String {
    switch self {
    case .timesheet: "calendar"
    case .meetings: "video"
    case .breaks: "cup.and.saucer"
    case .projects: "folder"
    }
  }
}

/// Which screen the main window shows, so the menu bar can pick one.
@Observable final class MainNavigation {
  var screen = MainScreen.timesheet
}

struct MainView: View {
  let timesheet: TimesheetModel
  let projects: ProjectsModel
  let preferences: Preferences
  /// The menu bar's shift, for adding a scheduled break to it today.
  let shift: ShiftModel?
  /// For the Meetings page's last call.
  let autoSwitch: AutoSwitchModel?
  @Bindable var navigation: MainNavigation

  var body: some View {
    NavigationSplitView {
      List(
        selection: Binding(
          get: { navigation.screen },
          set: { if let screen = $0 { navigation.screen = screen } })
      ) {
        ForEach(MainScreen.allCases) { screen in
          Label(screen.rawValue, systemImage: screen.symbol).tag(screen)
        }
      }
      .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 260)
    } detail: {
      switch navigation.screen {
      case .timesheet: TimesheetView(model: timesheet)
      case .meetings:
        MeetingsView(model: timesheet, preferences: preferences, autoSwitch: autoSwitch)
      case .breaks: BreaksView(preferences: preferences, shift: shift)
      case .projects: ProjectsView(model: projects)
      }
    }
    .frame(minWidth: 940, minHeight: 520)
    .onChange(of: navigation.screen) { _, new in
      // Pick up what another screen changed: a deleted project's time.
      switch new {
      case .timesheet, .meetings: timesheet.reload()
      case .breaks: preferences.pull()
      case .projects:
        projects.reload()
        projects.clearError()
      }
    }
  }
}
