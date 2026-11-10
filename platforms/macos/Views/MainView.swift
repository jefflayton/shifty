import Observation
import SwiftUI

/// The main window's screens, picked in the sidebar.
enum MainScreen: String, CaseIterable, Identifiable {
  case timesheet = "Timesheet"
  case projects = "Projects"

  var id: Self { self }

  var symbol: String {
    switch self {
    case .timesheet: "calendar"
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
      case .projects: ProjectsView(model: projects)
      }
    }
    .frame(minWidth: 940, minHeight: 520)
    .onChange(of: navigation.screen) { _, new in
      // Pick up what another screen changed: a deleted project's time.
      switch new {
      case .timesheet: timesheet.reload()
      case .projects:
        projects.reload()
        projects.clearError()
      }
    }
  }
}
