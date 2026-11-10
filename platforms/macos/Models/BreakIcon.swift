import Foundation

/// The SF Symbols breaks can show: lunch, the breaks you start from the menu
/// bar, and each scheduled break. Stored by name (in the store for presets,
/// so every frontend sees the same choice); nil means the default.
enum BreakIcon {
  /// Lunch, unless you pick another.
  static let lunch = "fork.knife"
  /// A break you start from the menu bar, and a scheduled break with no
  /// icon of its own.
  static let rest = "cup.and.saucer"

  struct Choice: Identifiable, Equatable {
    let symbol: String
    let name: String
    var id: String { symbol }
  }

  /// What the pickers offer. All in SF Symbols 6 (macOS 15).
  static let choices: [Choice] = [
    Choice(symbol: "fork.knife", name: "Fork and Knife"),
    Choice(symbol: "takeoutbag.and.cup.and.straw", name: "Takeout"),
    Choice(symbol: "cup.and.saucer", name: "Cup"),
    Choice(symbol: "mug", name: "Mug"),
    Choice(symbol: "carrot", name: "Carrot"),
    Choice(symbol: "birthday.cake", name: "Cake"),
    Choice(symbol: "figure.walk", name: "Walk"),
    Choice(symbol: "figure.run", name: "Run"),
    Choice(symbol: "dumbbell", name: "Dumbbell"),
    Choice(symbol: "book", name: "Book"),
    Choice(symbol: "graduationcap", name: "Class"),
    Choice(symbol: "bed.double", name: "Bed"),
    Choice(symbol: "moon.zzz", name: "Nap"),
    Choice(symbol: "sun.max", name: "Sun"),
    Choice(symbol: "leaf", name: "Leaf"),
    Choice(symbol: "car", name: "Car"),
    Choice(symbol: "tram", name: "Train"),
    Choice(symbol: "cart", name: "Errands"),
    Choice(symbol: "phone", name: "Phone"),
    Choice(symbol: "person.2", name: "People"),
    Choice(symbol: "stethoscope", name: "Appointment"),
    Choice(symbol: "pawprint", name: "Pet"),
    Choice(symbol: "gamecontroller", name: "Game"),
    Choice(symbol: "music.note", name: "Music"),
  ]

  /// The choices, with `symbol` added at the end if it isn't one (picked
  /// elsewhere, like the TUI or a newer Shifty), so the picker still shows it.
  static func choices(including symbol: String?) -> [Choice] {
    guard let symbol, !symbol.isEmpty, !choices.contains(where: { $0.symbol == symbol }) else {
      return choices
    }
    return choices + [Choice(symbol: symbol, name: symbol)]
  }

  /// `icon`, or `fallback` when it's unset or empty.
  static func symbol(_ icon: String?, or fallback: String) -> String {
    guard let icon, !icon.isEmpty else { return fallback }
    return icon
  }
}
