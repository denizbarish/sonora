import SonoraProfiles
import SwiftUI

/// The preset section: a heading and the menu that opens the full catalogue on
/// one line, with a segmented control of the three presets used most recently
/// beneath them.
///
/// The split is what lets the list grow. Seven built-ins already overflow a
/// single row, and user presets and a headphone-correction library are still to
/// come; a menu absorbs all of that without the panel changing shape, while a
/// row of shortcuts cannot. The shortcuts exist so the common case, re-picking
/// something used minutes ago, stays a single click.
///
/// Each part has one job. The menu is the way into the catalogue, so it is
/// labelled for what it opens rather than for what is selected; the segmented
/// control says which preset is active. The checkmark inside the menu stays,
/// because that is where a list of choices has to mark the current one.
///
/// The shortcuts are one segmented control rather than three separate buttons
/// because separate buttons each took the width of their own name: "Flat" made
/// a small capsule with a wide gap after it while "Treble Boost" nearly filled
/// its share, and the eye read three floating objects with uneven spacing
/// instead of one group. Equal, adjacent segments inside a single track remove
/// the gaps that were doing the misleading, and the selected segment is a light
/// raised fill rather than a saturated accent, so the row reads as one object
/// with one part chosen.
///
/// A segmented control usually says "these are all the choices", and these are
/// three of seven. The "All Presets" menu directly above is what answers that,
/// which is why there is no fourth "More" segment here: two ways into the
/// catalogue a few points apart would be one too many.
struct PresetPicker: View {

    /// Every preset, in declared order. The menu shows all of them.
    let presets: [Preset]

    /// At most three presets, most recently used first, never empty.
    let recentPresets: [Preset]

    /// The preset the current settings match, or `nil` once a band slider has
    /// been moved and the curve is no longer any named preset.
    let activeID: String?

    let onSelect: (Preset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Presets")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                menu
            }

            recentSegments
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
    /// Naming the active preset here said the same thing the segments below
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

    // MARK: - Recent segments

    /// The three most recent presets as one segmented control spanning the
    /// panel's content width.
    ///
    /// It takes the full width on purpose. The segments are then equal and
    /// adjacent whatever their names are, which is the whole point of using a
    /// segmented control here, and the track's ends land on the same edges as
    /// the heading above and the equalizer above that.
    ///
    /// A long name shortens rather than pushing the row wider: a segment is a
    /// third of the track no matter what it holds, and a name too long for its
    /// third truncates inside it. Nothing is lost when that happens, because
    /// the full name is still spelled out in the "All Presets" menu and in the
    /// accessibility value below. The two longest built-in names, "Laptop
    /// Speaker" and "Treble Boost", are well inside a third of 332 points; the
    /// truncation is there for the user presets and correction curves to come.
    private var recentSegments: some View {
        Picker("Recent Presets", selection: recentSelection) {
            ForEach(recentPresets) { preset in
                Text(preset.name)
                    .lineLimit(1)
                    // Tagged as an optional so the tag type matches the
                    // optional selection, which is what lets `nil` mean "none
                    // of these" rather than being an unrepresentable value.
                    .tag(Optional(preset.id))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Recent Presets")
        // The segment itself carries the selected state; this says which preset
        // that is, and says so in full even when the visible label is
        // truncated. When nothing matches it names that state instead of
        // leaving VoiceOver to report a control with no value.
        .accessibilityValue(activeRecentPreset?.name ?? "No preset selected")
        .help("Choose a recently used preset")
    }

    /// The recent preset the current settings match, if the match is one of the
    /// three on screen.
    ///
    /// `nil` covers both cases where no segment may be selected: the sliders
    /// have been moved and `activeID` is itself `nil`, and `activeID` names a
    /// preset picked from the menu that is not among the recents. In both the
    /// control has to show no selection, because a segment lit up here would
    /// claim the curve is something it is not. The menu above keeps its
    /// checkmark in the second case, so the active preset is still stated
    /// somewhere.
    private var activeRecentPreset: Preset? {
        guard let activeID else { return nil }
        return recentPresets.first { $0.id == activeID }
    }

    /// Reads as "the selected segment, or none", and writes only real
    /// selections. A segment can never be deselected by clicking it, so the
    /// setter has nothing to do for `nil`; clearing the selection is the
    /// sliders' job, and it arrives through `activeID`.
    private var recentSelection: Binding<String?> {
        Binding(
            get: { activeRecentPreset?.id },
            set: { id in
                guard
                    let id,
                    let preset = recentPresets.first(where: { $0.id == id })
                else { return }

                onSelect(preset)
            }
        )
    }
}
