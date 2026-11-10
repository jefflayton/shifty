import AppKit
import SwiftUI

/// An hour-and-minute time that reads as plain text and edits in place:
/// click an hour or minute and type, or use the arrow keys. Each change is
/// saved as it's made.
struct TimeField: View {
  let label: String
  let value: Date
  let set: (Date) -> Void
  /// Takes the keyboard when this turns true, as Return on a row asks.
  var focusRequested = false
  var onFocused: () -> Void = {}

  @State private var hovered = false
  @Environment(\.backgroundProminence) private var prominence

  init(
    _ label: String, _ value: Date, focusRequested: Bool = false,
    onFocused: @escaping () -> Void = {}, set: @escaping (Date) -> Void
  ) {
    self.label = label
    self.value = value
    self.set = set
    self.focusRequested = focusRequested
    self.onFocused = onFocused
  }

  var body: some View {
    PlainTimePicker(
      label: label, value: value, set: set, onSelectedRow: prominence == .increased,
      focusRequested: focusRequested, onFocused: onFocused
    )
    .fixedSize()
    .padding(.horizontal, 3)
    .padding(.vertical, 1)
    // A hint on hover that it's editable.
    .background(
      hovered && prominence != .increased ? AnyShapeStyle(.quinary) : AnyShapeStyle(.clear),
      in: RoundedRectangle(cornerRadius: 4, style: .continuous)
    )
    .onHover { hovered = $0 }
    .help("Click to change; type or use the arrow keys")
  }
}

/// A borderless NSDatePicker: SwiftUI's field style always draws a bezel.
private struct PlainTimePicker: NSViewRepresentable {
  let label: String
  let value: Date
  let set: (Date) -> Void
  /// On a selected row's accent fill, so the text goes white.
  let onSelectedRow: Bool
  let focusRequested: Bool
  let onFocused: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSDatePicker {
    let picker = NSDatePicker()
    picker.datePickerStyle = .textField
    picker.datePickerElements = .hourMinute
    picker.isBezeled = false
    picker.isBordered = false
    picker.drawsBackground = false
    picker.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    picker.target = context.coordinator
    picker.action = #selector(Coordinator.changed(_:))
    picker.setAccessibilityLabel(label)
    return picker
  }

  func updateNSView(_ picker: NSDatePicker, context: Context) {
    context.coordinator.set = set
    if picker.dateValue != value { picker.dateValue = value }
    picker.textColor = onSelectedRow ? .alternateSelectedControlTextColor : .labelColor
    if focusRequested {
      // After this update: the window may be mid-layout.
      DispatchQueue.main.async {
        picker.window?.makeFirstResponder(picker)
        onFocused()
      }
    }
  }

  final class Coordinator: NSObject {
    var set: (Date) -> Void = { _ in }

    @objc func changed(_ picker: NSDatePicker) { set(picker.dateValue) }
  }
}

/// A timesheet row you can select: click it, or move to it with the arrow
/// keys. Selected, it's on the accent color while the timesheet has the
/// keyboard, and gray when it doesn't, like a list's rows.
struct SelectableRow: ViewModifier {
  let model: TimesheetModel
  let item: TimesheetModel.Item
  /// Whether the timesheet has the keyboard.
  let isFocused: Bool
  /// Gives the timesheet the keyboard after a click.
  let focus: () -> Void

  func body(content: Content) -> some View {
    let selected = model.selection == item
    content
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
      .background {
        if selected {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(
              isFocused
                ? Color.accentColor
                : Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
        }
      }
      .environment(\.backgroundProminence, selected && isFocused ? .increased : .standard)
      .contentShape(Rectangle())
      .onTapGesture {
        model.selection = item
        focus()
      }
      .id(item)
  }
}

extension View {
  func selectableRow(
    _ model: TimesheetModel, _ item: TimesheetModel.Item, isFocused: Bool,
    focus: @escaping () -> Void
  ) -> some View {
    modifier(SelectableRow(model: model, item: item, isFocused: isFocused, focus: focus))
  }
}
