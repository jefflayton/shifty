import AVFoundation
import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AlarmController: ObservableObject {
  static let shared = AlarmController()

  struct Alarm: Identifiable {
    let id: String
    let title: String
    var body: String
    var fireDate: Date
  }

  @Published private(set) var ringing: [Alarm] = []

  private struct Pending {
    let alarm: Alarm
    var timer: Timer
    let snoozed: Bool
  }
  private var pending: [String: Pending] = [:]

  private var player: AVAudioPlayer?
  private var attentionRequestId = 0
  private var alarmWindow: NSWindow?
  private var activityToken: NSObjectProtocol?
  private let snoozeInterval: TimeInterval = 5 * 60
  /// The notification backstop only matters if the app isn't running, so it
  /// trails the in-app alarm, which cancels it on firing.
  private let backstopDelay: TimeInterval = 5
  private static let soundName = "alarm.caf"

  init() {
    // Timers don't advance while the Mac sleeps; re-arm them on wake so
    // alarms due during sleep ring right away instead of hours late.
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { _ in
      Task { @MainActor in AlarmController.shared.rearmTimers() }
    }
  }

  /// Backstops from a previous run would ring at stale times; the scheduler
  /// re-creates current ones after launch.
  func removeStaleBackstops() {
    UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
  }

  func schedule(id: String, title: String, body: String, at date: Date) {
    schedule(id: id, title: title, body: body, at: date, snoozed: false)
  }

  private func schedule(id: String, title: String, body: String, at date: Date, snoozed: Bool) {
    cancel(id: id)

    let alarm = Alarm(id: id, title: title, body: body, fireDate: date)
    pending[id] = Pending(alarm: alarm, timer: makeTimer(id: id, at: date), snoozed: snoozed)
    scheduleBackstop(for: alarm)

    updateAppNap()
  }

  func pendingAlarm(id: String) -> Alarm? { pending[id]?.alarm }

  func isSnoozed(id: String) -> Bool { pending[id]?.snoozed ?? false }

  /// Stops the alarm whether it's pending or ringing.
  func cancel(id: String) {
    cancelPending(id: id)
    ringing.removeAll { $0.id == id }
    refreshRingingState()
  }

  /// Drops a pending alarm but leaves it ringing if it already is.
  func cancelPending(id: String) {
    pending.removeValue(forKey: id)?.timer.invalidate()
    cancelBackstop(id: id)
    updateAppNap()
  }

  /// Cancels every alarm, pending or ringing, whose id isn't in `ids`.
  func cancelAll(except ids: Set<String>) {
    let stale = Set(pending.keys).union(ringing.map(\.id)).subtracting(ids)
    stale.forEach(cancel(id:))
  }

  private func makeTimer(id: String, at date: Date) -> Timer {
    let timer = Timer(fire: max(date, Date()), interval: 0, repeats: false) { _ in
      Task { @MainActor in self.fire(id: id) }
    }
    // .common so alarms still fire while a menu is being tracked
    RunLoop.main.add(timer, forMode: .common)
    return timer
  }

  private func rearmTimers() {
    for (id, p) in pending {
      p.timer.invalidate()
      pending[id]?.timer = makeTimer(id: id, at: p.alarm.fireDate)
    }
  }

  private func fire(id: String) {
    guard let p = pending.removeValue(forKey: id) else { return }
    cancelBackstop(id: id)
    ringing.append(p.alarm)
    startSoundIfNeeded()
    bounceDockIfNeeded()
    showOrFrontWindow()
    updateAppNap()
  }

  func stop(id: String) {
    ringing.removeAll { $0.id == id }
    refreshRingingState()
  }

  func snooze(id: String) {
    guard let a = ringing.first(where: { $0.id == id }) else { return }
    ringing.removeAll { $0.id == id }
    refreshRingingState()
    schedule(
      id: id, title: a.title, body: a.body, at: Date().addingTimeInterval(snoozeInterval),
      snoozed: true)
  }

  private func refreshRingingState() {
    if ringing.isEmpty {
      stopSound()
      cancelDockBounce()
      closeWindow()
    }
    updateAppNap()
  }

  // Sound
  private func startSoundIfNeeded() {
    guard player == nil else { return }
    guard let url = Bundle.main.url(forResource: "alarm", withExtension: "caf") else {
      NSSound.beep()
      return
    }

    do {
      let p = try AVAudioPlayer(contentsOf: url)
      p.numberOfLoops = -1
      p.volume = 1.0
      p.prepareToPlay()
      p.play()
      player = p
    } catch {
      NSSound.beep()
    }
  }

  private func stopSound() {
    player?.stop()
    player = nil
  }

  // Dock Bounce
  private func bounceDockIfNeeded() {
    guard attentionRequestId == 0 else { return }
    attentionRequestId = NSApp.requestUserAttention(.criticalRequest)
  }

  private func cancelDockBounce() {
    if attentionRequestId != 0 {
      NSApp.cancelUserAttentionRequest(attentionRequestId)
      attentionRequestId = 0
    }
  }

  // App Nap
  private func updateAppNap() {
    let needed = !pending.isEmpty || !ringing.isEmpty
    if needed, activityToken == nil {
      activityToken = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep],
        reason: "Pending session alarm"
      )
    } else if !needed, let token = activityToken {
      ProcessInfo.processInfo.endActivity(token)
      activityToken = nil
    }
  }

  // Backstop
  private func scheduleBackstop(for alarm: Alarm) {
    let content = UNMutableNotificationContent()
    content.title = alarm.title
    content.body = alarm.body
    content.sound = UNNotificationSound(named: UNNotificationSoundName(Self.soundName))
    content.interruptionLevel = .timeSensitive

    // A calendar trigger names a wall-clock time, so unlike an interval
    // trigger it isn't thrown off by sleep or rescheduling.
    let date = max(alarm.fireDate, Date()).addingTimeInterval(backstopDelay)
    let components = Calendar.current.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: date)
    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: backstopId(alarm.id), content: content, trigger: trigger)
    )
  }

  private func backstopId(_ id: String) -> String { "alarm-\(id)" }

  private func cancelBackstop(id: String) {
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
      backstopId(id)
    ])
  }

  // Window Update
  private func showOrFrontWindow() {
    if alarmWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
        styleMask: [.titled, .fullSizeContentView],
        backing: .buffered,
        defer: false
      )
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.isMovableByWindowBackground = true
      window.level = .screenSaver
      window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      window.isReleasedWhenClosed = false
      window.contentView = NSHostingView(rootView: AlarmStackView(controller: self))
      window.center()
      alarmWindow = window

      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      window.orderFrontRegardless()
    }
  }

  private func closeWindow() {
    alarmWindow?.close()
    alarmWindow = nil
  }
}
