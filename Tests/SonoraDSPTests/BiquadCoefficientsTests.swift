import Testing
import Foundation
@testable import SonoraDSP

@Suite("BiquadCoefficients")
struct BiquadCoefficientsTests {

    let sampleRate = 48_000.0

    @Test("peaking filter hits its exact gain at the centre frequency")
    func peakingGainAtCentre() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 1_000, q: 1.41, gainDecibels: 6, sampleRate: sampleRate
        )

        let magnitude = coefficients.magnitudeDecibels(atFrequency: 1_000, sampleRate: sampleRate)
        #expect(abs(magnitude - 6) < 0.01)
    }

    @Test("peaking filter is transparent far from the centre frequency")
    func peakingTransparentAway() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 1_000, q: 1.41, gainDecibels: 6, sampleRate: sampleRate
        )

        #expect(abs(coefficients.magnitudeDecibels(atFrequency: 20, sampleRate: sampleRate)) < 0.2)
        #expect(abs(coefficients.magnitudeDecibels(atFrequency: 18_000, sampleRate: sampleRate)) < 0.2)
    }

    @Test("cut is the mirror of boost at the centre frequency")
    func symmetricCut() {
        let cut = BiquadCoefficients(
            kind: .peaking, frequency: 2_000, q: 1.41, gainDecibels: -9, sampleRate: sampleRate
        )

        let magnitude = cut.magnitudeDecibels(atFrequency: 2_000, sampleRate: sampleRate)
        #expect(abs(magnitude + 9) < 0.01)
    }

    @Test("zero gain produces a flat response at every frequency")
    func zeroGainIsFlat() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 1_000, q: 1.41, gainDecibels: 0, sampleRate: sampleRate
        )

        for frequency in [20.0, 100, 1_000, 5_000, 20_000] as [Double] {
            let magnitude = coefficients.magnitudeDecibels(
                atFrequency: frequency, sampleRate: sampleRate
            )
            #expect(abs(magnitude) < 0.0001)
        }
    }

    @Test("low shelf lifts the bottom and leaves the top alone")
    func lowShelf() {
        let coefficients = BiquadCoefficients(
            kind: .lowShelf, frequency: 200, q: 0.707, gainDecibels: 6, sampleRate: sampleRate
        )

        #expect(abs(coefficients.magnitudeDecibels(atFrequency: 20, sampleRate: sampleRate) - 6) < 0.3)
        #expect(abs(coefficients.magnitudeDecibels(atFrequency: 10_000, sampleRate: sampleRate)) < 0.2)
    }

    @Test("high shelf lifts the top and leaves the bottom alone")
    func highShelf() {
        let coefficients = BiquadCoefficients(
            kind: .highShelf, frequency: 4_000, q: 0.707, gainDecibels: 6, sampleRate: sampleRate
        )

        #expect(abs(coefficients.magnitudeDecibels(atFrequency: 18_000, sampleRate: sampleRate) - 6) < 0.3)
        #expect(abs(coefficients.magnitudeDecibels(atFrequency: 100, sampleRate: sampleRate)) < 0.2)
    }

    @Test("high pass is down 3 dB at the cutoff frequency")
    func highPassCutoff() {
        let coefficients = BiquadCoefficients(
            kind: .highPass, frequency: 1_000, q: 0.707, gainDecibels: 0, sampleRate: sampleRate
        )

        let magnitude = coefficients.magnitudeDecibels(atFrequency: 1_000, sampleRate: sampleRate)
        #expect(abs(magnitude + 3.01) < 0.1)
    }

    @Test("low pass is down 3 dB at the cutoff frequency")
    func lowPassCutoff() {
        let coefficients = BiquadCoefficients(
            kind: .lowPass, frequency: 1_000, q: 0.707, gainDecibels: 0, sampleRate: sampleRate
        )

        let magnitude = coefficients.magnitudeDecibels(atFrequency: 1_000, sampleRate: sampleRate)
        #expect(abs(magnitude + 3.01) < 0.1)
    }

    @Test("identity coefficients pass the signal untouched")
    func identity() {
        let coefficients = BiquadCoefficients.identity

        #expect(coefficients.b0 == 1)
        #expect(coefficients.b1 == 0)
        #expect(coefficients.b2 == 0)
        #expect(coefficients.a1 == 0)
        #expect(coefficients.a2 == 0)
    }

    @Test("a zero sample rate yields identity rather than NaN coefficients")
    func zeroSampleRateIsIdentity() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 1_000, q: 1.41, gainDecibels: 6, sampleRate: 0
        )

        #expect(coefficients == .identity)
        #expect(coefficients.b0.isNaN == false)
    }
}
