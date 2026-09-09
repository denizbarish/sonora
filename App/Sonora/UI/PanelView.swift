import AppKit
import SonoraDSP
import SwiftUI

struct PanelView: View {

    @Bindable var model: PanelModel

    private static let gainRange = EqualizerBand.gainRange

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            preamp
            equalizer
            presets
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    ForEach(model.availableOutputs) { device in
                        Button(device.name) { model.selectOutput(device) }
                    }
                } label: {
                    Text(model.outputDeviceName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Output device")

                Spacer()

                // The switch carries its own name. Unlabelled, it was a control
                // in the corner of the panel with nothing saying what it did.
                Toggle("Bypass", isOn: $model.isBypassed)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .accessibilityLabel("Bypass equalizer")
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Slider(value: $model.systemVolume, in: 0...1)
                    .accessibilityLabel("System volume")
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }
        }
    }

    private var preamp: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Preamp")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%+.1f dB", model.preampDecibels))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    // Above unity the limiter starts doing real work, so the
                    // number says so rather than leaving it to be discovered.
                    //
                    // Wrapped in AnyShapeStyle because the two branches are
                    // different types, Color and HierarchicalShapeStyle, and
                    // the type checker cannot unify them in a ternary.
                    .foregroundStyle(
                        model.preampDecibels > 0
                            ? AnyShapeStyle(.orange)
                            : AnyShapeStyle(.secondary)
                    )
            }
            // The same control the bands use, laid on its side: the preamp is
            // a gain over the same range with the same neutral 0 dB, so it
            // fills out of the centre rather than out of its minimum. The
            // system volume slider above stays a stock `Slider` on purpose,
            // because 0 to 1 has no neutral point to fill from.
            GainSlider(
                axis: .horizontal,
                gain: $model.preampDecibels,
                accessibilityLabel: "Preamp"
            )
        }
    }

    private var equalizer: some View {
        ZStack(alignment: .top) {
            CurveView(
                points: model.curvePoints(count: 120),
                range: Self.gainRange,
                verticalInset: BandMetrics.curveInset
            )
            .frame(height: BandMetrics.trackHeight)
            .opacity(model.isBypassed ? 0.25 : 1)

            // 0 dB, drawn once across the whole equalizer rather than left for
            // the eye to infer from ten separate controls. Every fill above it
            // is a boost and every fill below it is a cut, and the line is what
            // makes that readable without touching anything.
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .frame(height: BandMetrics.trackHeight, alignment: .center)

            BandSliders(gains: $model.bandGains)
        }
    }

    /// The preset section. It carries its own heading, on the same line as the
    /// menu it opens, the way the preamp above puts its label and its value on
    /// one line.
    private var presets: some View {
        PresetPicker(
            presets: model.presets,
            recentPresets: model.recentPresets,
            activeID: model.activePresetID,
            onSelect: model.selectPreset
        )
    }

    private var footer: some View {
        HStack {
            Text(model.stateDescription)
                .font(.system(size: 10))
                .foregroundStyle(
                    model.isRunning
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(.orange)
                )
                .lineLimit(1)

            Spacer()

            if !model.isRunning {
                Button("Try Again", action: model.retry)
                    .controlSize(.small)
            }
        }
    }
}
