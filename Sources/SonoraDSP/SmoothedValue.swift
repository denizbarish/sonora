import Foundation

/// A value that moves toward its target along a one-pole exponential ramp.
///
/// Every gain change in the signal path goes through this type. Applying a new
/// gain instantly produces an audible click, so changes are spread over
/// `rampSeconds` worth of samples.
///
/// This is a value type with no allocations, safe to advance from the real-time
/// audio thread.
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

    private static func coefficient(sampleRate: Double, rampSeconds: Float) -> Float {
        guard sampleRate > 0, rampSeconds > 0 else { return 1 }
        return 1 - exp(-1 / (Float(sampleRate) * rampSeconds))
    }
}
