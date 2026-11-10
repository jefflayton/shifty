import Foundation
import Observation

/// Moves the running timer to the project linked to where you're working.
/// Somewhere linked to another project, once you've stayed a while
/// (`Preferences.autoSwitchDelay`), it offers to switch and counts down
/// (`autoSwitchCountdown`); when the count runs out it switches, from when
/// you got there. You can switch at once or keep the current project.
/// With no timer running but on shift (not on a break), it offers to start
/// one the same way. Places nothing links to change nothing.
@Observable final class AutoSwitchModel {
  /// An offer counting down to a switch, or to starting a timer.
  struct Offer: Equatable {
    var target: ShiftStore.Target
    /// The project switched to, and from: nil when it starts a timer.
    var name: String
    var from: String?
    var starts: Bool { from == nil }
    /// Where you are: a repo, a folder, or an app.
    var place: String
    /// When you got there, which the new entry starts at.
    var arrived: Date
    var deadline: Date
  }

  /// A switch just made, shown for a moment with Undo.
  struct Switched: Equatable {
    var name: String
    /// A timer started rather than switched.
    var started: Bool = false
    var place: String
    var until: Date
  }

  /// Where you were last outside Shifty, linked or not.
  struct Seen: Equatable {
    /// The repo, folder, or app's name.
    var name: String
    var dir: String?
    var app: String?
    var place: ShiftStore.Place
  }

  private(set) var offer: Offer?
  private(set) var switched: Switched?
  /// Set by the focus watcher.
  var seen: Seen?

  /// Where you are, if nothing links it and a timer for a project runs:
  /// what the menu bar offers to link to that project.
  var unlinked: Seen? {
    guard preferences.autoSwitch, let seen, seen.place.target == nil,
      tracking.runningTarget != nil
    else { return nil }
    return seen
  }

  /// Links where you are (its repo or folder, else its app) to the running
  /// timer's project.
  func linkSeen() {
    guard let seen = unlinked, let target = tracking.runningTarget else { return }
    do {
      if let dir = seen.dir {
        try tracking.store.link(dir: seen.place.root ?? dir, to: target)
      } else if let app = seen.app {
        try tracking.store.link(app: app, to: target)
      }
      self.seen?.place = try tracking.store.place(dir: seen.dir, app: seen.app)
    } catch {
      log("link here:", error)
    }
  }

  /// How long a switch stays up for undoing, and how long Keep holds off
  /// offering the same project again.
  static let undoSeconds: TimeInterval = 8
  static let keepSeconds: TimeInterval = 30 * 60

  @ObservationIgnored let tracking: TrackingModel
  @ObservationIgnored let preferences: Preferences
  /// Where you've been since it last matched the timer.
  @ObservationIgnored private var candidate: (target: ShiftStore.Target, place: String, since: Date)?
  /// Projects you kept the timer from, until when.
  @ObservationIgnored private var kept: [ShiftStore.Target: Date] = [:]
  @ObservationIgnored private var undo: (() -> Void)?
  /// Runs when `offer` or `switched` changes, to show or hide them.
  @ObservationIgnored var didChange: (() -> Void)?
  /// When you clocked in, if you're on shift and not on a break: when a
  /// timer can start with none running.
  @ObservationIgnored var onShiftSince: () -> Date? = { nil }

  init(tracking: TrackingModel, preferences: Preferences) {
    self.tracking = tracking
    self.preferences = preferences
  }

  /// You're working at `place`, which is linked to `target`, or to nothing
  /// (nil): that changes nothing.
  func observe(_ target: ShiftStore.Target?, place: String, now: Date = Date()) {
    defer { tick(now: now) }
    guard preferences.autoSwitch, tracking.running != nil || onShiftSince() != nil else {
      candidate = nil
      set(offer: nil)
      return
    }
    guard let target else { return }
    if target == tracking.runningTarget {
      candidate = nil
      set(offer: nil)
      return
    }
    if let until = kept[target], until > now { return }
    if candidate?.target != target {
      candidate = (target, place, now)
      set(offer: nil)
    }
    guard offer == nil, let candidate,
      now.timeIntervalSince(candidate.since) >= preferences.autoSwitchDelay
    else { return }
    set(
      offer: Offer(
        target: target,
        name: tracking.label(project: target.project, workspace: target.workspace) ?? "Project",
        from: tracking.running.map {
          tracking.label(project: $0.projectId, workspace: $0.workspaceId) ?? "No Project"
        },
        place: candidate.place, arrived: candidate.since,
        deadline: now.addingTimeInterval(preferences.autoSwitchCountdown)))
  }

  /// Switches when the countdown runs out, and drops a switch shown long
  /// enough.
  func tick(now: Date = Date()) {
    if let offer, now >= offer.deadline { switchNow(now: now) }
    if let switched, now >= switched.until { dismissSwitched() }
  }

  func switchNow(now: Date = Date()) {
    guard let offer else { return }
    candidate = nil
    set(offer: nil)
    let undo: (() -> Void)?
    if offer.starts {
      // Not from before you clocked in.
      let since = max(offer.arrived, onShiftSince() ?? offer.arrived)
      undo = tracking.start(offer.target, since: since, now: now)
    } else {
      undo = tracking.switchTo(offer.target, since: offer.arrived, now: now)
    }
    guard let undo else { return }
    self.undo = undo
    set(
      switched: Switched(
        name: offer.name, started: offer.starts, place: offer.place,
        until: now.addingTimeInterval(Self.undoSeconds)))
  }

  /// Keeps the current project, and doesn't offer this one again for a
  /// while.
  func keep(now: Date = Date()) {
    guard let offer else { return }
    kept[offer.target] = now.addingTimeInterval(Self.keepSeconds)
    candidate = nil
    set(offer: nil)
  }

  func undoSwitch() {
    undo?()
    dismissSwitched()
  }

  func dismissSwitched() {
    undo = nil
    set(switched: nil)
  }

  private func set(offer new: Offer?) {
    guard new != offer else { return }
    offer = new
    didChange?()
  }

  private func set(switched new: Switched?) {
    guard new != switched else { return }
    switched = new
    didChange?()
  }
}
