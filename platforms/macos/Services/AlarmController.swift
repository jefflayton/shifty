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
    let timer: Timer
  }
  private var pending: [String: Pending] = [:]

  private var player: AVAudioPlayer?
  private var attentionRequestId = 0
  private var alarmWindow: NSWindow?
  private var activityToken: NSObjectProtocol?
  private let snoozeInterval: TimeInterval = 5 * 60

  @discardableResult
  func schedule(
    id: String = UUID().uuidString,
    title: String = "Session Complete",
    body: String = "Your timer has ended.",
    after seconds: TimeInterval
  ) -> String {
    cancel(id: id)

    let alarm = Alarm(
      id: id, title: title, body: body, fireDate: Date().addingTimeInterval(seconds))
    let timer = Timer.scheduledTimer(withTimeInterval: max(seconds, 0.01), repeats: false) { _ in
      Task { @MainActor in self.fire(id: id) }
    }
    pending[id] = Pending(alarm: alarm, timer: timer)
    scheduleBackstop(for: alarm, after: seconds)

    updateAppNap()
    return id
  }

  func cancel(id: String) {
    pending.removeValue(forKey: id)?.timer.invalidate()
    cancelBackstop(id: id)
    ringing.removeAll { $0.id == id }
    refreshRingingState()
  }

  func cancelAll() {
    pending.values.forEach { $0.timer.invalidate() }
    pending.removeAll()
    ringing.forEach { cancelBackstop(id: $0.id) }
    ringing.removeAll()
    refreshRingingState()
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
    schedule(id: id, title: a.title, body: a.body, after: snoozeInterval)
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
  private func scheduleBackstop(for alarm: Alarm, after seconds: TimeInterval) {
    let content = UNMutableNotificationContent()
    content.title = alarm.title
    content.body = alarm.body
    content.sound = .defaultCritical
    content.interruptionLevel = .timeSensitive

    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(seconds, 1), repeats: false)
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: "alarm-\(alarm.id)", content: content, trigger: trigger)
    )
  }

  private func cancelBackstop(id: String) {
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [
      id
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
