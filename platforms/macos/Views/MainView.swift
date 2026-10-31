import SwiftUI

/// The main window's screens, switched from the toolbar.
enum MainScreen: String, CaseIterable, Identifiable {
  case timesheet = "Timesheet"
  case projects = "Projects"

  var id: Self { self }
}

struct MainView: View {
  let timesheet: TimesheetModel
  let projects: ProjectsModel

  @State private var screen = MainScreen.timesheet

  var body: some View {
    Group {
      switch screen {
      case .timesheet: TimesheetView(model: timesheet)
      case .projects: ProjectsView(model: projects)
      }
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Show", selection: $screen) {
          ForEach(MainScreen.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
    }
    .onChange(of: screen) { _, new in
      // Pick up what the other screen changed: a deleted project's time.
      switch new {
      case .timesheet: timesheet.reload()
      case .projects:
        projects.reload()
        projects.clearError()
      }
    }
  }
}
