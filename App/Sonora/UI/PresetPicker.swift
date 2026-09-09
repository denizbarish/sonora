import SonoraProfiles
import SwiftUI

/// The preset picker: a pop-up menu carrying every preset, with a short row of
/// one-click pills beneath it for the three used most recently.
///
/// The split is what lets the list grow. Seven built-ins already overflow a
/// single row, and user presets and a headphone-correction library are still to
/// come; a menu absorbs all of that without the panel changing shape, while a
/// row of pills cannot. The pills exist so the common case, re-picking
/// something used minutes ago, stays a single click.
///
/// The menu is the complete list and the pills are a shortcut into it, so both
/// lead to the same `onSelect`, and the active preset is marked in both places.
struct PresetPicker: View {

    /// Every preset, in declared order. The menu shows all of them.
    let presets: [Preset]

    /// At most three presets, most recently used first, never empty.
    let recentPresets: [Preset]

    /// The preset the current settings match, or `nil` once a band slider has
    /// been moved and the curve is no longer any named preset.
    let activeID: String?

    let onSelect: (Preset) -> Void

    /// The gap between pills, and the figure the equal-width split assumes.
    private static let pillSpacing: CGFloat = 6

    /// What the menu button reads when the curve matches no named preset.
    private static let customStateName = "Custom"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            menu
            pillRow
        }
    }

    // MARK: - Menu

    /// The full list, grouped under a heading.
    ///
    /// The heading is there before there is anything to contrast it with: when
    /// a "My Presets" group arrives the menu gains a second section rather than
    /// changing from an ungrouped list into a grouped one, so nothing the user
    /// has already learned about this menu moves.
    ///
    /// `Toggle` rather than `Button` because in a menu SwiftUI draws a toggle
    /// as a checkmark item, which is the native way a macOS menu says "this one
    /// is the current choice" and is also what VoiceOver reads back as a state.
    private var menu: some View {
        Menu {
            Section("Built-In") {
                ForEach(presets) { preset in
                    Toggle(preset.name, isOn: selectionBinding(for: preset))
                }
            }
        } label: {
            Text(activeName)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Preset")
        .accessibilityValue(activeName)
        .help("Choose a preset")
    }

    /// Turning an item on selects it. Turning the active one off is ignored,
    /// because "no preset" is a state the sliders produce, not one to pick.
    private func selectionBinding(for preset: Preset) -> Binding<Bool> {
        Binding(
            get: { preset.id == activeID },
            set: { isOn in
                if isOn {
                    onSelect(preset)
                }
            }
        )
    }

    private var activeName: String {
        presets.first { $0.id == activeID }?.name ?? Self.customStateName
    }

    // MARK: - Pills

    /// The three most recent presets, sharing the row in equal thirds.
    ///
    /// Equal thirds rather than intrinsic widths so the row is exactly the
    /// panel's width by construction: with 332 points of usable width and two
    /// 6-point gaps, each pill gets a little over 106 points whatever the names
    /// happen to be. A name too long for that truncates at the tail and keeps
    /// its full text in the tooltip and in the accessibility label, so nothing
    /// is ever lost, only shortened. None of the current built-ins reach that
    /// limit, including "Laptop Speaker"; the rule is there for the user
    /// presets and correction curves that will.
    private var pillRow: some View {
        HStack(spacing: Self.pillSpacing) {
            ForEach(recentPresets) { preset in
                pill(for: preset)
            }
        }
        .controlSize(.small)
        .buttonBorderShape(.capsule)
    }

    /// The two button styles are separate branches because `.bordered` and
    /// `.borderedProminent` are different types and cannot meet in a ternary.
    /// Both are stock AppKit-backed styles, which is what gives the pills their
    /// keyboard focus ring and their pressed state for free.
    @ViewBuilder
    private func pill(for preset: Preset) -> some View {
        let button = pillButton(for: preset)

        if preset.id == activeID {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func pillButton(for preset: Preset) -> some View {
        Button {
            onSelect(preset)
        } label: {
            Text(preset.name)
                .lineLimit(1)
                .truncationMode(.tail)
                // On the label as well as on the button: the button style
                // stretches its background to the frame, but the text inside
                // stays at its natural width and drifts off centre without it.
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        // The label may be truncated, so the name is stated in full for both
        // VoiceOver and the tooltip rather than read off the visible glyphs.
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(preset.id == activeID ? [.isSelected] : [])
        .help(preset.name)
    }
}
