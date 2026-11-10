import Observation
import SwiftUI

/// The main window's screens, picked in the sidebar: the timesheet and
/// projects, then each page of settings.
enum MainScreen: Hashable, Identifiable {
  case timesheet
  case projects
  case settings(SettingsTab)

  var id: Self { self }

  /// The screens that need the store.
  static let tracking: [MainScreen] = [.timesheet, .projects]
  static var settings: [MainScreen] { SettingsTab.allCases.map { .settings($0) } }
  static var all: [MainScreen] { tracking + settings }

  var title: String {
    switch self {
    case .timesheet: "Timesheet"
    case .projects: "Projects"
    case .settings(let tab): tab.title
    }
  }

  var symbol: String {
    switch self {
    case .timesheet: "calendar"
    case .projects: "folder"
    case .settings(let tab): tab.symbol
    }
  }

  var isSettings: Bool {
    if case .settings = self { return true }
    return false
  }
}

/// Which screen the main window shows, so the menu bar can pick one.
@Observable final class MainNavigation {
  var screen = MainScreen.timesheet
}

/// Shifty's window: the timesheet and projects (with the store), and
/// settings.
struct MainView: View {
  /// Nil without the store; then there are only settings.
  let timesheet: TimesheetModel?
  let projects: ProjectsModel?
  @Bindable var navigation: MainNavigation
  let preferences: Preferences
  let loginItem: LoginItem
  /// The menu bar's shift, for adding a scheduled break to it today.
  var shift: ShiftModel? = nil

  var body: some View {
    NavigationSplitView {
      List(
        selection: Binding(
          get: { navigation.screen },
          set: { if let screen = $0 { navigation.screen = screen } })
      ) {
        if timesheet != nil {
          Section {
            ForEach(MainScreen.tracking) { row($0) }
          }
        }
        Section("Settings") {
          ForEach(MainScreen.settings) { row($0) }
        }
      }
      .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
    } detail: {
      detail
    }
    .frame(minWidth: 940, minHeight: 560)
    .onChange(of: navigation.screen) { _, new in
      // Pick up what another screen, the TUI, or the CLI changed.
      switch new {
      case .timesheet: timesheet?.reload()
      case .projects:
        projects?.reload()
        projects?.clearError()
      case .settings:
        preferences.pull()
        // Login items can also be changed in System Settings.
        loginItem.refresh()
      }
    }
  }

  private func row(_ screen: MainScreen) -> some View {
    Label(screen.title, systemImage: screen.symbol).tag(screen)
  }

  @ViewBuilder private var detail: some View {
    switch navigation.screen {
    case .timesheet:
      if let timesheet { TimesheetView(model: timesheet) }
    case .projects:
      if let projects { ProjectsView(model: projects) }
    case .settings(let tab):
      SettingsPane(tab: tab, preferences: preferences, loginItem: loginItem, shift: shift)
        .navigationTitle(tab.title)
    }
  }
}
