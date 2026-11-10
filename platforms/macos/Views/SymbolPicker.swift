import SwiftUI

/// Picks a break's icon from `BreakIcon.choices`. Picking the default
/// stores nil, so the break follows the default if it ever changes.
struct SymbolPicker: View {
  let label: String
  @Binding var symbol: String?
  /// What nil shows.
  let fallback: String
  /// Just the icon, as a borderless menu, for a row with other controls.
  var compact = false

  init(_ label: String, symbol: Binding<String?>, fallback: String, compact: Bool = false) {
    self.label = label
    _symbol = symbol
    self.fallback = fallback
    self.compact = compact
  }

  private var selection: Binding<String> {
    Binding(
      get: { BreakIcon.symbol(symbol, or: fallback) },
      set: { symbol = $0 == fallback ? nil : $0 })
  }

  private var picker: some View {
    Picker(label, selection: selection) {
      ForEach(BreakIcon.choices(including: symbol)) { choice in
        Label(choice.name, systemImage: choice.symbol).tag(choice.symbol)
      }
    }
  }

  var body: some View {
    if compact {
      Menu {
        picker.pickerStyle(.inline).labelsHidden()
      } label: {
        Image(systemName: selection.wrappedValue)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help(label)
      .accessibilityLabel(label)
    } else {
      picker.pickerStyle(.menu)
    }
  }
}
