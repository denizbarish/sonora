import Foundation

/// A value that moves toward its target along a one-pole exponential ramp.
///
/// Every gain change in the signal path goes through this type. Applying a new
/// gain instantly produces an audible click, so changes are spread over
/// `rampSeconds` worth of samples.
///
/// This is a value type with no allocations, safe to advance from the real-time
/// audio thread. `Sendable` here certifies that copies cross isolation domains
/// safely; it does not make a single shared instance safe to mutate from two
/// threads at once. Owners must not write `target` while another thread calls
/// `nextValue()` on the same instance.
public struct SmoothedValue: Sendable {

    /// The value the ramp is heading toward.
    public var target: Float

    /// The value the ramp has reached.
    public private(set) var current: Float

    private var rampSeconds: Float
    private var coefficient: Float

    public init(value: Float, sampleRate: Double, rampSeconds: Float = 0.030) {
        self.target = value
        self.current = value
        self.rampSeconds = rampSeconds
        self.coefficient = Self.coefficient(sampleRate: sampleRate, rampSeconds: rampSeconds)
    }

    /// Advances the ramp by one sample and returns the new value.
    public mutating func nextValue() -> Float {
        current += (target - current) * coefficient
        return current
    }

    /// Jumps to a value with no ramp. Use when starting the engine or after a
    /// format change, never in response to a user gesture.
    public mutating func snap(to value: Float) {
        target = value
        current = value
    }

    /// Recomputes the ramp for a new sample rate, keeping the duration in seconds.
    public mutating func setSampleRate(_ sampleRate: Double) {
        coefficient = Self.coefficient(sampleRate: sampleRate, rampSeconds: rampSeconds)
    }

    /// A coefficient of 1 means "no smoothing": `nextValue` jumps straight to
    /// the target. That is the deliberate fallback for a nonsensical sample rate
    /// or ramp duration, including NaN, which fails both comparisons. Snapping is
    /// wrong-sounding but safe; a NaN coefficient would poison the whole signal.
    ///
    /// Computed in `Double` and narrowed at the end. This runs in `init` and
    /// `setSampleRate`, never on the audio path, so there is no reason to give up
    /// the precision.
    private static func coefficient(sampleRate: Double, rampSeconds: Float) -> Float {
        guard sampleRate > 0, rampSeconds > 0 else { return 1 }
        return Float(1 - exp(-1 / (sampleRate * Double(rampSeconds))))
    }
}
