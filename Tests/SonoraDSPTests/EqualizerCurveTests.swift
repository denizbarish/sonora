import Testing
import Foundation
@testable import SonoraDSP

@Suite("EqualizerCurve")
struct EqualizerCurveTests {

    let sampleRate = 48_000.0

    @Test("a flat band set produces a flat curve")
    func flatIsFlat() {
        for frequency in [20.0, 100, 1_000, 10_000, 20_000] {
            let value = EqualizerCurve.magnitudeDecibels(
                of: EqualizerBand.graphicDefaults,
                atFrequency: frequency,
                sampleRate: sampleRate
            )
            #expect(abs(value) < 0.000_1)
        }
    }

    @Test("a boosted band lifts its own centre frequency")
    func boostedBand() {
        var bands = EqualizerBand.graphicDefaults
        bands[5].gainDecibels = 6  // 1 kHz

        let value = EqualizerCurve.magnitudeDecibels(
            of: bands, atFrequency: 1_000, sampleRate: sampleRate
        )
        #expect(abs(value - 6) < 0.3)
    }

    @Test("the curve agrees with a chain built from the same bands")
    func agreesWithTheChain() {
        var bands = EqualizerBand.graphicDefaults
        bands[2].gainDecibels = -7
        bands[8].gainDecibels = 4

        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        chain.update(bands: bands)

        // The interface must draw what the engine will actually do. If these
        // two ever disagree, the curve is lying to the user.
        for frequency in [32.0, 125, 1_000, 8_000, 16_000] {
            let curve = EqualizerCurve.magnitudeDecibels(
                of: bands, atFrequency: frequency, sampleRate: sampleRate
            )
            let engine = chain.magnitudeDecibels(atFrequency: frequency)
            #expect(abs(curve - engine) < 0.001)
        }
    }

    @Test("points are logarithmically spaced and cover the range")
    func pointSpacing() {
        let points = EqualizerCurve.points(
            of: EqualizerBand.graphicDefaults,
            sampleRate: sampleRate,
            from: 20, to: 20_000, count: 100
        )

        #expect(points.count == 100)
        #expect(abs(points.first!.frequency - 20) < 0.001)
        #expect(abs(points.last!.frequency - 20_000) < 0.001)

        // Logarithmic spacing means every step multiplies by the same ratio.
        let firstRatio = points[1].frequency / points[0].frequency
        let lastRatio = points[99].frequency / points[98].frequency
        #expect(abs(firstRatio - lastRatio) < 0.000_1)
    }

    @Test("a single point request returns the low end rather than dividing by zero")
    func degenerateCount() {
        let points = EqualizerCurve.points(
            of: EqualizerBand.graphicDefaults,
            sampleRate: sampleRate,
            from: 20, to: 20_000, count: 1
        )

        #expect(points.count == 1)
        #expect(points[0].frequency == 20)
    }

    @Test("a nonsensical count returns nothing rather than trapping")
    func zeroCount() {
        #expect(
            EqualizerCurve.points(
                of: EqualizerBand.graphicDefaults,
                sampleRate: sampleRate,
                from: 20, to: 20_000, count: 0
            ).isEmpty
        )
        #expect(
            EqualizerCurve.points(
                of: EqualizerBand.graphicDefaults,
                sampleRate: sampleRate,
                from: 20, to: 20_000, count: -5
            ).isEmpty
        )
    }
}
