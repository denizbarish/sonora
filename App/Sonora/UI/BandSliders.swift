import SonoraDSP
import SwiftUI

/// The ten band controls, laid out under the curve.
struct BandSliders: View {

    @Binding var gains: [Double]

    var body: some View {
        // The columns are flexible and the control inside each one is a fixed
        // 26 points, so the row spans the panel's content width and lines its
        // outer edges up with the preamp slider above it. Ten controls take
        // 260 of the 332 points available, leaving 72 for the gaps, which is
        // more than the 4 points the row needs to fit.
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(EqualizerBand.graphicFrequencies.enumerated()), id: \.offset) { index, frequency in
                VStack(spacing: 4) {
                    BandControl(frequency: frequency, gain: binding(for: index))

                    Text(Self.shortLabel(for: frequency))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
                .frame(maxWidth: .infinity)
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
}

extension Array {
    /// Index access that returns nil rather than trapping. The interface reads
    /// band gains that ultimately came off disk, and a wrong count there should
    /// look wrong, not crash.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
