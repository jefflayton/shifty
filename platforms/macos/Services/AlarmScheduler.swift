import Foundation
import Observation

/// Keeps AlarmController in step with the shift. Any change that moves clock
/// out (a new break, a different clock in) reschedules the alarms that
/// follow it, and every change is saved. During a break, clock out keeps
/// moving, so the alarms that follow it wait for the break to end.
@MainActor
final class AlarmScheduler {
  private let model: ShiftModel
  private let preferences: Preferences
  private let controller: AlarmController

  init(model: ShiftModel, preferences: Preferences, controller: AlarmController) {
    self.model = model
    self.preferences = preferences
    self.controller = controller
    controller.removeStaleBackstops()
    observe()
  }

  /// Runs `sync` now and again after any model property it read changes.
  private func observe() {
    withObservationTracking {
      sync()
    } onChange: { [weak self] in
      // onChange fires before the new value is stored; sync after it lands.
      Task { @MainActor in self?.observe() }
    }
  }

  func sync(now: Date = Date()) {
    model.rollOverIfStale(now: now)
    model.save()

    let clockOut = model.clockOut(now: now)
    let body =
      if let breakStart = model.breakStart {
        "On break since \(breakStart.formatted(date: .omitted, time: .shortened))"
      } else {
        "Clock out at \(clockOut.formatted(date: .omitted, time: .shortened))"
      }
    var live = Set<String>()

    for rule in model.alarms where rule.isEnabled {
      let id = rule.id.uuidString
      live.insert(id)
      apply(
        id: id, title: rule.title, body: body, link: preferences.clockOutLink,
        fireDate: rule.fireDate(clockIn: model.clockInTime, clockOut: clockOut),
        held: model.isOnBreak && rule.followsClockOut, now: now)
    }

    // Until you've had lunch. Going on a break counts, so it stops ringing.
    if let lunch = model.lunch(preferences.lunch, now: now), let remind = lunch.remind {
      live.insert(Self.lunchID)
      apply(
        id: Self.lunchID, title: "Time for lunch",
        body: "Start lunch by \(lunch.closes.formatted(date: .omitted, time: .shortened))",
        link: nil, fireDate: remind, held: false, now: now)
    }

    // Deleted or disabled rules
    controller.cancelAll(except: live)
  }

  static let lunchID = "lunch"

  /// Brings one alarm's pending notification in line with its fire date.
  private func apply(
    id: String, title: String, body: String, link: URL?, fireDate: Date, held: Bool, now: Date
  ) {
    let pending = controller.pendingAlarm(id: id)
    let snoozed = controller.isSnoozed(id: id)
    let action = AlarmPlanner.action(
      fireDate: fireDate, pending: pending?.fireDate, snoozed: snoozed, held: held, now: now)
    switch action {
    case .schedule(let date):
      controller.schedule(id: id, title: title, body: body, link: link, at: date)
    case .cancelPending:
      controller.cancelPending(id: id)
    case .keep:
      // Same time, but clock out (in the body), the title, or the link may
      // have changed.
      if let pending, !snoozed,
        pending.title != title || pending.body != body || pending.link != link
      {
        controller.schedule(id: id, title: title, body: body, link: link, at: fireDate)
      }
    }
  }
}
