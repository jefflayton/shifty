import Foundation
import Observation

@Observable class ShiftModel {
  var clockInTime = Date()
  var shiftLength = 8.0
  var lunchMins = 0.0
  var breaks: [Interval] = []
}
