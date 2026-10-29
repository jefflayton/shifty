import Foundation

// A struct so edits through bindings mutate ShiftModel.breaks and trigger
// observation; a class would change in place and leave clockOut stale.
struct Interval: Identifiable {
  let id = UUID()
  var inDate: Date
  var outDate: Date

  var isValid: Bool { inDate < outDate }

  init() {
    let calendar = Calendar.current
    self.inDate = Date()
    if let newDate = calendar.date(byAdding: .hour, value: 1, to: self.inDate) {
      self.outDate = newDate
    } else {
      self.outDate = Date()
    }
  }
}
