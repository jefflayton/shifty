import Foundation
import Observation

@Observable class ShiftModel {
  var clockInTime = Date()
  var shiftLength = 8.0
  var breaks: [Interval] = []
  var alarms: [AlarmRule] = []

  /// A shift whose clock out is this far in the past is over.
  static let staleAfter: TimeInterval = 12 * 60 * 60

  var clockOut: Date {
    let intervals = breaks.filter(\.isValid).map { brk in
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

  /// The clock-in picker only edits hour and minute, so a menu bar app left
  /// running overnight would compute today's shift on yesterday's date and
  /// every alarm would already be in the past. Once a shift is stale, start
  /// the next one at the same time of day today, without yesterday's breaks.
  func rollOverIfStale(now: Date = Date(), calendar: Calendar = .current) {
    guard clockOut < now.addingTimeInterval(-Self.staleAfter) else { return }
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
    return model
  }

  func save(to defaults: UserDefaults = .standard) {
    let snap = Snapshot(
      clockInTime: clockInTime, shiftLength: shiftLength, breaks: breaks, alarms: alarms)
    if let data = try? JSONEncoder().encode(snap) {
      defaults.set(data, forKey: Self.defaultsKey)
    }
  }
}
