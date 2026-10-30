import AppKit

/// Asks for the clock-out link. A text field doesn't fit in the Settings
/// menu, so this is an alert of its own.
@MainActor
enum ClockOutLinkPrompt {
  static func run(preferences: Preferences) {
    var text = preferences.clockOutLink?.absoluteString ?? ""
    var invalid = false

    while true {
      let alert = NSAlert()
      alert.messageText = "Clock-Out Link"
      alert.informativeText =
        invalid
        ? "“\(text)” isn't a link. Enter a web address, like your timeclock page."
        : "Alarms show a Clock Out button that opens this link, "
          + "like your timeclock page. Leave it empty for no button."
      alert.addButton(withTitle: "Save")
      alert.addButton(withTitle: "Cancel")

      let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
      field.placeholderString = "https://"
      field.stringValue = text
      alert.accessoryView = field
      alert.window.initialFirstResponder = field

      NSApp.activate(ignoringOtherApps: true)
      guard alert.runModal() == .alertFirstButtonReturn else { return }

      text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.isEmpty {
        preferences.clockOutLink = nil
        return
      }
      if let link = Preferences.link(from: text) {
        preferences.clockOutLink = link
        return
      }
      invalid = true
    }
  }
}
