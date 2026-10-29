import AppKit
import Sparkle
import SwiftUI
import UserNotifications

struct PopoverView: View {
  @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
  private let updater: SPUUpdater

  @Bindable var model: ShiftModel
  @State var quitHovered = false

  init(updater: SPUUpdater, model: ShiftModel) {
    self.updater = updater
    self.model = model

    // Create our view model for our CheckForUpdatesView
    self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
  }

  var body: some View {
    VStack {
      Text("Shifty")
        .font(.system(size: 20))
        .padding(.vertical, 5)

      HStack {
        Text("Shift Length").bold()
        TextField("Shift Length", value: $model.shiftLength, format: .number)
          .frame(width: 36)
        Text(" hr")
      }

      HStack {
        DatePicker("Clock In", selection: $model.clockInTime, displayedComponents: .hourAndMinute)
        Button("Now") { model.clockInTime = Date() }
      }

      HStack {
        Text("Breaks").bold()
        Button(action: { model.breaks.append(Interval()) }) {
          Image(systemName: "plus")
        }
      }
      .padding(.vertical, 4)

      ForEach($model.breaks) { $brk in
        HStack {
          DatePicker("", selection: $brk.inDate, displayedComponents: .hourAndMinute)
            .labelsHidden()
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
          HStack {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Invalid break times")
          }
          .foregroundStyle(.red)
        }
      }

      HStack {
        Text("Clock Out:").bold()
        Text(model.clockOut, style: .time)
      }.padding()

      AlarmsSection(model: model)

      Divider()
      Button("Check for Updates", action: updater.checkForUpdates)
        .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
      Button {
        NSApp.terminate(nil)
      } label: {
        HStack {
          Text("Quit Shifty")
          Spacer()
        }
        .buttonStyle(.borderless)
        .tint(.clear)
        .contentShape(Rectangle())
        .padding(.horizontal, 8)
        .padding(.vertical, 4)

        .background(
          quitHovered ? Color.accentColor : .clear,
          in: RoundedRectangle(
            cornerRadius:
              4)
        )
        .foregroundStyle(quitHovered ? .white : .primary)
      }
      .buttonStyle(.borderless)
      .onHover { quitHovered = $0 }
      .padding(.horizontal, 4)
    }
    .padding()
    .frame(width: 300)
    .onAppear(perform: {
      // Nothing observes the clock, so check for a finished shift on open.
      model.rollOverIfStale()
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
        granted, error in
        if granted {
          log("Permission granted")
        } else if let error = error {
          log(error.localizedDescription)
        }
      }
    })
  }

}
