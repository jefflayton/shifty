import Foundation
import Observation

@Observable class ShiftModel {
  var clockInTime = Date()
  var shiftLength = 8.0
  var breaks: [Interval] = []
  var alarms: [AlarmRule] = []
  /// When the break in progress started, if you're on one. It counts up to
  /// now until it ends and joins `breaks`.
  var breakStart: Date?

  var isOnBreak: Bool { breakStart != nil }

  /// A shift whose clock out is this far in the past is over.
  static let staleAfter: TimeInterval = 12 * 60 * 60

  var clockOut: Date { clockOut(now: Date()) }

  /// Clock out if the break in progress (if any) ended at `now`.
  func clockOut(now: Date) -> Date {
    let intervals = breaks(now: now).filter(\.isValid).map { brk in
      let (start, end) = ShiftTimes.anchor(brk, clockIn: clockInTime)
      return ShiftInterval(
        in_ts: Int64(start.timeIntervalSince1970),
        out_ts: Int64(end.timeIntervalSince1970)
      )
    }

    let outTs = intervals.withUnsafeBufferPointer { buf in
      clockIn(
        Int64(shiftLength * 60 * 60),
        Int64(clockInTime.timeIntervalSince1970),
        buf.baseAddress,
        buf.count
      )
    }
    return Date(timeIntervalSince1970: TimeInterval(outTs))
  }

  /// The saved breaks, plus the one in progress as if it ended at `now`.
  func breaks(now: Date) -> [Interval] {
    guard let breakStart else { return breaks }
    return breaks + [Interval(inDate: breakStart, outDate: max(now, breakStart))]
  }

  func startBreak(now: Date = Date()) {
    if breakStart == nil { breakStart = now }
  }

  /// Saves the break in progress. One ended within the minute it started
  /// (most likely a mis-click) is dropped.
  func endBreak(now: Date = Date()) {
    guard let start = breakStart else { return }
    breakStart = nil
    let brk = Interval(inDate: start, outDate: now)
    if brk.isValid { breaks.append(brk) }
  }

  /// The clock-in picker only edits hour and minute, so a menu bar app left
  /// running overnight would compute today's shift on yesterday's date and
  /// every alarm would already be in the past. Once a shift is stale, start
  /// the next one at the same time of day today, without yesterday's breaks.
  func rollOverIfStale(now: Date = Date(), calendar: Calendar = .current) {
    // A break left running this long was forgotten, not taken.
    if let breakStart, breakStart < now.addingTimeInterval(-Self.staleAfter) {
      self.breakStart = nil
    }
    guard clockOut(now: now) < now.addingTimeInterval(-Self.staleAfter) else { return }
    let today = ShiftTimes.on(now, timeOf: clockInTime, calendar: calendar)
    // Only assign real changes: every set notifies observers.
    if today != clockInTime { clockInTime = today }
    if !breaks.isEmpty { breaks = [] }
  }

  // MARK: Persistence

  private struct Snapshot: Codable {
    var clockInTime: Date
    var shiftLength: Double
    var breaks: [Interval]
    var alarms: [AlarmRule]
    var breakStart: Date?
  }

  static let defaultsKey = "shift.v1"

  static func load(from defaults: UserDefaults = .standard) -> ShiftModel {
    let model = ShiftModel()
    guard let data = defaults.data(forKey: defaultsKey),
      let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
    else { return model }
    model.clockInTime = snap.clockInTime
    model.shiftLength = snap.shiftLength
    model.breaks = snap.breaks
    model.alarms = snap.alarms
    model.breakStart = snap.breakStart
    return model
  }

  func save(to defaults: UserDefaults = .standard) {
    let snap = Snapshot(
      clockInTime: clockInTime, shiftLength: shiftLength, breaks: breaks, alarms: alarms,
      breakStart: breakStart)
    if let data = try? JSONEncoder().encode(snap) {
      defaults.set(data, forKey: Self.defaultsKey)
    }
  }
}
