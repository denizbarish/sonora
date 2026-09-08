/// A cascade of biquad sections applied to an interleaved audio buffer.
///
/// Filter state lives in one flat buffer allocated once at construction and
/// sized for the maximum band count. Nothing on the audio path touches Swift
/// `Array` storage, so `process` and `applyCoefficients` allocate nothing, take
/// no locks, and do no reference counting.
///
/// The thread split is deliberate. Coefficients are expensive to compute and are
/// produced on the interface thread, either through `update(bands:)` or through
/// the static `coefficients(for:sampleRate:)` helper. The audio thread only ever
/// calls `applyCoefficients`, which copies finished floats.
///
/// ## Threading contract
///
/// This is a contract, not a suggestion. The chain has no internal
/// synchronisation, and `@unchecked Sendable` asserts that callers honour the
/// split below rather than providing any safety itself.
///
/// - `update(bands:)` is the setup path. Call it before the render callback
///   starts, or while it is stopped. Never while audio is flowing.
/// - `applyCoefficients` is the live path. Call it only from the render callback
///   itself, with coefficients already resolved on the setup thread and handed
///   across as finished floats.
///
/// Calling `update(bands:)` while the render callback runs is a data race. A
/// five float coefficient set has no atomic store, so the audio thread can read
/// a torn mix of old and new values and land on an unstable pole pair, which is
/// audible as a burst of noise rather than the click the split exists to avoid.
public final class EqualizerChain: @unchecked Sendable {

    /// Upper bound on bands, so storage is allocated once. The graphic
    /// equalizer uses ten; the parametric mode in a later phase stays under this.
    public static let maximumBandCount = 32

    public private(set) var bands: [EqualizerBand]

    private let sampleRate: Double
    private let channelCount: Int

    /// `channelCount * maximumBandCount` filters, laid out channel-major.
    private let filters: UnsafeMutableBufferPointer<Biquad>

    /// How many of the per-channel slots are in use.
    private var bandCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        let channels = max(channelCount, 1)
        self.sampleRate = sampleRate
        self.channelCount = channels
        // Left empty on purpose: `update` below is the single source of truth
        // for both, and setting them here would only make the coefficient work
        // it does look like it had already happened.
        self.bands = []
        self.bandCount = 0

        let storage = UnsafeMutableBufferPointer<Biquad>.allocate(
            capacity: channels * Self.maximumBandCount
        )
        storage.initialize(repeating: Biquad())
        self.filters = storage

        update(bands: EqualizerBand.graphicDefaults)
    }

    deinit {
        filters.deinitialize()
        filters.deallocate()
    }

    /// Replaces the band definitions and recomputes coefficients.
    ///
    /// Setup path only. See the threading contract on the type: call this before
    /// the render callback starts, or while it is stopped, never while audio is
    /// flowing. Live changes go through `applyCoefficients` instead.
    ///
    /// Filter state is left alone, which is what lets the chain be reconfigured
    /// and restarted without a discontinuity.
    public func update(bands newBands: [EqualizerBand]) {
        let clamped = Array(newBands.prefix(Self.maximumBandCount))
        bands = clamped
        bandCount = clamped.count

        // Every channel gets the same coefficients, so the trigonometry runs
        // once per band rather than once per band per channel.
        for index in 0..<clamped.count {
            let band = clamped[index]
            let computed = BiquadCoefficients(
                kind: band.kind,
                frequency: band.frequency,
                q: band.q,
                gainDecibels: band.gainDecibels,
                sampleRate: sampleRate
            )
            for channel in 0..<channelCount {
                filters[channel * Self.maximumBandCount + index].coefficients = computed
            }
        }
    }

    /// Installs precomputed coefficients.
    ///
    /// Real-time safe: reads a caller-owned buffer and copies plain floats.
    /// No allocation, no locks, no coefficient math. `bands` is deliberately not
    /// updated, because it is interface-side bookkeeping.
    public func applyCoefficients(_ source: UnsafePointer<BiquadCoefficients>, count: Int) {
        // A negative count would make `0..<usable` trap, and trapping on the
        // audio thread kills the render callback outright.
        //
        // Every channel below shares this one bound, which is also what makes a
        // wrong bound detectable: the last channel's pass would run off the end
        // of the whole allocation and trip the debug bounds check. Give each
        // channel its own bound and that safety net disappears.
        let usable = min(max(count, 0), Self.maximumBandCount)
        bandCount = usable

        for channel in 0..<channelCount {
            let base = channel * Self.maximumBandCount
            for index in 0..<usable {
                filters[base + index].coefficients = source[index]
            }
        }
    }

    /// Filters an interleaved buffer in place. Real-time safe.
    ///
    /// - Parameters:
    ///   - buffer: interleaved samples, `frameCount * channelCount` of them.
    ///   - frameCount: number of frames, not samples.
    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard bandCount > 0, frameCount > 0 else { return }

        for channel in 0..<channelCount {
            let base = channel * Self.maximumBandCount
            for frame in 0..<frameCount {
                let offset = frame * channelCount + channel
                var sample = buffer[offset]
                for index in 0..<bandCount {
                    sample = filters[base + index].process(sample)
                }
                buffer[offset] = sample
            }
        }
    }

    /// Clears every filter's memory. Call after a format change.
    public func reset() {
        for index in 0..<(channelCount * Self.maximumBandCount) {
            filters[index].reset()
        }
    }

    /// The combined response of the active bands at one frequency, in decibels.
    /// Used to draw the equalizer curve.
    ///
    /// Reads channel zero's slots, which start at offset zero, because every
    /// channel always holds identical coefficients. If per-channel bands are
    /// ever added, this has to take a channel argument.
    public func magnitudeDecibels(atFrequency frequency: Double) -> Float {
        var total: Float = 0
        for index in 0..<bandCount {
            total += filters[index].coefficients.magnitudeDecibels(
                atFrequency: frequency, sampleRate: sampleRate
            )
        }
        return total
    }

    /// Computes coefficients for a band list without touching a chain.
    ///
    /// This is the setup-thread half of the split: resolve here, then hand the
    /// result to `applyCoefficients` on the render thread.
    public static func coefficients(
        for bands: [EqualizerBand],
        sampleRate: Double
    ) -> [BiquadCoefficients] {
        bands.prefix(maximumBandCount).map { band in
            BiquadCoefficients(
                kind: band.kind,
                frequency: band.frequency,
                q: band.q,
                gainDecibels: band.gainDecibels,
                sampleRate: sampleRate
            )
        }
    }
}
