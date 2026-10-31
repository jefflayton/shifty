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

  /// Throws `SHIFTY_CONFLICT` if a shift is already open.
  func startShift(at clockIn: Date, lengthSeconds: Int64) throws -> UUID {
    var id = ShiftyId()
    try check(shifty_start_shift(handle, ts(clockIn), lengthSeconds, &id))
    return UUID(id)
  }

  func editShift(_ id: UUID, clockIn: Date, lengthSeconds: Int64, now: Date = Date()) throws {
    try check(shifty_edit_shift(handle, ShiftyId(id), ts(clockIn), lengthSeconds, ts(now)))
  }

  func endShift(now: Date = Date()) throws {
    let result = shifty_end_shift(handle, ts(now))
    if result != SHIFTY_NONE { try check(result) }
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

    var start: Date { date(inTs) }
    /// nil while it's running.
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

  /// The entries overlapping `range`, and the names they refer to.
  func timesheet(_ range: DateInterval) throws -> Timesheet {
    try json(Timesheet()) { shifty_timesheet_json(handle, ts(range.start), ts(range.end), $0, $1) }
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

  /// Stops the running entry. Returns whether one was running.
  @discardableResult
  func stopEntry(now: Date = Date()) throws -> Bool {
    let result = shifty_stop_entry(handle, ts(now))
    if result == SHIFTY_NONE { return false }
    try check(result)
    return true
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
