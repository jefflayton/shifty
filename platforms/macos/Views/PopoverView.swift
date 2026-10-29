import AppKit
import Sparkle
import SwiftUI

struct PopoverView: View {
  @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
  private let updater: SPUUpdater

  @Bindable var model: ShiftModel

  init(updater: SPUUpdater, model: ShiftModel) {
    self.updater = updater
    self.model = model

    // Create our view model for our CheckForUpdatesView
    self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
  }

  var body: some View {
    VStack(spacing: 12) {
      Text("Shifty")
        .font(.system(size: 20))

      // Labels right-aligned in the first column, controls left-aligned in
      // the second, so every row lines up.
      Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
        GridRow {
          FormLabel("Shift Length")
          HStack(spacing: 4) {
            TextField("Shift Length", value: $model.shiftLength, format: .number)
              .frame(width: 44)
            Text("hr")
          }
        }

        GridRow {
          FormLabel("Clock In")
          HStack {
            DatePicker("Clock In", selection: $model.clockInTime, displayedComponents: .hourAndMinute)
              .labelsHidden()
            Button("Now") { model.clockInTime = Date() }
          }
        }

        GridRow {
          FormLabel("Breaks")
          AddButton { model.breaks.append(Interval()) }
        }

        ForEach($model.breaks) { $brk in
          GridRow {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
            VStack(alignment: .leading, spacing: 4) {
              HStack(spacing: 6) {
                DatePicker("", selection: $brk.inDate, displayedComponents: .hourAndMinute)
                  .labelsHidden()
                Text("–")
                  .fixedSize()
                DatePicker("", selection: $brk.outDate, displayedComponents: .hourAndMinute)
                  .labelsHidden()
                Button {
                  let id = brk.id
                  model.breaks.removeAll { $0.id == id }
                } label: {
                  Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
              }
              if !brk.isValid {
                Label("Invalid break times", systemImage: "exclamationmark.triangle.fill")
                  .font(.caption)
                  .foregroundStyle(.red)
              }
            }
          }
        }

        GridRow {
          FormLabel("Clock Out")
          Text(model.clockOut, style: .time)
            .font(.title3.bold())
            .monospacedDigit()
        }
        .padding(.vertical, 4)

        AlarmsSection(model: model)
      }

      Divider()

      VStack(spacing: 0) {
        MenuRowButton("Check for Updates", action: updater.checkForUpdates)
          .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
        MenuRowButton("Quit Shifty") { NSApp.terminate(nil) }
      }
    }
    .padding()
    .frame(width: 380)
    .onAppear {
      // Nothing observes the clock, so check for a finished shift on open.
      model.rollOverIfStale()
    }
  }
}

/// A form label in the popover's label column.
struct FormLabel: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .bold()
      .gridColumnAlignment(.trailing)
  }
}

/// The popover's "+" for adding a break or alarm.
struct AddButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "plus.circle")
        // Match the Alarms menu's "+", which renders in the label color.
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// A full-width, menu-style row that highlights on hover.
struct MenuRowButton: View {
  let title: String
  let action: () -> Void
  @State private var hovered = false
  @Environment(\.isEnabled) private var isEnabled

  init(_ title: String, action: @escaping () -> Void) {
    self.title = title
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack {
        Text(title)
        Spacer()
      }
      .contentShape(Rectangle())
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        hovered && isEnabled ? Color.accentColor : .clear,
        in: RoundedRectangle(cornerRadius: 4)
      )
      .foregroundStyle(hovered && isEnabled ? .white : isEnabled ? .primary : .secondary)
    }
    .buttonStyle(.borderless)
    .onHover { hovered = $0 }
  }
}
