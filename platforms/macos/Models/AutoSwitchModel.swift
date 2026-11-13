import Foundation
import Observation

/// Moves the running timer to the project linked to where you're working.
/// Somewhere linked to another project, once you've stayed a while
/// (`Preferences.autoSwitchDelay`), it offers to switch and counts down
/// (`autoSwitchCountdown`); when the count runs out it switches, from when
/// you got there. You can switch at once or keep the current project.
/// With no timer running but on shift (not on a break), it offers to start
/// one the same way. Places nothing links to change nothing.
///
/// A Teams call offers to log it as a meeting, from when the call began:
/// an entry of its own, titled for the call, on the project a keyword in
/// its title names, else on the running timer's. It waits for you rather
/// than counting down, since a meeting can name a project without being
/// for it, unless `Preferences.meetingAutoLog` logs it at once. When the
/// call ends, so does the meeting, and what ran before picks up again,
/// with Undo. While a call is on, where you work switches nothing.
@Observable final class AutoSwitchModel {
  /// What an offer is for.
  enum Kind: Equatable {
    /// Where you're working: it counts down, then switches.
    case place
    /// A call, to log as a meeting. It waits for you.
    case meeting
  }

  /// An offer to switch, or to start a timer: counting down to it, or
  /// waiting for you (a meeting's).
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
    /// When it switches by itself; nil if it waits for you.
    var deadline: Date?
    var kind: Kind = .place
    /// A meeting's title, for its entry's note.
    var meeting: String? = nil
    /// The meeting goes on the project already running.
    var logsHere: Bool { from == name }
  }

  /// A Teams call going on, as the meeting watcher sees it.
  struct MeetingSeen: Equatable {
    /// What its windows call it.
    var title: String?
    /// The project a keyword in its title names.
    var target: ShiftStore.Target?
  }

  /// The call going on, and when it began.
  struct Meeting: Equatable {
    var title: String?
    var target: ShiftStore.Target?
    var since: Date
  }

  /// A switch just made, shown for a moment with Undo.
  struct Switched: Equatable {
    var name: String
    /// A timer started rather than switched.
    var started: Bool = false
    var place: String
    var until: Date
    /// The meeting logged, or (with `ended`) the one that just ended.
    var meeting: String? = nil
    /// The meeting ended with its call: `name` picked up again, or
    /// nothing if `stopped`.
    var ended: Bool = false
    var stopped: Bool = false
  }

  /// What a meeting is called when Teams' windows don't say.
  static let untitled = "Teams meeting"

  /// Where you were last outside Shifty, linked or not.
  struct Seen: Equatable {
    /// The repo, folder, or app's name.
    var name: String
    var dir: String?
    var app: String?
    /// Its window's title, which keywords are matched in.
    var title: String? = nil
    var place: ShiftStore.Place
  }

  private(set) var offer: Offer?
  private(set) var switched: Switched?
  /// The Teams call going on, if any.
  private(set) var meeting: Meeting?
  /// The last call's Teams window titles, as the meeting watcher read
  /// them: what a keyword can match, for the Meetings page.
  var callTitles: [String] = []
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
      self.seen?.place = try tracking.store.place(dir: seen.dir, app: seen.app, title: seen.title)
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
  /// Projects this call has offered, so each is offered once a call.
  @ObservationIgnored private var offeredForMeeting: Set<ShiftStore.Target> = []
  /// What ran before you logged the call as a meeting, and the project it
  /// went on: to go back to when it ends.
  private struct Before {
    /// Whether a timer ran, and for what (nil: no project).
    var running: Bool
    var target: ShiftStore.Target?
    var meeting: ShiftStore.Target
  }
  @ObservationIgnored private var beforeMeeting: Before?
  /// Runs when `offer` or `switched` changes, to show or hide them.
  @ObservationIgnored var didChange: (() -> Void)?
  /// When you clocked in, if you're on shift and not on a break: when a
  /// timer can start with none running.
  @ObservationIgnored var onShiftSince: () -> Date? = { nil }
  /// Whether personal tracking has the timer (your own project's, off the
  /// clock): it moves and stops it, so where you work offers nothing.
  @ObservationIgnored var yields: () -> Bool = { false }

  init(tracking: TrackingModel, preferences: Preferences) {
    self.tracking = tracking
    self.preferences = preferences
  }

  /// You're working at `place`, which is linked to `target`, or to nothing
  /// (nil): that changes nothing.
  func observe(_ target: ShiftStore.Target?, place: String, now: Date = Date()) {
    defer { tick(now: now) }
    guard preferences.autoSwitch, !yields(), tracking.running != nil || onShiftSince() != nil
    else {
      candidate = nil
      set(offer: nil)
      return
    }
    // A call's on: the meeting decides, not where you are.
    guard meeting == nil else {
      candidate = nil
      return
    }
    guard let target else { return }
    if target == tracking.runningTarget {
      candidate = nil
      dropPlaceOffer()
      return
    }
    if let until = kept[target], until > now { return }
    if candidate?.target != target {
      candidate = (target, place, now)
      dropPlaceOffer()
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

  /// A Teams call is on (`seen`), or not (nil), having `ended` then if
  /// that was before `now`. See the type's notes.
  func observeMeeting(_ seen: MeetingSeen?, ended: Date? = nil, now: Date = Date()) {
    defer { tick(now: now) }
    let on = preferences.autoSwitch && preferences.meetingSwitch
    guard on, let seen else { return endMeeting(at: min(ended ?? now, now), now: now) }
    if meeting == nil {
      meeting = Meeting(title: seen.title, target: seen.target, since: now)
      offeredForMeeting = []
      beforeMeeting = nil
      candidate = nil
      // A place's countdown.
      if offer?.kind != .meeting { set(offer: nil) }
    } else if meeting?.title != seen.title || meeting?.target != seen.target {
      meeting?.title = seen.title
      meeting?.target = seen.target
    }
    // Logged before Teams said what it's called: name it now.
    if let title = seen.title, beforeMeeting != nil, tracking.running?.isMeeting == true,
      tracking.running?.note == Self.untitled
    {
      tracking.retitleMeeting(title, now: now)
    }
    guard let meeting, tracking.running != nil || onShiftSince() != nil,
      let target = seen.target ?? tracking.runningTarget,
      !(tracking.running?.isMeeting == true && tracking.runningTarget == target),
      !offeredForMeeting.contains(target)
    else { return }
    offeredForMeeting.insert(target)
    let title = seen.title ?? Self.untitled
    set(
      offer: Offer(
        target: target, name: name(of: target),
        from: tracking.running.map {
          tracking.label(project: $0.projectId, workspace: $0.workspaceId) ?? "No Project"
        },
        place: title, arrived: meeting.since, deadline: nil, kind: .meeting, meeting: title))
    if preferences.meetingAutoLog { switchNow(now: now) }
  }

  /// The call ended, at `end`: its offer goes, and if you logged it as a
  /// meeting that still runs, the meeting ends then and what ran before
  /// picks up again, with Undo.
  private func endMeeting(at end: Date, now: Date) {
    guard let meeting else { return }
    self.meeting = nil
    offeredForMeeting = []
    let before = beforeMeeting
    beforeMeeting = nil
    if offer?.kind == .meeting { set(offer: nil) }
    guard let before, tracking.running?.isMeeting == true,
      tracking.runningTarget == before.meeting
    else { return }
    let title = tracking.running?.note ?? meeting.title ?? Self.untitled
    guard
      let undo = tracking.endMeeting(
        at: end, resume: before.running, back: before.target, now: now)
    else { return }
    self.undo = undo
    set(
      switched: Switched(
        name: before.target.map { name(of: $0) } ?? "No Project", place: title,
        until: now.addingTimeInterval(Self.undoSeconds), meeting: title, ended: true,
        stopped: !before.running))
  }

  private func name(of target: ShiftStore.Target) -> String {
    tracking.label(project: target.project, workspace: target.workspace) ?? "Project"
  }

  /// Switches when the countdown runs out, drops a meeting's offer once
  /// you've switched some other way, and drops a switch shown long enough.
  func tick(now: Date = Date()) {
    if let offer, let deadline = offer.deadline, now >= deadline { switchNow(now: now) }
    if let offer, offer.kind == .meeting, tracking.running?.isMeeting == true,
      offer.target == tracking.runningTarget
    {
      set(offer: nil)
    }
    if let switched, now >= switched.until { dismissSwitched() }
  }

  func switchNow(now: Date = Date()) {
    guard let offer else { return }
    candidate = nil
    set(offer: nil)
    let undo: (() -> Void)?
    if offer.kind == .meeting {
      // What ran before the call, not a meeting logged for it already.
      let before =
        beforeMeeting
        ?? Before(
          running: tracking.running != nil, target: tracking.runningTarget, meeting: offer.target)
      let since = offer.starts ? max(offer.arrived, onShiftSince() ?? offer.arrived) : offer.arrived
      undo = tracking.startMeeting(
        offer.target, title: offer.meeting ?? Self.untitled, since: since, now: now)
      if undo != nil {
        beforeMeeting = before
        beforeMeeting?.meeting = offer.target
      }
    } else if offer.starts {
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
        until: now.addingTimeInterval(Self.undoSeconds), meeting: offer.meeting))
  }

  /// Keeps the current project, and doesn't offer this one again for a
  /// while: a place's, for `keepSeconds`; a meeting's, for the rest of the
  /// call.
  func keep(now: Date = Date()) {
    guard let offer else { return }
    if offer.kind == .place {
      kept[offer.target] = now.addingTimeInterval(Self.keepSeconds)
      candidate = nil
    }
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

  /// Drops the offer if it's a place's: where you work leaves a meeting's
  /// alone.
  private func dropPlaceOffer() {
    if offer?.kind == .place { set(offer: nil) }
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
