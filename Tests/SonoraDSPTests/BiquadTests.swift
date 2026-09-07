import Testing
import Foundation
@testable import SonoraDSP

@Suite("Biquad")
struct BiquadTests {

    let sampleRate = 48_000.0

    /// Feeds a sine wave through the filter and measures the steady state
    /// amplitude of the output, in decibels relative to the input.
    private func measuredGainDecibels(
        of coefficients: BiquadCoefficients,
        atFrequency frequency: Double
    ) -> Float {
        var filter = Biquad(coefficients: coefficients)
        let totalSamples = 48_000
        let settleSamples = 24_000
        var peak: Float = 0

        for index in 0..<totalSamples {
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
            let output = filter.process(Float(sin(phase)))
            if index >= settleSamples {
                peak = max(peak, abs(output))
            }
        }

        return 20 * log10(peak)
    }

    @Test("identity coefficients return the input unchanged")
    func identityPassthrough() {
        var filter = Biquad()

        #expect(filter.process(0.25) == 0.25)
        #expect(filter.process(-0.5) == -0.5)
        #expect(filter.process(0) == 0)
    }

    @Test("measured gain matches the analytic response at the centre frequency")
    func measuredMatchesAnalytic() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 1_000, q: 1.41, gainDecibels: 6, sampleRate: sampleRate
        )

        let measured = measuredGainDecibels(of: coefficients, atFrequency: 1_000)
        #expect(abs(measured - 6) < 0.1)
    }

    @Test("measured cut matches the analytic response")
    func measuredCut() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 500, q: 1.41, gainDecibels: -6, sampleRate: sampleRate
        )

        let measured = measuredGainDecibels(of: coefficients, atFrequency: 500)
        #expect(abs(measured + 6) < 0.1)
    }

    @Test("the filter stays stable over a long run")
    func stability() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 60, q: 4, gainDecibels: 12, sampleRate: sampleRate
        )
        var filter = Biquad(coefficients: coefficients)
        var maximum: Float = 0

        for index in 0..<480_000 {
            let phase = 2 * Double.pi * 60 * Double(index) / sampleRate
            let output = filter.process(Float(sin(phase)))
            maximum = max(maximum, abs(output))
            #expect(output.isFinite)
        }

        // A +12 dB peak on a unit sine cannot exceed roughly 4x amplitude.
        #expect(maximum < 5)
    }

    @Test("reset clears the filter state")
    func reset() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 1_000, q: 1, gainDecibels: 12, sampleRate: sampleRate
        )
        var filter = Biquad(coefficients: coefficients)

        for _ in 0..<100 { _ = filter.process(1) }
        filter.reset()

        // With cleared state the first sample only sees the b0 term.
        #expect(abs(filter.process(1) - coefficients.b0) < 0.000_01)
    }

    @Test("an impulse produces a decaying finite response")
    func impulseResponse() {
        let coefficients = BiquadCoefficients(
            kind: .lowPass, frequency: 1_000, q: 0.707, gainDecibels: 0, sampleRate: sampleRate
        )
        var filter = Biquad(coefficients: coefficients)

        var response: [Float] = [filter.process(1)]
        for _ in 0..<999 { response.append(filter.process(0)) }

        #expect(response.allSatisfy { $0.isFinite })
        #expect(abs(response[999]) < abs(response[0]))
    }
}
