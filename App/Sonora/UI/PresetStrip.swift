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
    }
}
