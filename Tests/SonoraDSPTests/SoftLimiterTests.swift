import Testing
import Foundation
@testable import SonoraDSP

@Suite("SoftLimiter")
struct SoftLimiterTests {

    @Test("quiet signals pass through untouched")
    func belowThresholdIsTransparent() {
        var limiter = SoftLimiter()

        #expect(limiter.process(0.25) == 0.25)
        #expect(limiter.process(-0.4) == -0.4)
        #expect(limiter.isEngaged == false)
    }

    @Test("the output never exceeds the ceiling, however loud the input")
    func neverExceedsCeiling() {
        var limiter = SoftLimiter()

        // tanh saturates to exactly 1 in Float for large inputs, so the output
        // reaches the ceiling but never passes it.
        for input in [1.0, 2.0, 10.0, 100.0, 1_000.0] as [Float] {
            #expect(limiter.process(input) <= SoftLimiter.ceiling)
            #expect(limiter.process(-input) >= -SoftLimiter.ceiling)
        }
    }

    @Test("the curve is continuous at the threshold")
    func continuousAtThreshold() {
        var limiter = SoftLimiter()

        let below = limiter.process(SoftLimiter.threshold - 0.000_1)
        let above = limiter.process(SoftLimiter.threshold + 0.000_1)
        #expect(abs(above - below) < 0.001)
    }

    @Test("the curve is monotonic, louder input gives louder output")
    func monotonic() {
        var limiter = SoftLimiter()
        var previous: Float = 0

        for step in 0...200 {
            let input = Float(step) * 0.02
            let output = limiter.process(input)
            #expect(output >= previous)
            previous = output
        }
    }

    @Test("the engaged flag reports that limiting happened")
    func engagedFlag() {
        var limiter = SoftLimiter()

        _ = limiter.process(0.1)
        #expect(limiter.isEngaged == false)

        _ = limiter.process(0.9)
        #expect(limiter.isEngaged == true)

        limiter.clearEngagedFlag()
        #expect(limiter.isEngaged == false)
    }

    @Test("NaN is replaced rather than passed on")
    func nanIsReplaced() {
        var limiter = SoftLimiter()

        #expect(limiter.process(.nan) == 0)
        #expect(limiter.isEngaged == true)
    }
}
