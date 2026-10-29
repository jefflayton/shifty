import Foundation

// A struct so edits through bindings mutate ShiftModel.breaks and trigger
// observation; a class would change in place and leave clockOut stale.
struct Interval: Identifiable, Codable, Equatable {
  var id = UUID()
  var inDate: Date
  var outDate: Date

  var isValid: Bool { ShiftTimes.isValid(self) }

  init(inDate: Date, outDate: Date) {
    self.inDate = inDate
    self.outDate = outDate
  }

  init() {
    let now = Date()
    self.init(inDate: now, outDate: now.addingTimeInterval(60 * 60))
  }
}
