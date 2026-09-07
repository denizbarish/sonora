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
        self.bands = EqualizerBand.graphicDefaults
        self.bandCount = EqualizerBand.graphicDefaults.count

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
    /// Interface thread only: this calls into the coefficient math.
    ///
    /// Filter state is left alone, so a slider move does not click.
    public func update(bands newBands: [EqualizerBand]) {
        let clamped = Array(newBands.prefix(Self.maximumBandCount))
        bands = clamped
        bandCount = clamped.count

        for channel in 0..<channelCount {
            let base = channel * Self.maximumBandCount
            for index in 0..<clamped.count {
                let band = clamped[index]
                filters[base + index].coefficients = BiquadCoefficients(
                    kind: band.kind,
                    frequency: band.frequency,
                    q: band.q,
                    gainDecibels: band.gainDecibels,
                    sampleRate: sampleRate
                )
            }
        }
    }

    /// Installs precomputed coefficients.
    ///
    /// Real-time safe: reads a caller-owned buffer and copies plain floats.
    /// No allocation, no locks, no coefficient math. `bands` is deliberately not
    /// updated, because it is interface-side bookkeeping.
    public func applyCoefficients(_ source: UnsafePointer<BiquadCoefficients>, count: Int) {
        let usable = min(count, Self.maximumBandCount)
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
        guard bandCount > 0 else { return }

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
    /// This is how the parameter bridge does its work on the interface thread.
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
