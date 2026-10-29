import SwiftUI

/// The shift from clock in to clock out: work in the accent color, breaks as
/// gaps, time already worked solid and time ahead faded, and a dot for now.
struct ShiftBar: View {
  let clockIn: Date
  let clockOut: Date
  /// Fractions (0...1) of the shift spent on break.
  let breaks: [ClosedRange<Double>]
  let now: Date

  private let height: CGFloat = 6

  private var progress: Double {
    let total = clockOut.timeIntervalSince(clockIn)
    guard total > 0 else { return 0 }
    return min(max(now.timeIntervalSince(clockIn) / total, 0), 1)
  }

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(.quaternary).frame(height: height)

        // Work: the whole shift, minus break gaps
        workShape(width: width)
          .fill(Color.accentColor.opacity(0.35))
        workShape(width: width)
          .fill(Color.accentColor)
          .mask(alignment: .leading) {
            Rectangle().frame(width: width * progress)
          }

        if progress > 0 && progress < 1 {
          Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .frame(width: height + 6, height: height + 6)
            .offset(x: width * progress - (height + 6) / 2)
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        }
      }
    }
    .frame(height: height + 6)
    .accessibilityElement()
    .accessibilityLabel("Shift progress")
    .accessibilityValue("\(Int(progress * 100)) percent")
  }

  /// One rounded segment per stretch of work between breaks.
  private func workShape(width: CGFloat) -> Path {
    var path = Path()
    var start = 0.0
    for span in breaks + [1...1] {
      if span.lowerBound > start {
        let rect = CGRect(
          x: width * start, y: 3, width: width * (span.lowerBound - start), height: height)
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: height / 2, height: height / 2))
      }
      start = span.upperBound
    }
    return path
  }
}
