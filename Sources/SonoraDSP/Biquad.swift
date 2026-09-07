/// A second order filter section in transposed direct form II.
///
/// Transposed direct form II is the standard choice for floating point audio:
/// it needs two state variables per channel and has better numerical behaviour
/// than direct form I at low frequencies.
///
/// One instance holds the state for one channel. Stereo needs two.
///
/// Processing allocates nothing and takes no locks, so it is safe to call from
/// the real-time audio thread.
public struct Biquad: Sendable {

    /// The filter shape. Assigning new coefficients does not clear the state,
    /// which is what keeps the audio continuous while a slider moves.
    public var coefficients: BiquadCoefficients

    private var state1: Float = 0
    private var state2: Float = 0

    public init(coefficients: BiquadCoefficients = .identity) {
        self.coefficients = coefficients
    }

    /// Filters one sample.
    @inline(__always)
    public mutating func process(_ input: Float) -> Float {
        let output = coefficients.b0 * input + state1
        state1 = coefficients.b1 * input - coefficients.a1 * output + state2
        state2 = coefficients.b2 * input - coefficients.a2 * output
        return output
    }

    /// Clears the filter memory. Call after a sample rate or format change,
    /// never while audio is flowing, since it produces a discontinuity.
    public mutating func reset() {
        state1 = 0
        state2 = 0
    }
}
