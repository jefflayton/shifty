import Foundation

/// The database Shifty's CLI and TUI share, through the Zig store's C API
/// (shifty.h). Use it from the main thread only.
final class ShiftStore {
  struct Error: Swift.Error, CustomStringConvertible {
    let result: ShiftyResult
    var description: String { "store error \(result.rawValue)" }
  }

  struct Shift: Equatable {
    var id: UUID
    var clockIn: Date
    var lengthSeconds: Int64
  }

  struct Break: Equatable {
    var id: UUID
    var start: Date
    /// nil while it's running.
    var end: Date?
  }

  private let handle: OpaquePointer

  /// The shared database, or the one at `path` (tests use a temporary one).
  init(path: String? = nil) throws {
    var out: OpaquePointer?
    let result = path.map { shifty_store_open($0, &out) } ?? shifty_store_open(nil, &out)
    guard result == SHIFTY_OK, let out else { throw Error(result: result) }
    handle = out
  }

  deinit { shifty_store_close(handle) }

  /// Changes when another process writes.
  func dataVersion() throws -> Int64 {
    var v: Int64 = 0
    try check(shifty_data_version(handle, &v))
    return v
  }

  // MARK: Shifts

  func currentShift() throws -> Shift? {
    var s = ShiftyShift()
    let result = shifty_current_shift(handle, &s)
    if result == SHIFTY_NONE { return nil }
    try check(result)
    return Shift(id: UUID(s.id), clockIn: date(s.in_ts), lengthSeconds: s.target_secs)
  }

  /// Throws `SHIFTY_CONFLICT` if a shift is already open. With `presets`,
  /// the day's scheduled breaks go on it, as when the TUI or CLI clocks in;
  /// without, it starts empty for the caller to add its own.
  func startShift(at clockIn: Date, lengthSeconds: Int64, presets: Bool = false) throws -> UUID {
    var id = ShiftyId()
    try check(shifty_start_shift(handle, ts(clockIn), lengthSeconds, presets ? 1 : 0, &id))
    return UUID(id)
  }

  /// The breaks the scheduled presets put on a shift clocking in at
  /// `clockIn`.
  func scheduledBreaks(at clockIn: Date, lengthSeconds: Int64) throws -> [(start: Date, end: Date)] {
    try fill { buf, cap, count in
      shifty_scheduled_breaks(handle, ts(clockIn), lengthSeconds, buf, cap, count)
    }.map { (date($0.in_ts), date($0.out_ts)) }
  }

  func editShift(_ id: UUID, clockIn: Date, lengthSeconds: Int64, now: Date = Date()) throws {
    try check(shifty_edit_shift(handle, ShiftyId(id), ts(clockIn), lengthSeconds, ts(now)))
  }

  func endShift(now: Date = Date()) throws {
    let result = shifty_end_shift(handle, ts(now))
    if result != SHIFTY_NONE { try check(result) }
  }

  /// An ended shift recorded after the fact. Its length is the time between
  /// its ends.
  func addShift(start: Date, end: Date) throws -> UUID {
    var id = ShiftyId()
    try check(shifty_add_shift(handle, ts(start), ts(end), &id))
    return UUID(id)
  }

  /// Moves an ended shift's clock in and clock out.
  func setShiftTimes(_ id: UUID, start: Date, end: Date, now: Date = Date()) throws {
    try check(shifty_set_shift_times(handle, ShiftyId(id), ts(start), ts(end), ts(now)))
  }

  /// Deletes a shift and its breaks. Time tracked during it stays.
  func deleteShift(_ id: UUID, now: Date = Date()) throws {
    try check(shifty_delete_shift(handle, ShiftyId(id), ts(now)))
  }

  /// Brings back a deleted shift and the breaks deleted with it. Throws
  /// `SHIFTY_CONFLICT` if it was open and another shift is open now.
  func restoreShift(_ id: UUID, now: Date = Date()) throws {
    try check(shifty_restore_shift(handle, ShiftyId(id), ts(now)))
  }

  /// Stops the running entry where a planned break began after it started.
  /// Returns whether one was stopped.
  @discardableResult
  func stopForBreaks(now: Date = Date()) throws -> Bool {
    let result = shifty_stop_for_breaks(handle, ts(now))
    if result == SHIFTY_NONE { return false }
    try check(result)
    return true
  }

