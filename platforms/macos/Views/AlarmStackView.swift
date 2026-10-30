import SwiftUI

struct AlarmStackView: View {
  @ObservedObject var controller: AlarmController

  var body: some View {
    VStack(spacing: 14) {
      ForEach(controller.ringing) { alarm in
        VStack(spacing: 10) {
          Image(systemName: "bell.fill")
            .font(.system(size: 32))
            .symbolEffect(.pulse)
            .foregroundStyle(.orange)

          Text(alarm.title)
            .font(.headline)
          Text(alarm.body)
            .font(.subheadline)
            .foregroundStyle(.secondary)

          HStack(spacing: 10) {
            Button("Snooze") { controller.snooze(id: alarm.id) }
              .keyboardShortcut("s", modifiers: [])

            // With a link, clocking out is the main action.
            if alarm.link != nil {
              Button("Stop") { controller.stop(id: alarm.id) }
                .keyboardShortcut(.cancelAction)
            } else {
              Button("Stop") { controller.stop(id: alarm.id) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
          }
          .controlSize(.large)

          if let link = alarm.link {
            Button {
              controller.clockOut(id: alarm.id)
            } label: {
              Label("Clock Out", systemImage: "arrow.up.forward.square")
                .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help("Open \(link.host() ?? link.absoluteString) and stop the alarm")
          }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
      }
    }

    .padding(20)
    .frame(width: 320)
  }
}
