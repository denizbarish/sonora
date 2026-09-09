import SonoraProfiles
import SwiftUI

/// The preset section: a heading and the menu that opens the full catalogue on
/// one line, with a short row of one-click shortcuts to the three presets used
/// most recently beneath them.
///
/// The split is what lets the list grow. Seven built-ins already overflow a
/// single row, and user presets and a headphone-correction library are still to
/// come; a menu absorbs all of that without the panel changing shape, while a
/// row of pills cannot. The pills exist so the common case, re-picking
/// something used minutes ago, stays a single click.
///
/// Each part has one job. The menu is the way into the catalogue, so it is
/// labelled for what it opens rather than for what is selected; the pills say
/// which preset is active. The checkmark inside the menu stays, because that is
/// where a list of choices has to mark the current one.
struct PresetPicker: View {

    /// Every preset, in declared order. The menu shows all of them.
    let presets: [Preset]

    /// At most three presets, most recently used first, never empty.
    let recentPresets: [Preset]

    /// The preset the current settings match, or `nil` once a band slider has
    /// been moved and the curve is no longer any named preset.
    let activeID: String?

    let onSelect: (Preset) -> Void

    /// The gap between pills, and the figure the width cap below assumes.
    private static let pillSpacing: CGFloat = 6

    /// The widest a single pill may become. A pill takes its natural width, so
    /// short names sit in short capsules and the row reads as a handful of
    /// shortcuts rather than as a segmented control; the cap is what guarantees
    /// three of them can never overflow the panel. Three capped pills and two
    /// gaps come to 330 points inside the 332 points of content width, so even
    /// three long names stay inside it. "Laptop Speaker" and "Treble Boost",
    /// the longest built-in names, are well under the cap and are not
    /// truncated; the cap is there for the user presets and correction curves
    /// that will be longer. A name that does reach it truncates at the tail and
    /// keeps its full text in the tooltip and the accessibility label, so
    /// nothing is ever lost, only shortened.
    private static let maximumPillWidth: CGFloat = 106

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Presets")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                menu
            }

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
    /// The button names the catalogue it opens instead of the active preset.
    /// Naming the active preset here said the same thing the pills below
    /// already say, a few points apart, and made a way in look like a value.
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
            Text("All Presets")
        }
        .controlSize(.small)
        // Sized to its label, at the panel's trailing edge, so it lines up with
        // the preamp's value above it instead of stretching across the panel.
        .fixedSize()
        .accessibilityLabel("All Presets")
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

    // MARK: - Pills

    /// The three most recent presets, each at its natural width, packed against
    /// the leading edge under the heading.
    private var pillRow: some View {
        HStack(spacing: Self.pillSpacing) {
            ForEach(recentPresets) { preset in
                pill(for: preset)
            }

            Spacer(minLength: 0)
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
        }
        // A cap, not a width: the pill shrinks to its name and only stops
        // growing when a long one would push the row past the panel.
        .frame(maxWidth: Self.maximumPillWidth)
        // The label may be truncated, so the name is stated in full for both
        // VoiceOver and the tooltip rather than read off the visible glyphs.
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(preset.id == activeID ? [.isSelected] : [])
        .help(preset.name)
    }
}
