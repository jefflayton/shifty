import Observation
import SwiftUI

/// The main window's screens, switched from the toolbar.
enum MainScreen: String, CaseIterable, Identifiable {
  case timesheet = "Timesheet"
  case projects = "Projects"
  case settings = "Settings"

  var id: Self { self }

  /// Without the store there's no time to show, only settings.
  var needsStore: Bool { self != .settings }
}

/// Which screen the main window shows, so the menu bar and ⌘, can pick one.
@Observable final class MainNavigation {
  var screen = MainScreen.timesheet
}

struct MainView: View {
  /// nil without the store.
  let timesheet: TimesheetModel?
  let projects: ProjectsModel?
  let preferences: Preferences
  let loginItem: LoginItem
  /// The menu bar's shift, for adding a scheduled break to it today.
  let shift: ShiftModel?
  @Bindable var navigation: MainNavigation

  private var screens: [MainScreen] {
    timesheet == nil ? [.settings] : MainScreen.allCases
  }

  var body: some View {
    Group {
      switch navigation.screen {
      case .timesheet: timesheet.map { TimesheetView(model: $0) }
      case .projects: projects.map { ProjectsView(model: $0) }
      case .settings:
        SettingsView(preferences: preferences, loginItem: loginItem, shift: shift)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(minWidth: 820, minHeight: 520)
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("Show", selection: $navigation.screen) {
          ForEach(screens) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
      }
    }
    .onChange(of: navigation.screen) { _, new in
      // Pick up what another screen changed: a deleted project's time.
      switch new {
      case .timesheet: timesheet?.reload()
      case .projects:
        projects?.reload()
        projects?.clearError()
      case .settings: loginItem.refresh()
      }
    }
  }
}
