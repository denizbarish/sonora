import Atomics
import Foundation

/// The complete signal path: preamp, equalizer, limiter.
///
/// One instance is owned by the render loop and processes every buffer that
/// comes out of the process tap. `process` allocates nothing and takes no locks.
///
/// Not thread safe, and the split matches `EqualizerChain`'s.
///
/// - `update(bands:)`, `preampDecibels` and `isBypassed` are the setup path.
///   Set them before the render callback starts, or while it is stopped. Never
///   while audio is flowing: they are plain stored state with no
///   synchronisation, and a concurrent write races the render thread.
/// - `applyResolved` is the live path and runs on the render thread itself,
///   with coefficients already computed on the setup thread.
///
/// `@unchecked Sendable` asserts that callers honour that split. It provides
/// no safety of its own.
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
    /// One limiter per channel, allocated once. Held as a raw buffer rather
    /// than an `Array` for the same reason `EqualizerChain.filters` is: Array
    /// storage does a uniqueness check on access, and the render thread must do
    /// no reference counting at all.
    private let limiters: UnsafeMutableBufferPointer<SoftLimiter>

    /// `UnsafeAtomic` rather than `ManagedAtomic` because the latter is a
    /// class, and touching a class reference on the render thread can emit
    /// retain and release traffic in unoptimised builds.
    private let limiterEngaged: UnsafeAtomic<Bool>

    public init(sampleRate: Double, channelCount: Int) {
        let channels = max(channelCount, 1)
        self.channelCount = channels
        self.equalizer = EqualizerChain(sampleRate: sampleRate, channelCount: channels)
        self.preampRamp = SmoothedValue(value: 1, sampleRate: sampleRate)

        let storage = UnsafeMutableBufferPointer<SoftLimiter>.allocate(capacity: channels)
        storage.initialize(repeating: SoftLimiter())
        self.limiters = storage

        self.limiterEngaged = UnsafeAtomic<Bool>.create(false)
    }

    deinit {
        limiters.deinitialize()
        limiters.deallocate()
        limiterEngaged.destroy()
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
        // A negative frame count would trap in the loops below, and trapping on
        // the audio thread kills the render callback outright.
        guard frameCount > 0 else { return }

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

        // The limiter stage indexes the raw buffer directly: no closure, no
        // Array, no uniqueness check.
        var engaged = false
        for index in 0..<channelCount {
            limiters[index].clearEngagedFlag()
        }

        for frame in 0..<frameCount {
            for channel in 0..<channelCount {
                let offset = frame * channelCount + channel
                buffer[offset] = limiters[channel].process(buffer[offset])
            }
        }

        for index in 0..<channelCount where limiters[index].isEngaged {
            engaged = true
        }

        limiterEngaged.store(engaged, ordering: .releasing)
    }

    /// Clears filter and ramp state. Call after a format change.
    public func reset() {
        equalizer.reset()
        preampRamp.snap(to: preampRamp.target)
        for index in 0..<channelCount {
            limiters[index].clearEngagedFlag()
        }
        limiterEngaged.store(false, ordering: .releasing)
    }
}
