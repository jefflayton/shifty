import Foundation

/// Microsoft Teams, as auto-switch sees it: a call is on while Teams has
/// the microphone, and its windows' titles name the meeting, so a project's
/// keyword in one says which project the meeting is for.
enum Meetings {
  /// New Teams, then classic. Their helper processes' ids start with these.
  static let teams = ["com.microsoft.teams2", "com.microsoft.teams"]

  /// Whether `bundle` is Teams or one of its helpers.
  static func isTeams(_ bundle: String?) -> Bool {
    guard let bundle else { return false }
    return teams.contains { bundle == $0 || bundle.hasPrefix($0 + ".") }
  }

  /// Whether a process at `path` is part of Teams, for audio that names no
  /// bundle.
  static func isTeams(path: String) -> Bool {
    path.contains("/Microsoft Teams.app/") || path.contains("/Microsoft Teams classic.app/")
  }

  /// What a Teams window's title calls the meeting: its parts ("a | b")
  /// without Teams' own name. "Shifty sync | Microsoft Teams" reads
  /// "Shifty sync"; nil if nothing's left.
  static func name(fromTitle title: String) -> String? {
    let parts = title.components(separatedBy: "|")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.lowercased().hasPrefix("microsoft teams") }
    return parts.isEmpty ? nil : parts.joined(separator: " | ")
  }

  /// Teams' window titles in the order to look for a keyword in: windows
  /// that weren't open before the call (the meeting's own, most likely)
  /// first, then the rest, like the main window showing a chat.
  static func ordered(_ titles: [String], before: Set<String>) -> [String] {
    titles.filter { !before.contains($0) } + titles.filter { before.contains($0) }
  }
}
