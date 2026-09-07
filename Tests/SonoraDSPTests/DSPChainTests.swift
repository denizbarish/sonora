import Testing
import Foundation
@testable import SonoraDSP

@Suite("DSPChain")
struct DSPChainTests {

    let sampleRate = 48_000.0

    private func sineBuffer(frequency: Double, frameCount: Int, amplitude: Float = 0.1) -> [Float] {
        var buffer = [Float](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
            let sample = amplitude * Float(sin(phase))
            buffer[frame * 2] = sample
            buffer[frame * 2 + 1] = sample
        }
        return buffer
    }

    private func peak(of buffer: [Float], fromFrame startFrame: Int) -> Float {
        var peak: Float = 0
        for index in (startFrame * 2)..<buffer.count {
            peak = max(peak, abs(buffer[index]))
        }
        return peak
    }

    @Test("a flat chain at unity preamp is transparent")
    func transparentWhenFlat() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 2)
        var buffer = sineBuffer(frequency: 1_000, frameCount: 48_000)
        let inputPeak = peak(of: buffer, fromFrame: 24_000)

        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 48_000)
        }

        #expect(abs(peak(of: buffer, fromFrame: 24_000) - inputPeak) < 0.001)
    }

    @Test("preamp applies its gain in decibels")
    func preampGain() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 2)
        chain.preampDecibels = 6
        var buffer = sineBuffer(frequency: 1_000, frameCount: 48_000, amplitude: 0.1)

        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 48_000)
        }

        let measured = 20 * log10(peak(of: buffer, fromFrame: 24_000) / 0.1)
        #expect(abs(measured - 6) < 0.1)
    }

    @Test("bypass returns the input untouched even with extreme settings")
    func bypass() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 2)
        chain.preampDecibels = 12
        var bands = EqualizerBand.graphicDefaults
        for index in bands.indices { bands[index].gainDecibels = 12 }
        chain.update(bands: bands)
        chain.isBypassed = true

        var buffer = sineBuffer(frequency: 1_000, frameCount: 1_024)
        let original = buffer

        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 1_024)
        }

        #expect(buffer == original)
    }

    @Test("the output never exceeds the limiter ceiling")
    func neverClips() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 2)
        chain.preampDecibels = 12
        var bands = EqualizerBand.graphicDefaults
        for index in bands.indices { bands[index].gainDecibels = 12 }
        chain.update(bands: bands)

        var buffer = sineBuffer(frequency: 1_000, frameCount: 48_000, amplitude: 1.0)
        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 48_000)
        }

        #expect(buffer.allSatisfy { abs($0) <= SoftLimiter.ceiling })
        #expect(chain.limiterIsEngaged == true)
    }

    @Test("a preamp change ramps instead of jumping")
    func preampRamps() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 2)
        var buffer = [Float](repeating: 0.1, count: 64 * 2)
        chain.preampDecibels = 12

        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 64)
        }

        // 64 frames is far shorter than the 30 ms ramp, so the gain has barely moved.
        #expect(buffer[0] < 0.11)
        #expect(buffer[126] > buffer[0])
    }

    @Test("applyResolved installs bypass, preamp and coefficients together")
    func applyResolved() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 2)

        var bands = EqualizerBand.graphicDefaults
        bands[4].gainDecibels = 4  // 500 Hz
        let computed = EqualizerChain.coefficients(for: bands, sampleRate: sampleRate)

        computed.withUnsafeBufferPointer { pointer in
            chain.applyResolved(
                isBypassed: false,
                preampGain: 0.5,
                coefficients: pointer.baseAddress!,
                count: computed.count
            )
        }

        #expect(chain.isBypassed == false)
        #expect(abs(chain.preampDecibels - (-6.020_6)) < 0.01)
        #expect(abs(chain.magnitudeDecibels(atFrequency: 500) - 4) < 0.3)
    }

    @Test("preampDecibels round trips through the ramp target")
    func preampDecibelsRoundTrip() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 2)

        for value in [-12.0, -3.0, 0.0, 6.0, 12.0] {
            chain.preampDecibels = value
            #expect(abs(chain.preampDecibels - value) < 0.001)
        }
    }

    @Test("processing a mono buffer works")
    func monoChannelCount() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 1)
        var buffer = [Float](repeating: 0.2, count: 512)

        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 512)
        }

        #expect(buffer.allSatisfy { $0.isFinite })
    }

    @Test("the overload indicator clears when the chain is bypassed")
    func indicatorClearsOnBypass() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 2)
        chain.preampDecibels = 12
        var buffer = sineBuffer(frequency: 1_000, frameCount: 1_024, amplitude: 1.0)

        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 1_024)
        }
        #expect(chain.limiterIsEngaged == true)

        chain.isBypassed = true
        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 1_024)
        }
        #expect(chain.limiterIsEngaged == false)
    }

    @Test("a NaN never leaves the chain")
    func nanIsContained() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 2)
        var buffer = [Float](repeating: .nan, count: 512)

        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 256)
        }

        #expect(buffer.allSatisfy { $0.isFinite })
    }

    @Test("the chain recovers after a NaN buffer")
    func recoversFromNaNBuffer() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 2)

        var poisoned = [Float](repeating: .nan, count: 512)
        poisoned.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 256)
        }

        // The previous test only proved a NaN buffer comes out finite. This one
        // proves the glitch did not leave the filters poisoned: real audio has
        // to come through afterwards, not silence.
        var clean = sineBuffer(frequency: 1_000, frameCount: 256, amplitude: 0.5)
        clean.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 256)
        }

        #expect(clean.allSatisfy { $0.isFinite })
        #expect(clean.contains { abs($0) > 0.1 })
    }
}
