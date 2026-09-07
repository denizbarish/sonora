import Atomics
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
    ///
    /// The getter floors the linear gain at 1e-6 because `log10(0)` is negative
    /// infinity. A true mute therefore reads back as -120 dB rather than as a
    /// value no interface can render.
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
    private let limiterEngaged = ManagedAtomic<Bool>(false)

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

    /// Whether the limiter shaped anything in the most recently processed
    /// buffer.
    ///
    /// The audio thread writes this once per buffer and the interface thread
    /// reads it to light the overload indicator, so it is genuinely cross
    /// thread. A plain `Bool` would be a data race, and a reader could catch a
    /// buffer part way through and see some channels already re-processed while
    /// others still hold the value from the start of the same buffer. One
    /// atomic, written once per buffer, gives a coherent snapshot instead.
    public var limiterIsEngaged: Bool {
        limiterEngaged.load(ordering: .acquiring)
    }

    /// The equalizer curve at one frequency, in decibels. Excludes the preamp.
    public func magnitudeDecibels(atFrequency frequency: Double) -> Float {
        equalizer.magnitudeDecibels(atFrequency: frequency)
    }

    /// Runs the chain over an interleaved buffer in place.
    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard !isBypassed else {
            // Nothing is being shaped while bypassed, so the indicator must not
            // stay lit from whatever the last processed buffer happened to do.
            limiterEngaged.store(false, ordering: .releasing)
            return
        }

        // Preamp, one ramped gain value per frame shared across channels.
        for frame in 0..<frameCount {
            let gain = preampRamp.nextValue()
            for channel in 0..<channelCount {
                buffer[frame * channelCount + channel] *= gain
            }
        }

        equalizer.process(buffer, frameCount: frameCount)

        // One unsafe buffer pass for the whole limiter stage. Subscripting
        // `limiters` directly would go through Array's uniqueness check on
        // every access, which is exactly the reference counting the audio
        // thread must not do.
        var engaged = false
        limiters.withUnsafeMutableBufferPointer { limiterPointer in
            for index in limiterPointer.indices {
                limiterPointer[index].clearEngagedFlag()
            }

            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    let offset = frame * channelCount + channel
                    buffer[offset] = limiterPointer[channel].process(buffer[offset])
                }
            }

            for index in limiterPointer.indices where limiterPointer[index].isEngaged {
                engaged = true
            }
        }

        limiterEngaged.store(engaged, ordering: .releasing)
    }

    /// Clears filter and ramp state. Call after a format change.
    public func reset() {
        equalizer.reset()
        preampRamp.snap(to: preampRamp.target)
        for index in limiters.indices {
            limiters[index].clearEngagedFlag()
        }
        limiterEngaged.store(false, ordering: .releasing)
    }
}
