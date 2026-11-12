import Foundation
import Observation

/// One-off breaks for the Breaks page: a break on one day only, like the
/// dentist on Thursday from 2 to 3. The store puts one on that day's shift
/// when you clock in, or straight away if you're on it and it's still to
/// come.
@Observable final class OneOffBreaksModel {
  /// The shown week's and the ones still to come, earliest first.
  private(set) var breaks: [ShiftStore.OneOffBreak] = []
  private(set) var error: String?

  @ObservationIgnored let store: ShiftStore
  @ObservationIgnored let calendar: Calendar
  /// Called after a change that can reach today's shift, so the menu bar
  /// and timesheet read it.
  @ObservationIgnored var didChange: (() -> Void)?
  @ObservationIgnored private var week: DateInterval?

  /// How far ahead the page lists them.
  static let ahead: TimeInterval = 60 * 24 * 60 * 60
  /// The longest the store takes.
  static let maxLength: TimeInterval = 12 * 60 * 60

  init(store: ShiftStore, calendar: Calendar = .current) {
    self.store = store
    self.calendar = calendar
  }

  /// A one-off break being added or edited.
  struct Draft: Equatable {
    var id = UUID()
    var name = ""
    var icon: String? = nil
    var start: Date
    var end: Date
    var clockLink = false

    /// A new one: an hour from the next whole hour on `day`, or tomorrow's
    /// if that's over.
    static func new(on day: Date, now: Date, calendar: Calendar = .current) -> Draft {
      let base = calendar.isDate(day, inSameDayAs: now) ? now : calendar.startOfDay(for: day)
      var start = calendar.nextDate(
        after: base.addingTimeInterval(-1), matching: DateComponents(minute: 0, second: 0),
        matchingPolicy: .nextTime) ?? base
      if !calendar.isDate(day, inSameDayAs: now) {
        start = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? start
      }
      return Draft(start: start, end: start.addingTimeInterval(3600))
    }

    init(id: UUID = UUID(), name: String = "", icon: String? = nil, start: Date, end: Date,
      clockLink: Bool = false)
    {
      self.id = id
      self.name = name
      self.icon = icon
      self.start = start
      self.end = end
      self.clockLink = clockLink
    }

    init(_ brk: ShiftStore.OneOffBreak) {
      self.init(
        id: brk.id, name: brk.name, icon: brk.icon, start: brk.start, end: brk.end,
        clockLink: brk.clockLink)
    }

    /// What's wrong with it, or nil when the store will take it.
    func problem(now: Date) -> String? {
      if end <= start { return "Ends before it starts" }
      if end.timeIntervalSince(start) > OneOffBreaksModel.maxLength { return "Longer than 12 hours" }
      if end <= now { return "That's over already" }
      return nil
    }
  }

  /// Reloads the ones overlapping `week`, and every one still to come.
  func reload(week: DateInterval? = nil, now: Date = Date()) {
    if let week { self.week = week }
    let today = calendar.startOfDay(for: now)
    let from = min(self.week?.start ?? today, today)
    let to = max(self.week?.end ?? today, now.addingTimeInterval(Self.ahead))
    do {
      let fresh = try store.oneOffBreaks(DateInterval(start: from, end: to))
      if fresh != breaks { breaks = fresh }
      error = nil
    } catch {
      self.error = "Couldn't read one-off breaks."
      log("one-off breaks:", error)
    }
  }

  /// The ones that haven't ended.
  func upcoming(now: Date) -> [ShiftStore.OneOffBreak] { breaks.filter { $0.end > now } }

  /// The ones that start on `day`.
  func breaks(on day: Date) -> [ShiftStore.OneOffBreak] {
    breaks.filter { calendar.isDate($0.start, inSameDayAs: day) }
  }

  /// Saves a new or changed one. False, with `error` set, if it can't be.
  @discardableResult
  func save(_ draft: Draft, now: Date = Date()) -> Bool {
    if let problem = draft.problem(now: now) {
      error = problem
      return false
    }
    let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      try store.putOneOffBreak(
        id: draft.id, name: name.isEmpty ? "Break" : name, icon: draft.icon, start: draft.start,
        end: draft.end, clockLink: draft.clockLink, now: now)
    } catch {
      self.error = "Couldn't save the break."
      log("save one-off break:", error)
      return false
    }
    reload(now: now)
    didChange?()
    return true
  }

  func delete(_ id: UUID, now: Date = Date()) {
    do {
      try store.deleteOneOffBreak(id, now: now)
    } catch {
      self.error = "Couldn't delete the break."
      log("delete one-off break:", error)
      return
    }
    reload(now: now)
    didChange?()
  }

  func clearError() { error = nil }

  /// The one-off a break on a shift is, if any: it ends when the one-off
  /// does and starts when it does or later (clock in cuts one that started
  /// before it).
  func match(start: Date, end: Date?) -> ShiftStore.OneOffBreak? {
    guard let end else { return nil }
    return breaks.first { abs($0.end.timeIntervalSince(end)) < 60 && start >= $0.start.addingTimeInterval(-59) && start < $0.end }
  }
}
