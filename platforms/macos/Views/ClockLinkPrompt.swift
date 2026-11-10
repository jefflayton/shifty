import AppKit

/// Asks for a clock link. A text field doesn't fit in the Settings menu, so
/// this is an alert of its own.
@MainActor
enum ClockLinkPrompt {
  enum Kind {
    /// The clock-out link, which clocking in uses too unless it has its own.
    case clockOut
    /// Clocking in's own link.
    case clockIn
  }

  /// Returns false if cancelled.
  @discardableResult
  static func run(_ kind: Kind, preferences: Preferences) -> Bool {
    let current = kind == .clockIn ? preferences.separateClockInLink : preferences.clockOutLink
    var text = current?.absoluteString ?? ""
    var invalid = false

    while true {
      let alert = NSAlert()
      switch kind {
      case .clockOut where preferences.separateClockInLink == nil:
        alert.messageText = "Clock Link"
        alert.informativeText =
          "Clocking in or out from the menu bar can open this link, like your "
          + "timeclock page, and alarms show a Clock Out button that opens it. "
          + "Leave it empty for none."
      case .clockOut:
        alert.messageText = "Clock-Out Link"
        alert.informativeText =
          "Clocking out from the menu bar can open this link, and alarms show a "
          + "Clock Out button that opens it. Leave it empty for none."
      case .clockIn:
        alert.messageText = "Clock-In Link"
        alert.informativeText =
          "Clocking in from the menu bar can open this link instead of the "
          + "clock-out link. Leave it empty to use that one."
      }
      if invalid {
        alert.informativeText = "“\(text)” isn't a link. Enter a web address, like your timeclock page."
      }
      alert.addButton(withTitle: "Save")
      alert.addButton(withTitle: "Cancel")

      let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
      field.placeholderString = "https://"
      field.stringValue = text
      alert.accessoryView = field
      alert.window.initialFirstResponder = field

      NSApp.activate(ignoringOtherApps: true)
      guard alert.runModal() == .alertFirstButtonReturn else { return false }

      text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      let link = Preferences.link(from: text)
      if text.isEmpty || link != nil {
        if kind == .clockIn {
          preferences.separateClockInLink = link
        } else {
          preferences.clockOutLink = link
        }
        return true
      }
      invalid = true
    }
  }

  /// After clocking in or out, or starting or ending lunch, from the menu
  /// bar: opens the link, or asks first, remembering "Don't ask again" as the
  /// answer from now on.
  static func offer(_ event: ClockEvent, preferences: Preferences) {
    let link: URL
    switch preferences.clockLinkAction(for: event) {
    case .none: return
    case .open(let url): link = url
    case .ask(let url):
      let alert = NSAlert()
      alert.messageText = event.question
      alert.informativeText = "Opens \(url.host() ?? url.absoluteString)."
      alert.addButton(withTitle: "Open")
      alert.addButton(withTitle: "Not Now")
      alert.showsSuppressionButton = true
      alert.suppressionButton?.title = "Don't ask again"
      NSApp.activate(ignoringOtherApps: true)
      let open = alert.runModal() == .alertFirstButtonReturn
      if alert.suppressionButton?.state == .on {
        preferences.clockLinkMode = open ? .always : .never
      }
      guard open else { return }
      link = url
    }
    NSWorkspace.shared.open(link)
  }
}

/// Something done in the menu bar that may call for punching the timeclock
/// too.
enum ClockEvent: Equatable {
  case clockIn
  case clockOut
  /// Started lunch, which is clocked out for.
  case lunchStarts
  /// Back from lunch: clock back in.
  case lunchEnds

  /// Whether it opens the clock-in link rather than the clock-out one.
  var clockingIn: Bool { self == .clockIn || self == .lunchEnds }

  var isLunch: Bool { self == .lunchStarts || self == .lunchEnds }

  /// What the prompt asks.
  var question: String {
    switch self {
    case .clockIn: "Clock in on your timeclock too?"
    case .clockOut: "Clock out on your timeclock too?"
    case .lunchStarts: "Clock out for lunch on your timeclock too?"
    case .lunchEnds: "Clock back in from lunch on your timeclock too?"
    }
  }
}
