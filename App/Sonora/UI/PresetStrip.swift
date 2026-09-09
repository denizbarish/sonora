import SonoraProfiles
import SwiftUI

/// The preset picker, a horizontal row of pills.
struct PresetStrip: View {

    let presets: [Preset]
    let activeID: String?
    let onSelect: (Preset) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(presets) { preset in
                    Button {
                        onSelect(preset)
                    } label: {
                        Text(preset.name)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(
                                    preset.id == activeID
                                        ? AnyShapeStyle(.tint)
                                        : AnyShapeStyle(.quaternary)
                                )
                            )
                            .foregroundStyle(preset.id == activeID ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(preset.id == activeID ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.never)
        // The row is wider than the panel and always will be, so without a cue
        // the last pill just ends mid-word and reads as a rendering fault. The
        // fade makes the trailing edge say "this continues" instead. It runs
        // over the trailing tenth only, so a pill at rest is never dimmed
        // unless it is genuinely being cut off.
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.9),
                    .init(color: .black.opacity(0), location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}
