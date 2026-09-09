import SonoraDSP
import SwiftUI

/// The equalizer's response, drawn behind the band controls.
///
/// Takes points rather than a model so it stays a pure function of its input,
/// which makes it previewable and keeps it from reaching the engine.
///
/// It shows the same quantity the band controls set, in the same place, so the
/// two would merge into one another if they were drawn with the same weight.
/// They are deliberately not: the controls are opaque and hard edged, the curve
/// is a thin line over a low wash. Same hue, so it is clearly the same thing;
/// much less presence, so it reads as the layer behind rather than as more
/// controls.
struct CurveView: View {

    let points: [CurvePoint]

    /// Vertical range in decibels. Matches the controls' range so the curve and
    /// the handles line up.
    let range: ClosedRange<Double>

    /// Points of clearance at the top and bottom. A handle at full scale has
    /// its centre half a handle short of the edge, so the curve has to stop
    /// short by the same amount or a full boost draws higher than the handle
    /// that caused it.
    let verticalInset: Double

    var body: some View {
        Canvas { context, size in
            guard points.count > 1 else { return }

            let zero = size.height / 2

            var path = Path()
            for (index, point) in points.enumerated() {
                let x = size.width * Double(index) / Double(points.count - 1)
                let y = yPosition(for: Double(point.decibels), in: size.height)

                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            // The area between the curve and the zero line, so the eye reads
            // "this much gain" without tracing the line. A flat wash rather
            // than a top-to-bottom gradient, because a gradient keyed to the
            // canvas fades a cut away to nothing while leaving a boost solid,
            // and a cut is not less real than a boost.
            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: zero))
            fill.addLine(to: CGPoint(x: 0, y: zero))
            fill.closeSubpath()

            context.fill(fill, with: .color(.accentColor.opacity(0.14)))

            context.stroke(
                path,
                with: .color(.accentColor.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
        .accessibilityHidden(true)
    }

    /// Maps decibels onto the canvas with 0 dB pinned to the middle, so the
    /// curve is measured from the same line the band fills grow out of.
    private func yPosition(for decibels: Double, in height: Double) -> Double {
        let clamped = min(max(decibels, range.lowerBound), range.upperBound)
        let magnitude = max(abs(range.lowerBound), abs(range.upperBound))
        guard magnitude > 0 else { return height / 2 }

        let travel = height / 2 - verticalInset
        return height / 2 - (clamped / magnitude) * travel
    }
}
