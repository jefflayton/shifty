import SwiftUI

/// The shift from clock in to clock out: work in the accent color, breaks as
/// gaps, time already worked solid and time ahead faded, and a dot for now.
/// The lunch window, while lunch is still to come, is a band behind it; once
/// you've gone, the gap that was lunch is tinted. Past clock out on a shift
/// you're still on, the bar runs on to now, the time over in its own color.
struct ShiftBar: View {
  let clockIn: Date
  let clockOut: Date
  /// Fractions (0...1) of the shift spent on break.
  let breaks: [ClosedRange<Double>]
  /// Fractions of the shift lunch has to start in, or nil.
  var lunch: ClosedRange<Double>? = nil
  /// Fractions of the shift you were (or are) at lunch, or nil.
  var lunchBreak: ClosedRange<Double>? = nil
  let now: Date
  /// Draw time past clock out up to `now`, for a shift you're clocked in to.
  var showsOver = false

  private let height: CGFloat = 6
  private let dot: CGFloat = 12

  private var progress: Double {
    let total = clockOut.timeIntervalSince(clockIn)
    guard total > 0 else { return 0 }
    return min(max(now.timeIntervalSince(clockIn) / total, 0), 1)
  }

  /// The share of the bar the shift itself takes: 1, or less once you're
  /// over and the rest is overtime.
  private var shiftShare: Double {
    guard showsOver, now > clockOut else { return 1 }
    let total = now.timeIntervalSince(clockIn)
    guard total > 0 else { return 1 }
    return clockOut.timeIntervalSince(clockIn) / total
  }

  var body: some View {
    GeometryReader { geo in
      let full = geo.size.width
      // The shift's own width; everything below is laid out in it.
      let width = full * CGFloat(shiftShare)
      ZStack(alignment: .leading) {
        if let lunch {
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(LunchStyle.color.opacity(0.35))
            .frame(width: max(2, width * CGFloat(lunch.upperBound - lunch.lowerBound)), height: dot)
            .offset(x: width * CGFloat(lunch.lowerBound))
            .help("Lunch window")
        }
        Capsule().fill(.quaternary).frame(height: height)
        if let lunchBreak {
          Capsule()
            .fill(LunchStyle.color.opacity(0.6))
            .frame(
              width: max(height, width * CGFloat(lunchBreak.upperBound - lunchBreak.lowerBound)),
              height: height
            )
            .offset(x: width * CGFloat(lunchBreak.lowerBound))
            .help("Lunch")
        }

        // Work: the whole shift, minus break gaps
        workShape(width: width)
          .fill(Color.accentColor.opacity(0.35))
        workShape(width: width)
          .fill(Color.accentColor)
          .mask(alignment: .leading) {
            Rectangle().frame(width: width * CGFloat(progress))
          }

        if shiftShare < 1 {
          Capsule()
            .fill(OverStyle.color)
            .frame(width: max(height, full - width), height: height)
            .offset(x: width)
            .help("Past clock out")
        }

        if progress > 0 && progress < 1 {
          Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .frame(width: dot, height: dot)
            .offset(x: width * CGFloat(progress) - dot / 2)
            .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        }
      }
    }
    .frame(height: dot)
    .accessibilityElement()
    .accessibilityLabel("Shift progress")
    .accessibilityValue(
      shiftShare < 1
        ? "\(ShiftSummary.duration(now.timeIntervalSince(clockOut))) over"
        : "\(Int(progress * 100)) percent")
  }

  /// One rounded segment per stretch of work between breaks.
  private func workShape(width: CGFloat) -> Path {
    var path = Path()
    var start = 0.0
    for span in breaks + [1...1] {
      if span.lowerBound > start {
        let rect = CGRect(
          x: width * CGFloat(start), y: (dot - height) / 2,
          width: width * CGFloat(span.lowerBound - start), height: height)
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: height / 2, height: height / 2))
      }
      start = span.upperBound
    }
    return path
  }
}

enum OverStyle {
  /// Time past a shift's length, wherever it's drawn. Not the lunch window's
  /// orange, and not red, which means something's wrong.
  static let color = Color.purple
}