  /// Whether a shift nobody clocked out of was closed.
  func closeStaleShift(now: Date = Date()) throws -> Bool {
    let result = shifty_close_stale_shift(handle, ts(now))
    if result == SHIFTY_NONE { return false }
    try check(result)
    return true
  }

  // MARK: Breaks

  func breaks(of shift: UUID) throws -> [Break] {
    try fill { buf, cap, count in shifty_breaks(handle, ShiftyId(shift), buf, cap, count) }
      .map { Break(id: UUID($0.id), start: date($0.in_ts), end: $0.running != 0 ? nil : date($0.out_ts)) }
  }

  /// Creates or replaces a break under its own id.
  func putBreak(_ brk: Break, shift: UUID, now: Date = Date()) throws {
    try check(
      shifty_put_break(
        handle, ShiftyId(brk.id), ShiftyId(shift), ts(brk.start), brk.end.map(ts) ?? 0,
        brk.end == nil ? 1 : 0, ts(now)))
  }

  func deleteBreak(_ id: UUID, now: Date = Date()) throws {
    try check(shifty_delete_break(handle, ShiftyId(id), ts(now)))
  }

  // MARK: Alarms and settings

  func alarmRules() throws -> [ShiftyAlarmRule] {
    try fill { buf, cap, count in shifty_alarm_rules(handle, buf, cap, count) }
  }

  func putAlarmRule(_ rule: ShiftyAlarmRule, now: Date = Date()) throws {
    try check(shifty_put_alarm_rule(handle, rule, ts(now)))
  }

  func deleteAlarmRule(_ id: UUID, now: Date = Date()) throws {
    try check(shifty_delete_alarm_rule(handle, ShiftyId(id), ts(now)))
  }

  /// A break preset as the store keeps it. Times are nil where they don't
  /// apply to its kind.
  struct Preset: Decodable, Equatable {
    var id: UUID
    var name: String
    /// "scheduled" or "window".
    var kind: String
    var enabled: Bool
    var weekdays: Int
    var startSecs: Int64?
    var endSecs: Int64?
    var earliestSecs: Int64?
    var latestSecs: Int64?
    var minimumSecs: Int64?
    /// An SF Symbol name; nil for the default.
    var icon: String? = nil
    /// Whether starting and ending it offers the clock links. nil from a
    /// store older than icons.
    var clockLink: Bool? = nil
  }

  /// Break presets, windows (lunch) first.
  func breakPresets() throws -> [Preset] {
    try json([Preset]()) { shifty_break_presets_json(handle, $0, $1) }
  }

  /// `icon` nil (or empty) is the default.
  func putBreakPreset(
    _ preset: ShiftyBreakPreset, name: String, icon: String? = nil, now: Date = Date()
  ) throws {
    guard let icon, !icon.isEmpty else {
      return try check(shifty_put_break_preset(handle, preset, name, nil, ts(now)))
    }
    try icon.withCString { try check(shifty_put_break_preset(handle, preset, name, $0, ts(now))) }
  }

  /// Deletes a break preset and its alarms.
  func deleteBreakPreset(_ id: UUID, now: Date = Date()) throws {
    try check(shifty_delete_break_preset(handle, ShiftyId(id), ts(now)))
  }

