import SwiftUI

/// The main window's Breaks page: the lunch window, scheduled breaks like
/// a class, and the icon for breaks you start from the menu bar. Today's
/// breaks are on the timesheet and in the menu bar; so are break alarms.
struct BreaksView: View {
  @Bindable var preferences: Preferences
  /// The menu bar's shift, for adding a scheduled break to it today.
  let shift: ShiftModel?

  var body: some View {
    Form {
      BreakSettings(preferences: preferences, shift: shift)
    }
    .formStyle(.grouped)
    .frame(maxWidth: 720)
    .frame(maxWidth: .infinity)
    .navigationTitle("Breaks")
    .navigationSubtitle(subtitle)
  }

  private var subtitle: String {
    let scheduled = preferences.scheduledBreaks.count
    let lunch = preferences.lunch.isEnabled ? "Lunch window on" : "No lunch window"
    guard scheduled > 0 else { return lunch }
    return "\(lunch) · \(scheduled) scheduled"
  }
}
