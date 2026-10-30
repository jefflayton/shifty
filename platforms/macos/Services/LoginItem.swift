import Foundation
import Observation
import ServiceManagement

/// Whether Shifty opens at login. The system's login items are the source of
/// truth (you can also change it in System Settings), so nothing is stored.
@MainActor @Observable final class LoginItem {
  private(set) var isEnabled = false

  init() { refresh() }

  func refresh() {
    isEnabled = SMAppService.mainApp.status == .enabled
  }

  func setEnabled(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      log("Login item:", error.localizedDescription)
    }
    // macOS can ask for approval in System Settings instead of enabling it.
    if enabled, SMAppService.mainApp.status == .requiresApproval {
      SMAppService.openSystemSettingsLoginItems()
    }
    refresh()
  }
}