  func setting(_ key: String) throws -> String? {
    var buf = [CChar](repeating: 0, count: 512)
    var len = 0
    var result = shifty_setting(handle, key, &buf, buf.count, &len)
    if result == SHIFTY_NONE { return nil }
    try check(result)
    if len > buf.count {
      buf = [CChar](repeating: 0, count: len)
      result = shifty_setting(handle, key, &buf, buf.count, &len)
      try check(result)
    }
    return String(decoding: buf[..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  /// nil removes the setting.
  func setSetting(_ key: String, _ value: String?, now: Date = Date()) throws {
    let result =
      value.map { shifty_set_setting(handle, key, $0, ts(now)) }
      ?? shifty_set_setting(handle, key, nil, ts(now))
    try check(result)
  }

  // MARK: Timesheet

  struct Timesheet: Decodable, Equatable {
    var entries: [Entry] = []
    var shifts: [SheetShift] = []
    var clients: [Client] = []
    var projects: [Project] = []
    var workspaces: [Workspace] = []
  }

  struct Entry: Decodable, Equatable, Identifiable {
    var id: UUID
    var projectId: UUID?
    var workspaceId: UUID?
    var inTs: Int64
    var outTs: Int64?
    var source: String
    var note: String?
    /// "work", or "meeting" for a call, whose note is its title. Older
    /// cores leave it out, which reads as work.
    var kind: String? = nil

    var start: Date { date(inTs) }
    /// nil while it's running.
    var end: Date? { outTs.map(date) }
    var isMeeting: Bool { kind == "meeting" }
  }

  /// A shift on the timesheet, clock in to clock out, with its breaks.
  struct SheetShift: Decodable, Equatable, Identifiable {
    var id: UUID
    var inTs: Int64
    var outTs: Int64?
    var targetSecs: Int64
    var breaks: [SheetBreak]

    var start: Date { date(inTs) }
    /// nil while you're on it.
    var end: Date? { outTs.map(date) }
    var length: TimeInterval { TimeInterval(targetSecs) }
  }

  struct SheetBreak: Decodable, Equatable, Identifiable {
    var id: UUID
    var inTs: Int64
    var outTs: Int64?

    var start: Date { date(inTs) }
    /// nil while you're on it.
    var end: Date? { outTs.map(date) }
  }

  struct Client: Decodable, Equatable, Identifiable {
    var id: UUID
    var name: String
  }

  struct Project: Decodable, Equatable, Identifiable {
    var id: UUID
    var clientId: UUID?
    var name: String
    var color: String?
  }

  struct Workspace: Decodable, Equatable, Identifiable {
    var id: UUID
    var projectId: UUID
    var name: String
  }

  /// The entries and shifts overlapping `range`, and the names they refer
  /// to.
  func timesheet(_ range: DateInterval) throws -> Timesheet {
    try json(Timesheet()) { shifty_timesheet_json(handle, ts(range.start), ts(range.end), $0, $1) }
  }

  /// How a week stands against the weekly goal.
  struct WeekGoal: Decodable, Equatable {
    var goalSecs: Int64
    var workedSecs: Int64
    var leftSecs: Int64
    var overSecs: Int64
    /// What the week comes to once the open shift reaches its clock out;
    /// nil off shift, or for a week that isn't now.
    var atClockOutSecs: Int64?
    /// When the open shift reaches the goal; nil off shift, for a week that
    /// isn't now, or once it's met.
    var meetsAt: Int64?

    var goal: TimeInterval { TimeInterval(goalSecs) }
    var worked: TimeInterval { TimeInterval(workedSecs) }
    var left: TimeInterval { TimeInterval(leftSecs) }
    var over: TimeInterval { TimeInterval(overSecs) }
    var isMet: Bool { workedSecs >= goalSecs }
    var metAt: Date? { meetsAt.map(date) }
    /// Still to work after today's clock out, 0 if the shift gets you there;
    /// nil off shift.
    var leftAfterClockOut: TimeInterval? {
      atClockOutSecs.map { TimeInterval(max(0, goalSecs - $0)) }
    }

    /// "Goal met", "Met at 3:40 PM", "1h 30m after today", or "5h 30m
    /// left", for the menu bar.
    var detail: String {
      if isMet { return "Goal met" }
      if let after = leftAfterClockOut {
        if after == 0, let at = metAt {
          return "Met at \(at.formatted(date: .omitted, time: .shortened))"
        }
        return "\(TimesheetFormat.duration(after)) after today"
      }
      return "\(TimesheetFormat.duration(left)) left"
    }

    var helpText: String {
      if isMet {
        return over >= 60
          ? "Weekly goal met, \(TimesheetFormat.duration(over)) over" : "Weekly goal met"
      }
      var text = "\(TimesheetFormat.duration(left)) left of your weekly goal"
      if let after = leftAfterClockOut {
        text +=
          after == 0
          ? ". Today's shift gets you there."
          : ". After today's clock out, \(TimesheetFormat.duration(after)) is still to go."
      }
      return text
    }
  }

  /// How the week starting at midnight `weekStart` stands against the
  /// weekly goal, today's open shift included; nil without a goal.
  func weekGoal(weekStart: Date, now: Date = Date()) throws -> WeekGoal? {
    var ptr: UnsafeMutablePointer<CChar>?
    var len = 0
    let result = shifty_week_goal_json(handle, ts(weekStart), ts(now), &ptr, &len)
    if result == SHIFTY_NONE { return nil }
    try check(result)
    defer { shifty_free(ptr, len) }
    guard let ptr else { return nil }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(WeekGoal.self, from: Data(bytes: ptr, count: len))
  }

  /// Time recorded after the fact. A workspace implies its project.
  func addEntry(
    project: UUID?, workspace: UUID?, start: Date, end: Date, note: String? = nil
  ) throws -> UUID {
    var out = ShiftyId()
    try withIds(project, workspace) { p, w in
      try check(shifty_add_entry(handle, p, w, ts(start), ts(end), note, &out))
    }
    return UUID(out)
  }

  /// A meeting recorded after the fact, titled `title`: worked time on its
  /// project, kept apart from other work.
  func addMeeting(project: UUID?, workspace: UUID?, start: Date, end: Date, title: String)
    throws -> UUID
  {
    var out = ShiftyId()
    try withIds(project, workspace) { p, w in
      try check(shifty_add_meeting(handle, p, w, ts(start), ts(end), title, &out))
    }
    return UUID(out)
  }

  /// Makes an entry a meeting, or plain work again.
  func setMeeting(_ id: UUID, _ meeting: Bool, now: Date = Date()) throws {
    try check(shifty_set_entry_kind(handle, ShiftyId(id), meeting ? 1 : 0, ts(now)))
  }

  /// Replaces an entry's project, times, and note. A nil `end` keeps a
  /// running entry running.
  func editEntry(
    _ id: UUID, project: UUID?, workspace: UUID?, start: Date, end: Date?, note: String?,
    now: Date = Date()
  ) throws {
    try withIds(project, workspace) { p, w in
      try check(
        shifty_edit_entry(
          handle, ShiftyId(id), p, w, ts(start), end.map(ts) ?? 0, end == nil ? 1 : 0, note,
          ts(now)))
    }
  }

  /// Starts tracking now, stopping the running entry and ending a break in
  /// progress. A workspace implies its project.
  @discardableResult
  func startEntry(project: UUID?, workspace: UUID?, note: String? = nil, now: Date = Date())
    throws -> UUID
  {
    var out = ShiftyId()
    try withIds(project, workspace) { p, w in
      try check(shifty_start_entry(handle, p, w, note, ts(now), &out))
    }
    return UUID(out)
  }

  /// Starts a meeting titled `title` at `start`, when the call began,
  /// stopping the running entry there. A workspace implies its project.
  @discardableResult
  func startMeeting(project: UUID?, workspace: UUID?, title: String, at start: Date) throws
    -> UUID
  {
    var out = ShiftyId()
    try withIds(project, workspace) { p, w in
      try check(shifty_start_meeting(handle, p, w, title, ts(start), &out))
    }
    return UUID(out)
  }

  /// Stops the running entry. Returns whether one was running.
  @discardableResult
  func stopEntry(now: Date = Date()) throws -> Bool {
    let result = shifty_stop_entry(handle, ts(now))
    if result == SHIFTY_NONE { return false }
    try check(result)
    return true
  }

  /// Brings back a deleted entry as it was. Throws `SHIFTY_CONFLICT` if it
  /// was running and another entry runs now.
  func restoreEntry(_ id: UUID, now: Date = Date()) throws {
    try check(shifty_restore_entry(handle, ShiftyId(id), ts(now)))
  }

  func deleteEntry(_ id: UUID, now: Date = Date()) throws {
    try check(shifty_delete_entry(handle, ShiftyId(id), ts(now)))
  }

  func createProject(name: String, client: UUID? = nil, color: String? = nil, now: Date = Date())
    throws -> UUID
  {
    var out = ShiftyId()
    try withIds(client, nil) { c, _ in
      try check(shifty_create_project(handle, name, c, color, ts(now), &out))
    }
    return UUID(out)
  }

  // MARK: Projects

  struct Projects: Decodable, Equatable {
    var projects: [Project] = []
    var clients: [Client] = []
    var workspaces: [Workspace] = []
    var usage: [Usage] = []
  }

  /// How much a project has been used, all time.
  struct Usage: Decodable, Equatable {
    var projectId: UUID
    var entries: Int
    var seconds: Int64
    var lastTs: Int64

    /// When its latest entry started.
    var lastUsed: Date { date(lastTs) }
  }

  /// Every active project with its usage, a running entry counted up to
  /// `now`.
  func projects(now: Date = Date()) throws -> Projects {
    try json(Projects()) { shifty_projects_json(handle, ts(now), $0, $1) }
  }

  /// Replaces a project's name, client, and color (`#rrggbb`, nil for none).
  func editProject(_ id: UUID, name: String, client: UUID?, color: String?, now: Date = Date())
    throws
  {
    try withIds(client, nil) { c, _ in
      try check(shifty_edit_project(handle, ShiftyId(id), name, c, color, ts(now)))
    }
  }

  /// Deletes a project and its workspaces. Its time stays, unassigned.
  func deleteProject(_ id: UUID, now: Date = Date()) throws {
    try check(shifty_delete_project(handle, ShiftyId(id), ts(now)))
  }

  // MARK: Places and links

  /// What linked a place to its project.
  enum Via: String, Decodable {
    case situ, git, folder, app, keyword
  }

  /// A project to track: a project, and maybe one of its workspaces.
  struct Target: Hashable {
    var project: UUID
    var workspace: UUID?
  }

  /// Where you're working (a directory, an app) and what it's linked to.
  struct Place: Decodable, Equatable {
    var via: Via?
    var projectId: UUID?
    var workspaceId: UUID?
    /// The Situ or git repo's top.
    var root: String?
    /// The git remote, normalized: `github.com/owner/repo`.
    var remote: String?
    /// The linked folder that matched.
    var folder: String?
    /// The keyword in the window's title that picked the project, when
    /// `via` is `.keyword`.
    var keyword: String?
    /// How many projects it could have been: more than one where a repo
    /// links to several.
    var choices: Int = 0
    /// A Situ repo with ids to link by.
    var situ: Bool = false

    var target: Target? { projectId.map { Target(project: $0, workspace: workspaceId) } }
  }

  /// The place for `dir` (absolute) in the app `bundleID`, whose window is
  /// titled `title`: a keyword in it picks the project.
  func place(dir: String?, app bundleID: String?, title: String? = nil) throws -> Place {
    try json(Place()) { out, len in
      withOptionalCString(dir) { d in
        withOptionalCString(bundleID) { b in
          withOptionalCString(title) { t in shifty_place_json(handle, d, b, t, out, len) }
        }
      }
    }
  }

  /// Links the repo or folder `dir` is in to `target`: by its Situ ids,
  /// else its git remote, else its path. Returns which.
  @discardableResult
  func link(dir: String, to target: Target, now: Date = Date()) throws -> Via {
    var via: Int32 = 0
    try withIds(target.workspace, nil) { w, _ in
      try check(shifty_link_dir(handle, dir, ShiftyId(target.project), w, ts(now), &via))
    }
    return [Via.situ, .git, .folder, .app, .keyword][Int(via)]
  }

  func link(app bundleID: String, to target: Target, now: Date = Date()) throws {
    try withIds(target.workspace, nil) { w, _ in
      try check(shifty_link_app(handle, bundleID, ShiftyId(target.project), w, ts(now)))
    }
  }

  /// Links a keyword: a window titled with it (a Rex session or tab, an
  /// editor) is `target`'s. Kept trimmed and lowercase.
  func link(keyword: String, to target: Target, now: Date = Date()) throws {
    try withIds(target.workspace, nil) { w, _ in
      try check(shifty_link_keyword(handle, keyword, ShiftyId(target.project), w, ts(now)))
    }
  }

  /// Another tool's id pointed at a project.
  struct Link: Decodable, Equatable, Hashable, Identifiable {
    var provider: String
    var kind: String
    var externalId: String
    var projectId: UUID
    var workspaceId: UUID?

    var id: String { "\(provider)/\(kind)/\(externalId)/\(projectId)" }
    var target: Target { Target(project: projectId, workspace: workspaceId) }
  }

  func links() throws -> [Link] {
    try json([Link]()) { shifty_links_json(handle, $0, $1) }
  }

  /// Removes `link`: its id's link to its project, not to others.
  func unlink(_ link: Link, now: Date = Date()) throws {
    try withIds(link.projectId, nil) { p, _ in
      try check(shifty_unlink(handle, link.provider, link.kind, link.externalId, p, ts(now)))
    }
  }

  /// A shell's directory, as the prompt hook (`shifty hook`) last recorded.
  struct Spot: Decodable, Equatable {
    var ts: Int64
    /// The shell's, or Neovim's.
    var pid: Int32
    /// `$__CFBundleIdentifier` and `$TERM_PROGRAM`, either maybe empty.
    var bundle: String
    var term: String
    var dir: String

    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
  }

  /// The hook's record, newest first.
  func spots() throws -> [Spot] {
    try json([Spot]()) { shifty_here_json(handle, $0, $1) }
  }

  /// Where the hook's record is, to watch it.
  func spotsPath() throws -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    try check(shifty_here_path(handle, &buf, buf.count))
    return String(cString: buf)
  }

  /// The Rex tab and session you're on, as the `rex do` script
  /// (`shifty hook rex`) last told the store.
  struct RexFocus: Decodable, Equatable {
    var ts: Int64
    /// The host's label from `rex hosts`; empty for this Mac's server.
    var server: String
    var session: String
    var window: String
    /// "tab - session", as Rex titles its window.
    var title: String
  }

  /// What the Rex script last recorded, if it did in the day before `now`.
  func rexFocus(now: Date = Date()) throws -> RexFocus? {
    try json(RexFocus?.none) { shifty_rex_json(handle, ts(now), $0, $1) }
  }

  /// The Lua script for `rex do`, calling `cli rex`.
  static func rexScript(cli: String) -> String {
    var ptr: UnsafeMutablePointer<CChar>?
    var len = 0
    guard shifty_rex_script(cli, &ptr, &len) == SHIFTY_OK, let ptr else { return "" }
    defer { shifty_free(ptr, len) }
    return String(decoding: UnsafeRawBufferPointer(start: ptr, count: len), as: UTF8.self)
  }

  private func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let s else { return body(nil) }
    return s.withCString(body)
  }

  /// Passes optional ids to C as pointers, nil as NULL.
  private func withIds(
    _ a: UUID?, _ b: UUID?,
    _ body: (UnsafePointer<ShiftyId>?, UnsafePointer<ShiftyId>?) throws -> Void
  ) throws {
    var ia = a.map(ShiftyId.init)
    var ib = b.map(ShiftyId.init)
    try withOptionalPointer(&ia) { pa in
      try withOptionalPointer(&ib) { pb in try body(pa, pb) }
    }
  }

  private func withOptionalPointer<T>(
    _ value: inout T?, _ body: (UnsafePointer<T>?) throws -> Void
  ) throws {
    if value == nil { return try body(nil) }
    try withUnsafePointer(to: &value!) { try body($0) }
  }

  // MARK: Helpers

  private func check(_ result: ShiftyResult) throws {
    if result != SHIFTY_OK { throw Error(result: result) }
  }

  /// Calls a C function that returns JSON, and decodes it; `empty` if it
  /// returns nothing.
  private func json<T: Decodable>(
    _ empty: T,
    _ call: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<Int>) ->
      ShiftyResult
  ) throws -> T {
    var ptr: UnsafeMutablePointer<CChar>?
    var len = 0
    try check(call(&ptr, &len))
    defer { shifty_free(ptr, len) }
    guard let ptr else { return empty }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(T.self, from: Data(bytes: ptr, count: len))
  }

  /// Calls a C list function, growing the buffer until everything fits.
  private func fill<T>(
    _ call: (UnsafeMutablePointer<T>, Int, UnsafeMutablePointer<Int>) -> ShiftyResult
  ) throws -> [T] {
    var cap = 16
    while true {
      let buf = UnsafeMutablePointer<T>.allocate(capacity: cap)
      defer { buf.deallocate() }
      var count = 0
      try check(call(buf, cap, &count))
      if count <= cap { return Array(UnsafeBufferPointer(start: buf, count: count)) }
      cap = count
    }
  }
}

private func ts(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970.rounded(.down)) }
private func date(_ ts: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

extension UUID {
  init(_ id: ShiftyId) { self.init(uuid: id.bytes) }
}

extension ShiftyId {
  init(_ uuid: UUID) { self.init(bytes: uuid.uuid) }
}
