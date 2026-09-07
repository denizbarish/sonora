import Testing
import Foundation
@testable import SonoraDSP

@Suite("EqualizerChain")
struct EqualizerChainTests {

    let sampleRate = 48_000.0

    /// Runs a stereo sine through the chain and returns the steady state gain
    /// of each channel in decibels.
    private func measuredGainDecibels(
        chain: EqualizerChain,
        frequency: Double
    ) -> (left: Float, right: Float) {
        let frameCount = 48_000
        let settleFrames = 24_000
        var buffer = [Float](repeating: 0, count: frameCount * 2)

        for frame in 0..<frameCount {
            let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
            let sample = Float(sin(phase))
            buffer[frame * 2] = sample
            buffer[frame * 2 + 1] = sample
        }

        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: frameCount)
        }

        var leftPeak: Float = 0
        var rightPeak: Float = 0
        for frame in settleFrames..<frameCount {
            leftPeak = max(leftPeak, abs(buffer[frame * 2]))
            rightPeak = max(rightPeak, abs(buffer[frame * 2 + 1]))
        }

        return (20 * log10(leftPeak), 20 * log10(rightPeak))
    }

    @Test("there are ten graphic bands on ISO centre frequencies")
    func graphicBandLayout() {
        #expect(EqualizerBand.graphicFrequencies == [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000])
        #expect(EqualizerBand.graphicDefaults.count == 10)
        #expect(EqualizerBand.graphicDefaults.allSatisfy { $0.gainDecibels == 0 })
        #expect(EqualizerBand.graphicDefaults.allSatisfy { $0.kind == .peaking })
    }

    @Test("a flat chain leaves the signal untouched")
    func flatIsTransparent() {
        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        chain.update(bands: EqualizerBand.graphicDefaults)

        let gain = measuredGainDecibels(chain: chain, frequency: 1_000)
        #expect(abs(gain.left) < 0.01)
        #expect(abs(gain.right) < 0.01)
    }

    @Test("a boosted band raises its own centre frequency")
    func boostedBand() {
        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        var bands = EqualizerBand.graphicDefaults
        bands[5].gainDecibels = 6  // 1 kHz
        chain.update(bands: bands)

        let gain = measuredGainDecibels(chain: chain, frequency: 1_000)
        #expect(abs(gain.left - 6) < 0.3)
        #expect(abs(gain.right - 6) < 0.3)
    }

    @Test("a boosted band leaves distant frequencies alone")
    func boostIsLocal() {
        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        var bands = EqualizerBand.graphicDefaults
        bands[0].gainDecibels = 12  // 32 Hz
        chain.update(bands: bands)

        let gain = measuredGainDecibels(chain: chain, frequency: 4_000)
        #expect(abs(gain.left) < 0.5)
    }

    @Test("both channels are filtered independently but identically")
    func channelsMatch() {
        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        var bands = EqualizerBand.graphicDefaults
        bands[7].gainDecibels = -9  // 4 kHz
        chain.update(bands: bands)

        let gain = measuredGainDecibels(chain: chain, frequency: 4_000)
        #expect(abs(gain.left - gain.right) < 0.001)
        #expect(abs(gain.left + 9) < 0.5)
    }

    @Test("the analytic curve agrees with the measured response")
    func curveMatchesMeasurement() {
        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        var bands = EqualizerBand.graphicDefaults
        bands[3].gainDecibels = 8  // 250 Hz
        chain.update(bands: bands)

        let predicted = chain.magnitudeDecibels(atFrequency: 250)
        let measured = measuredGainDecibels(chain: chain, frequency: 250).left
        #expect(abs(predicted - measured) < 0.3)
    }

    @Test("precomputed coefficients produce the same response as update")
    func applyCoefficientsMatchesUpdate() {
        var bands = EqualizerBand.graphicDefaults
        bands[6].gainDecibels = -7  // 2 kHz

        let viaUpdate = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        viaUpdate.update(bands: bands)

        let viaCoefficients = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        let computed = EqualizerChain.coefficients(for: bands, sampleRate: sampleRate)
        computed.withUnsafeBufferPointer { pointer in
            viaCoefficients.applyCoefficients(pointer.baseAddress!, count: computed.count)
        }

        let expected = measuredGainDecibels(chain: viaUpdate, frequency: 2_000).left
        let actual = measuredGainDecibels(chain: viaCoefficients, frequency: 2_000).left
        #expect(abs(actual - expected) < 0.001)
        #expect(abs(actual + 7) < 0.5)
    }

    @Test("applyCoefficients clamps to the maximum band count")
    func applyCoefficientsClamps() {
        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        let tooMany = [BiquadCoefficients](
            repeating: .identity, count: EqualizerChain.maximumBandCount + 8
        )

        tooMany.withUnsafeBufferPointer { pointer in
            chain.applyCoefficients(pointer.baseAddress!, count: tooMany.count)
        }

        // Identity coefficients everywhere means the chain is transparent, and
        // clamping must not have read past its own storage.
        var buffer = [Float](repeating: 0.3, count: 256)
        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 128)
        }
        #expect(buffer.allSatisfy { abs($0 - 0.3) < 0.000_01 })
    }

    @Test("update beyond the maximum band count keeps only what fits")
    func updateClamps() {
        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        let tooMany = (0..<(EqualizerChain.maximumBandCount + 5)).map { index in
            EqualizerBand(frequency: 100 + Double(index) * 100, gainDecibels: 0)
        }

        chain.update(bands: tooMany)

        #expect(chain.bands.count == EqualizerChain.maximumBandCount)
    }

    @Test("processing never produces a non-finite sample")
    func staysFinite() {
        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        var bands = EqualizerBand.graphicDefaults
        for index in bands.indices { bands[index].gainDecibels = 12 }
        chain.update(bands: bands)

        var buffer = [Float](repeating: 0, count: 2_048)
        for index in buffer.indices { buffer[index] = Float.random(in: -1...1) }

        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 1_024)
        }

        #expect(buffer.allSatisfy { $0.isFinite })
    }
}
