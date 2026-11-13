import Foundation

/// Tracks your own projects by themselves, with no clocking in: the
/// projects of an organization with no shift (`ShiftStore.Tracking.auto`).
/// Off the clock, staying in one a while (`Preferences.autoSwitchDelay`)
/// starts its timer, from when you got there, and staying in another moves
/// it. It stops when you go idle (`Preferences.personalIdle`), at when you
/// last touched a key or the mouse; when the Mac sleeps or locks; when you
/// clock in; and when you stay in a project on the shift. Places nothing
/// links to change nothing. Its time is personal: never worked, and never
/// toward the day's length or the weekly goal.
///
/// Off the clock it runs any personal timer, whoever started it, and
/// leaves a work timer to auto-switch.
final class PersonalTracker {
  let tracking: TrackingModel
  let preferences: Preferences
  /// Whether you're clocked in, on a break or not.
  var isClockedIn: () -> Bool = { false }

  /// The personal project you're in, and since when: it starts or moves
  /// the timer once you've stayed.
  private(set) var candidate: (target: ShiftStore.Target, since: Date)?
  /// When you went to a project on the shift, with a personal timer
  /// running: it stops once you've stayed, from then.
  private(set) var atWork: Date?
  /// Whether you were clocked in when it last looked, to stop a personal
  /// timer once when you clock in, and not one you start on the clock.
  /// Nil before it first looks.
  private var wasClockedIn: Bool?

  init(tracking: TrackingModel, preferences: Preferences) {
    self.tracking = tracking
    self.preferences = preferences
  }

  /// Whether a personal timer runs off the clock: this moves and stops it,
  /// rather than auto-switch.
  var hasTimer: Bool {
    preferences.personalTracking && !isClockedIn() && runsPersonal
  }

  /// Whether the running timer is for a personal project, and not a
  /// meeting.
  private var runsPersonal: Bool {
    guard let running = tracking.running, !running.isMeeting else { return false }
    return tracking.isPersonal(running.projectId)
  }

  /// You're somewhere linked to `target`, or to nothing (nil), and it's
  /// been `idle` since you touched a key or the mouse.
  func observe(_ target: ShiftStore.Target?, idle: TimeInterval = 0, now: Date = Date()) {
    let clockedIn = isClockedIn()
    defer { wasClockedIn = clockedIn }
    guard preferences.personalTracking else { return reset() }
    if clockedIn {
      reset()
      // Your own time ends where the shift's begins.
      if wasClockedIn == false { stop(at: now, now: now) }
      return
    }
    if idle >= preferences.personalIdle {
      reset()
      return stop(at: now.addingTimeInterval(-idle), now: now)
    }
    // Nowhere linked, like a browser: what runs keeps running.
    guard let target else { return reset() }

    if tracking.isPersonal(target.project) {
      atWork = nil
      if runsPersonal && tracking.runningTarget == target {
        candidate = nil
        return
      }
      if candidate?.target != target { candidate = (target, now) }
      guard let candidate, now.timeIntervalSince(candidate.since) >= preferences.autoSwitchDelay
      else { return }
      self.candidate = nil
      if tracking.running == nil {
        _ = tracking.start(target, since: candidate.since, now: now)
      } else if runsPersonal {
        _ = tracking.switchTo(target, since: candidate.since, now: now)
      }
      // A work timer runs: auto-switch offers to move it.
    } else {
      // A project on the shift, off the clock: not tracked by itself.
      candidate = nil
      guard runsPersonal else {
        atWork = nil
        return
      }
      let since = atWork ?? now
      atWork = since
      if now.timeIntervalSince(since) >= preferences.autoSwitchDelay {
        atWork = nil
        stop(at: since, now: now)
      }
    }
  }

  /// The Mac is going to sleep, or locked: personal time stops now.
  func pause(now: Date = Date()) {
    reset()
    guard !isClockedIn() else { return }
    stop(at: now, now: now)
  }

  /// Stops a personal timer at `at` (after it started, not past `now`).
  private func stop(at: Date, now: Date) {
    guard runsPersonal, let running = tracking.running else { return }
    tracking.stop(now: min(now, max(at, running.start.addingTimeInterval(1))))
  }

  private func reset() {
    candidate = nil
    atWork = nil
  }
}
