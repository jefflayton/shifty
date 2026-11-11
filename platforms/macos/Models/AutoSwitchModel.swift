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
/// A Teams meeting whose title has another project's keyword offers to
/// switch to it too, from when the call began, but waits for you rather
/// than counting down, since a meeting can name a project without being
/// for it. If you switch, the call's end offers to switch back. While a
/// call is on, where you work switches nothing.
@Observable final class AutoSwitchModel {
  /// What an offer is for.
  enum Kind: Equatable {
    /// Where you're working: it counts down, then switches.
    case place
    /// A meeting for another project. It waits for you.
    case meeting
    /// The meeting you switched for ended: back to what ran before. It
    /// waits for you too.
    case meetingOver
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
  }

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
  /// What ran before you switched for the call (nil if nothing did), and
  /// what you switched to: to offer back when it ends.
  @ObservationIgnored private var beforeMeeting: (target: ShiftStore.Target?, meeting: ShiftStore.Target)?
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
    // A countdown takes over from an offer to go back after a meeting.
    guard offer == nil || offer?.kind == .meetingOver, let candidate,
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
    guard on, let seen else { return endMeeting(at: min(ended ?? now, now), offerBack: on) }
    if meeting == nil {
      meeting = Meeting(title: seen.title, target: seen.target, since: now)
      offeredForMeeting = []
      beforeMeeting = nil
      candidate = nil
      // A place's countdown, or the last call's offer to go back.
      if offer?.kind != .meeting { set(offer: nil) }
    } else if meeting?.title != seen.title || meeting?.target != seen.target {
      meeting?.title = seen.title
      meeting?.target = seen.target
    }
    guard let meeting, tracking.running != nil || onShiftSince() != nil,
      let target = seen.target, target != tracking.runningTarget,
      !offeredForMeeting.contains(target)
    else { return }
    offeredForMeeting.insert(target)
    set(
      offer: Offer(
        target: target, name: name(of: target),
        from: tracking.running.map {
          tracking.label(project: $0.projectId, workspace: $0.workspaceId) ?? "No Project"
        },
        place: seen.title ?? "a Teams meeting", arrived: meeting.since, deadline: nil,
        kind: .meeting))
  }

  /// The call ended, at `end`: its offer goes, and if you switched for it,
  /// it offers to switch back, from then.
  private func endMeeting(at end: Date, offerBack: Bool) {
    guard let meeting else { return }
    self.meeting = nil
    offeredForMeeting = []
    let before = beforeMeeting
    beforeMeeting = nil
    if offer?.kind == .meeting { set(offer: nil) }
    guard offerBack, let before, let back = before.target, back != before.meeting,
      tracking.runningTarget == before.meeting
    else { return }
    set(
      offer: Offer(
        target: back, name: name(of: back), from: name(of: before.meeting),
        place: meeting.title.map { "\($0) ended" } ?? "The meeting ended", arrived: end,
        deadline: nil, kind: .meetingOver))
  }

  private func name(of target: ShiftStore.Target) -> String {
    tracking.label(project: target.project, workspace: target.workspace) ?? "Project"
  }

  /// Switches when the countdown runs out, drops a meeting's offer once
  /// you've switched some other way, and drops a switch shown long enough.
  func tick(now: Date = Date()) {
    if let offer, let deadline = offer.deadline, now >= deadline { switchNow(now: now) }
    if let offer, offer.kind != .place, offer.target == tracking.runningTarget { set(offer: nil) }
    if let switched, now >= switched.until { dismissSwitched() }
  }

  func switchNow(now: Date = Date()) {
    guard let offer else { return }
    candidate = nil
    set(offer: nil)
    if offer.kind == .meeting { beforeMeeting = (tracking.runningTarget, offer.target) }
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
