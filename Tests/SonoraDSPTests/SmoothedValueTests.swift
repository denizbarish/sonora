import Testing
import Foundation
@testable import SonoraDSP

@Suite("SmoothedValue")
struct SmoothedValueTests {

    @Test("reaches roughly one time constant after the ramp duration")
    func oneTimeConstant() {
        var value = SmoothedValue(value: 0, sampleRate: 48_000, rampSeconds: 0.030)
        value.target = 1

        let samplesInRamp = Int(48_000 * 0.030)
        for _ in 0..<samplesInRamp {
            _ = value.nextValue()
        }

        // An exponential ramp covers 1 - 1/e of the distance in one time constant.
        #expect(abs(value.current - 0.632) < 0.01)
    }

    @Test("converges to the target after five time constants")
    func convergence() {
        var value = SmoothedValue(value: 0, sampleRate: 48_000, rampSeconds: 0.030)
        value.target = 2

        for _ in 0..<Int(48_000 * 0.030 * 5) {
            _ = value.nextValue()
        }

        #expect(abs(value.current - 2) < 0.001)
    }

    @Test("snap jumps immediately without ramping")
    func snap() {
        var value = SmoothedValue(value: 0, sampleRate: 48_000)
        value.snap(to: 0.5)

        #expect(value.current == 0.5)
        #expect(value.nextValue() == 0.5)
    }

    @Test("changing sample rate keeps the ramp duration in seconds")
    func sampleRateChange() {
        var value = SmoothedValue(value: 0, sampleRate: 48_000, rampSeconds: 0.030)
        value.setSampleRate(96_000)
        value.target = 1

        for _ in 0..<Int(96_000 * 0.030) {
            _ = value.nextValue()
        }

        #expect(abs(value.current - 0.632) < 0.01)
    }
}
