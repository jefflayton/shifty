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
  /// Wakes a sync once a break starts or ends, so a break alarm moves on to
  /// the next break. Nothing in the model changes when time passes.
  private var nextBoundary: Timer?

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

    let lunch = model.lunch(preferences.lunch, now: now)
    let breaks = model.anchoredBreaks()

    for rule in model.alarms where rule.isEnabled {
      let id = rule.id.uuidString
      // A lunch alarm with no lunch to come (none needed, had it, or on a
      // break), or a break alarm with no break ahead, is dropped, so one
      // ringing stops when you go.
      guard
        let fireDate = rule.fireDate(
          clockIn: model.clockInTime, clockOut: clockOut, lunch: lunch, breaks: breaks, now: now)
      else { continue }
      live.insert(id)
      if rule.isBreak, let brk = Self.breakFor(rule, breaks: breaks, now: now) {
        apply(
          id: id, title: rule.title,
          body: "Break \((brk.start..<brk.end).formatted(.interval.hour().minute()))",
          link: nil, fireDate: fireDate, held: false, now: now)
      } else if rule.isLunch, let lunch {
        apply(
          id: id, title: rule.title,
          body: "Start lunch by \(lunch.closes.formatted(date: .omitted, time: .shortened))",
          link: nil, fireDate: fireDate, held: false, now: now)
      } else {
        apply(
          id: id, title: rule.title, body: body, link: preferences.clockOutLink,
          fireDate: fireDate, held: model.isOnBreak && rule.followsClockOut, now: now)
      }
    }

    // Deleted or disabled rules
    controller.cancelAll(except: live)

    scheduleNextBoundary(breaks: breaks, now: now)
  }

  /// The break a break alarm is for: the next to start, or to end.
  private static func breakFor(_ rule: AlarmRule, breaks: [(start: Date, end: Date)], now: Date)
    -> (start: Date, end: Date)?
  {
    if case .beforeBreak = rule.trigger { return breaks.first { $0.start > now } }
    return breaks.first { $0.end > now }
  }

  private func scheduleNextBoundary(breaks: [(start: Date, end: Date)], now: Date) {
    nextBoundary?.invalidate()
    nextBoundary = nil
    guard model.alarms.contains(where: { $0.isEnabled && $0.isBreak }),
      let next = breaks.flatMap({ [$0.start, $0.end] }).filter({ $0 > now }).min()
    else { return }
    let timer = Timer(fire: next.addingTimeInterval(1), interval: 0, repeats: false) {
      [weak self] _ in
      Task { @MainActor in self?.sync() }
    }
    timer.tolerance = 5
    RunLoop.main.add(timer, forMode: .common)
    nextBoundary = timer
  }

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
