import Foundation

/// The complete signal path: preamp, equalizer, limiter.
///
/// One instance is owned by the render loop and processes every buffer that
/// comes out of the process tap. `process` allocates nothing and takes no locks.
///
/// Not thread safe. The engine calls the setters from the interface thread only
/// through the parameter bridge, which guarantees they never run concurrently
/// with `process`.
public final class DSPChain: @unchecked Sendable {

    /// Digital gain applied before the equalizer, in decibels. This is Sonora's
    /// own gain and is independent of the system output volume.
    ///
    /// Backed by the ramp's target rather than a separate stored property, so
    /// that a real-time `applyResolved` and an interface-side assignment can
    /// never disagree about the current value.
    public var preampDecibels: Double {
        get { 20 * log10(Double(max(preampRamp.target, 1e-6))) }
        set { preampRamp.target = Float(pow(10, newValue / 20)) }
    }

    /// When true, `process` returns the buffer untouched.
    public var isBypassed = false

    private let equalizer: EqualizerChain
    private let channelCount: Int
    private var preampRamp: SmoothedValue
    private var limiters: [SoftLimiter]

    public init(sampleRate: Double, channelCount: Int) {
        self.channelCount = max(channelCount, 1)
        self.equalizer = EqualizerChain(sampleRate: sampleRate, channelCount: channelCount)
        self.preampRamp = SmoothedValue(value: 1, sampleRate: sampleRate)
        self.limiters = Array(repeating: SoftLimiter(), count: max(channelCount, 1))
    }

    /// Replaces the equalizer bands, recomputing coefficients.
    /// Interface thread only.
    public func update(bands: [EqualizerBand]) {
        equalizer.update(bands: bands)
    }

    /// Installs a complete parameter set that was resolved elsewhere.
    ///
    /// Real-time safe: assigns a bool, retargets a ramp, and copies finished
    /// coefficients. No coefficient math, no allocation, no locks.
    public func applyResolved(
        isBypassed: Bool,
        preampGain: Float,
        coefficients: UnsafePointer<BiquadCoefficients>,
        count: Int
    ) {
        self.isBypassed = isBypassed
        preampRamp.target = preampGain
        equalizer.applyCoefficients(coefficients, count: count)
    }

    /// True if the limiter shaped anything since the last buffer.
    public var limiterIsEngaged: Bool {
        limiters.contains { $0.isEngaged }
    }

    /// The equalizer curve at one frequency, in decibels. Excludes the preamp.
    public func magnitudeDecibels(atFrequency frequency: Double) -> Float {
        equalizer.magnitudeDecibels(atFrequency: frequency)
    }

    /// Runs the chain over an interleaved buffer in place.
    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard !isBypassed else { return }

        for index in limiters.indices {
            limiters[index].clearEngagedFlag()
        }

        // Preamp, one ramped gain value per frame shared across channels.
        for frame in 0..<frameCount {
            let gain = preampRamp.nextValue()
            for channel in 0..<channelCount {
                buffer[frame * channelCount + channel] *= gain
            }
        }

        equalizer.process(buffer, frameCount: frameCount)

        limiters.withUnsafeMutableBufferPointer { limiterPointer in
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    let offset = frame * channelCount + channel
                    buffer[offset] = limiterPointer[channel].process(buffer[offset])
                }
            }
        }
    }

    /// Clears filter and ramp state. Call after a format change.
    public func reset() {
        equalizer.reset()
        preampRamp.snap(to: preampRamp.target)
        for index in limiters.indices {
            limiters[index].clearEngagedFlag()
        }
    }
}
