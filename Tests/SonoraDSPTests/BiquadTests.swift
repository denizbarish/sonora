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

    @Test("reset clears both state variables")
    func reset() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 1_000, q: 1, gainDecibels: 12, sampleRate: sampleRate
        )
        var reference = Biquad(coefficients: coefficients)
        var filter = Biquad(coefficients: coefficients)

        for _ in 0..<100 { _ = filter.process(1) }
        filter.reset()

        // With cleared state the first sample only sees the b0 term. The
        // reference filter consumes the same sample so the two stay in step.
        #expect(abs(filter.process(1) - coefficients.b0) < 0.000_01)
        #expect(abs(reference.process(1) - coefficients.b0) < 0.000_01)

        // state2 does not reach the output until the second sample, so a reset
        // that cleared only state1 would still pass the assertion above. Running
        // the reset filter alongside a fresh one catches it: from here on the
        // two must agree sample for sample.
        for _ in 0..<8 {
            #expect(abs(filter.process(1) - reference.process(1)) < 0.000_01)
        }
    }

    @Test("state is flushed instead of decaying into subnormals")
    func denormalFlush() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 100, q: 4, gainDecibels: 12, sampleRate: sampleRate
        )
        var filter = Biquad(coefficients: coefficients)

        for _ in 0..<1_000 { _ = filter.process(1) }

        var output: Float = 0
        for _ in 0..<200_000 { output = filter.process(0) }

        // Without flushing, the ringing tail decays through the subnormal range
        // and never reaches exactly zero.
        #expect(output == 0)
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

    @Test("a NaN burst does not silence the filter forever")
    func recoversFromNaN() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 1_000, q: 1.41, gainDecibels: 6, sampleRate: sampleRate
        )
        var filter = Biquad(coefficients: coefficients)

        for _ in 0..<16 { _ = filter.process(.nan) }

        // Without flushing non-finite state the NaN feeds itself and every
        // later sample is NaN, however clean the input.
        let recovered = filter.process(0.5)
        #expect(recovered.isFinite)
        #expect(recovered != 0)
    }
}
