import Atomics
import Foundation

/// Carries parameter changes from the interface thread to the real-time audio
/// thread with no lock and no allocation on the audio side.
///
/// The expensive part of a parameter change is turning bands into biquad
/// coefficients. That happens here, on the interface thread. What crosses to the
/// audio thread is a bool, a float, and a block of finished coefficients.
///
/// Handoff is a seqlock. The writer makes `sequence` odd, writes the payload,
/// then makes it even again. The reader loads `sequence`, copies the payload
/// into its own scratch buffer, and loads `sequence` again: if the two loads
/// disagree, or the first was odd, a write overlapped the copy, so the reader
/// throws its copy away and leaves the chain on the parameters it already had.
/// The next buffer picks the change up a few milliseconds later, which nobody
/// can hear. Committing a half-written coefficient set, on the other hand, means
/// an unstable pole pair and a burst of noise.
///
/// The lock in this class is taken by the interface thread only, to guard the
/// writer against itself. The audio path never touches it, and never blocks.
public final class ParameterBridge: @unchecked Sendable {

    /// The plain-data half of a resolved parameter set. Coefficients live in a
    /// parallel buffer.
    private struct Payload {
        var isBypassed = false
        var preampGain: Float = 1
        var bandCount = 0
    }

    private var sampleRate: Double

    /// Even means settled, odd means a write is in flight.
    ///
    /// `UnsafeAtomic` rather than `ManagedAtomic`, matching `DSPChain`: the
    /// latter is a non-final class, so every access on the render path costs a
    /// metadata load and an indirect call, plus retain traffic in unoptimised
    /// builds.
    private let sequence: UnsafeAtomic<Int>

    /// Copies the render thread threw away because a write overlapped them.
    ///
    /// Bookkeeping, not behaviour. A concurrency test that never actually
    /// interleaved proves nothing, so the test asserts this moved rather than
    /// trusting that an overlap happened.
    private let discarded: UnsafeAtomic<Int>

    private let payload: UnsafeMutablePointer<Payload>
    private let coefficients: UnsafeMutablePointer<BiquadCoefficients>

    /// Reader-side scratch. Only the render thread touches it, which is what
    /// lets the reader validate a copy before handing it to the chain.
    private let scratch: UnsafeMutablePointer<BiquadCoefficients>

    /// Render thread only, so a plain stored property is enough.
    private var appliedSequence = -1

    /// Interface thread only. Never taken by the audio thread.
    private let writerLock = NSLock()
    private var publishedParameters: EngineParameters

    public init(initial: EngineParameters = .defaults, sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        self.publishedParameters = initial
        self.sequence = UnsafeAtomic<Int>.create(0)
        self.discarded = UnsafeAtomic<Int>.create(0)

        let capacity = EqualizerChain.maximumBandCount
        payload = UnsafeMutablePointer<Payload>.allocate(capacity: 1)
        payload.initialize(to: Payload())
        coefficients = UnsafeMutablePointer<BiquadCoefficients>.allocate(capacity: capacity)
        coefficients.initialize(repeating: .identity, count: capacity)
        scratch = UnsafeMutablePointer<BiquadCoefficients>.allocate(capacity: capacity)
        scratch.initialize(repeating: .identity, count: capacity)

        writeLocked(initial)
    }

    deinit {
        sequence.destroy()
        discarded.destroy()
        payload.deinitialize(count: 1)
        payload.deallocate()
        coefficients.deinitialize(count: EqualizerChain.maximumBandCount)
        coefficients.deallocate()
        scratch.deinitialize(count: EqualizerChain.maximumBandCount)
        scratch.deallocate()
    }

    /// The most recently published values. Interface thread.
    public var current: EngineParameters {
        writerLock.lock()
        defer { writerLock.unlock() }
        return publishedParameters
    }

    /// Publishes a new parameter set, resolving its coefficients here.
    /// Interface thread.
    public func publish(_ parameters: EngineParameters) {
        writerLock.lock()
        publishedParameters = parameters
        writeLocked(parameters)
        writerLock.unlock()
    }

    /// Re-resolves the current parameters for a new sample rate and republishes.
    /// Call when the audio format changes, before the render loop starts.
    /// Interface thread.
    public func setSampleRate(_ sampleRate: Double) {
        writerLock.lock()
        self.sampleRate = sampleRate
        writeLocked(publishedParameters)
        writerLock.unlock()
    }

    /// How many copies were discarded because a write overlapped them.
    public var discardedCopyCount: Int {
        discarded.load(ordering: .relaxed)
    }

    /// Applies pending changes to the chain. Real-time thread.
    ///
    /// Costs one atomic load when nothing changed. When something did, copies
    /// the coefficients into scratch, validates, and only then commits.
    public func applyPendingChanges(to chain: DSPChain) {
        let start = sequence.load(ordering: .acquiring)

        // Odd means the writer is mid-update. Equal means nothing new.
        guard start % 2 == 0, start != appliedSequence else { return }

        let snapshot = payload.pointee
        let count = min(max(snapshot.bandCount, 0), EqualizerChain.maximumBandCount)
        for index in 0..<count {
            scratch[index] = coefficients[index]
        }

        // A LoadLoad barrier, then a relaxed re-read. This is the direct
        // translation of the kernel's `smp_rmb(); read_seqretry()`.
        //
        // An acquire load alone is not enough here. Acquire orders what comes
        // after it, and places no constraint on the copy above sinking past it,
        // so a coefficient load could be satisfied after this check had already
        // sampled the pre-write counter. That is precisely the tear this guard
        // exists to reject.
        //
        // If the counter moved, the copy may mix old and new coefficients.
        // Dropping it costs one buffer of staleness; committing it costs an
        // unstable filter.
        atomicMemoryFence(ordering: .acquiring)
        guard sequence.load(ordering: .relaxed) == start else {
            discarded.wrappingIncrement(ordering: .relaxed)
            return
        }

        chain.applyResolved(
            isBypassed: snapshot.isBypassed,
            preampGain: snapshot.preampGain,
            coefficients: scratch,
            count: count
        )
        appliedSequence = start
    }

    /// Writes the payload between an odd and an even sequence value.
    /// Caller holds `writerLock`.
    private func writeLocked(_ parameters: EngineParameters) {
        let computed = EqualizerChain.coefficients(
            for: parameters.bands, sampleRate: sampleRate
        )

        sequence.wrappingIncrement(ordering: .acquiringAndReleasing)

        for offset in 0..<computed.count {
            coefficients[offset] = computed[offset]
        }
        payload.pointee = Payload(
            isBypassed: parameters.isBypassed,
            preampGain: Float(pow(10, parameters.preampDecibels / 20)),
            bandCount: computed.count
        )

        sequence.wrappingIncrement(ordering: .releasing)
    }
}
