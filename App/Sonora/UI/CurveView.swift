import SonoraDSP
import SwiftUI

/// The equalizer's response, drawn behind the band sliders.
///
/// Takes points rather than a model so it stays a pure function of its input,
/// which makes it previewable and keeps it from reaching the engine.
struct CurveView: View {

    let points: [CurvePoint]

    /// Vertical range in decibels. Matches the sliders' range so the curve and
    /// the handles line up.
    let range: ClosedRange<Double>

    var body: some View {
        Canvas { context, size in
            guard points.count > 1 else { return }

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

            // A filled area under the line reads as "this much gain" at a
            // glance, where a bare line reads as a graph to be studied.
            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            fill.addLine(to: CGPoint(x: 0, y: size.height / 2))
            fill.closeSubpath()

            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [.accentColor.opacity(0.35), .accentColor.opacity(0.05)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            context.stroke(path, with: .color(.accentColor), lineWidth: 2)

            // The zero line, so a boost is visibly distinct from a cut.
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: size.height / 2))
            zero.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(
                zero,
                with: .color(.secondary.opacity(0.3)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
        }
        .accessibilityHidden(true)
    }

    private func yPosition(for decibels: Double, in height: Double) -> Double {
        let clamped = min(max(decibels, range.lowerBound), range.upperBound)
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return height / 2 }

        let normalised = (clamped - range.lowerBound) / span
        return height * (1 - normalised)
    }
}
