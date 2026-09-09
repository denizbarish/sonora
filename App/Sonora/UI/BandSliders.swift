import SonoraDSP
import SwiftUI

/// The ten band sliders, laid out under the curve.
struct BandSliders: View {

    @Binding var gains: [Double]

    var body: some View {
        // Ten columns of 26 plus nine gaps of 4 is 296 points, which fits
        // inside the panel's 360 with its padding.
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(EqualizerBand.graphicFrequencies.enumerated()), id: \.offset) { index, frequency in
                VStack(spacing: 4) {
                    Slider(
                        value: binding(for: index),
                        in: EqualizerBand.gainRange
                    )
                    // Order matters here. `rotationEffect` changes what is
                    // drawn, not what is laid out: the slider still occupies
                    // its natural horizontal length. So the first frame sets
                    // that length, the rotation stands it upright, and the
                    // second frame reserves the upright footprint. Without the
                    // second one every slider claims 104 points of width and
                    // the row runs off both sides of the panel.
                    .frame(width: 104)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 22, height: 104)
                    .accessibilityLabel(Self.label(for: frequency))
                    .accessibilityValue(Self.value(for: gains[safe: index] ?? 0))

                    Text(Self.shortLabel(for: frequency))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
                .frame(width: 26)
            }
        }
    }

    /// Guards the index, because a settings file with the wrong band count
    /// would otherwise crash the interface rather than showing something wrong.
    private func binding(for index: Int) -> Binding<Double> {
        Binding(
            get: { gains[safe: index] ?? 0 },
            set: { newValue in
                guard gains.indices.contains(index) else { return }
                gains[index] = newValue
            }
        )
    }

    private static func shortLabel(for frequency: Double) -> String {
        frequency >= 1_000
            ? "\(Int(frequency / 1_000))k"
            : "\(Int(frequency))"
    }

    private static func label(for frequency: Double) -> String {
        frequency >= 1_000
            ? "\(Int(frequency / 1_000)) kilohertz band"
            : "\(Int(frequency)) hertz band"
    }

    private static func value(for gain: Double) -> String {
        String(format: "%+.1f decibels", gain)
    }
}

extension Array {
    /// Index access that returns nil rather than trapping. The interface reads
    /// band gains that ultimately came off disk, and a wrong count there should
    /// look wrong, not crash.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
