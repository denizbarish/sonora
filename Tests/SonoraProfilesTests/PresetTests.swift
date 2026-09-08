import Testing
import Foundation
@testable import SonoraProfiles
import SonoraDSP

@Suite("Preset")
struct PresetTests {

    @Test("the flat preset has ten bands, all at zero")
    func flatPreset() {
        let flat = BuiltInPresets.flat

        #expect(flat.bands.count == 10)
        #expect(flat.bands.allSatisfy { $0.gainDecibels == 0 })
        #expect(flat.preampDecibels == 0)
        #expect(flat.isBuiltIn == true)
    }

    @Test("every built-in preset is well formed")
    func builtInsAreWellFormed() {
        // Named individually rather than counted, so a preset dropped from
        // `all` fails here instead of passing a loose count check.
        let expected = [
            BuiltInPresets.flat,
            BuiltInPresets.bassBoost,
            BuiltInPresets.trebleBoost,
            BuiltInPresets.vocal,
            BuiltInPresets.loudness,
            BuiltInPresets.podcast,
            BuiltInPresets.laptopSpeaker,
        ]
        #expect(BuiltInPresets.all.map(\.id) == expected.map(\.id))

        for preset in BuiltInPresets.all {
            #expect(preset.bands.count == 10)
            #expect(preset.isBuiltIn == true)
            #expect(preset.name.isEmpty == false)
            #expect(preset.bands.allSatisfy { EqualizerBand.gainRange.contains($0.gainDecibels) })
            #expect(EqualizerBand.gainRange.contains(preset.preampDecibels))
        }
    }

    @Test("built-in preset identifiers are unique")
    func uniqueIdentifiers() {
        let identifiers = BuiltInPresets.all.map(\.id)
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test("built-in preset band frequencies follow the graphic layout")
    func builtInFrequencies() {
        for preset in BuiltInPresets.all {
            #expect(preset.bands.map(\.frequency) == EqualizerBand.graphicFrequencies)
        }
    }

    @Test("a preset survives a JSON round trip")
    func codableRoundTrip() throws {
        let original = Preset(
            id: "custom-1",
            name: "My Curve",
            preampDecibels: -2,
            gains: [3, 2, 1, 0, 0, 0, -1, -2, 1, 4],
            isBuiltIn: false
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)

        #expect(decoded == original)
    }

    @Test("the gain convenience initialiser builds graphic bands")
    func gainInitialiser() {
        let preset = Preset(
            id: "test", name: "Test", preampDecibels: 0,
            gains: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], isBuiltIn: false
        )

        #expect(preset.bands.count == 10)
        #expect(preset.bands[0].frequency == 32)
        #expect(preset.bands[0].gainDecibels == 1)
        #expect(preset.bands[9].frequency == 16_000)
        #expect(preset.bands[9].gainDecibels == 10)
        #expect(preset.bands.allSatisfy { $0.kind == .peaking })
    }
}
