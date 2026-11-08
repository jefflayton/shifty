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

          let clockOut = controller.canClockOut(alarm)
          HStack(spacing: 10) {
            Button("Snooze") { controller.snooze(id: alarm.id) }
              .keyboardShortcut("s", modifiers: [])

            // When it can clock out, that's the main action.
            if clockOut {
              Button("Stop") { controller.stop(id: alarm.id) }
                .keyboardShortcut(.cancelAction)
            } else {
              Button("Stop") { controller.stop(id: alarm.id) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
          }
          .controlSize(.large)

          if clockOut {
            Button {
              controller.clockOut(id: alarm.id)
            } label: {
              Label(
                "Clock Out",
                systemImage: alarm.link == nil ? "clock.badge.checkmark" : "arrow.up.forward.square"
              )
              .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .help(clockOutHelp(alarm))
          }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
      }
    }

    .padding(20)
    .frame(width: 320)
  }

  private func clockOutHelp(_ alarm: AlarmController.Alarm) -> String {
    let ends = alarm.clocksOut && controller.isClockedIn()
    let site = alarm.link.map { $0.host() ?? $0.absoluteString }
    switch (ends, site) {
    case (true, let site?): return "End the shift, open \(site), and stop the alarm"
    case (true, nil): return "End the shift and stop the alarm"
    case (false, let site?): return "Open \(site) and stop the alarm"
    case (false, nil): return "Stop the alarm"
    }
  }
}
