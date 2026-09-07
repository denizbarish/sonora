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

    /// The smallest state magnitude the filter keeps. Anything under this is
    /// flushed to zero.
    ///
    /// An IIR filter's state decays exponentially toward zero whenever the input
    /// goes quiet, between tracks or during a fade. Once it reaches subnormal
    /// floats, some CPUs fall back to microcode where a single multiply can cost
    /// hundreds of cycles. That is enough to stall a render callback that is
    /// otherwise allocation free and lock free, so the usual real-time
    /// discipline does not cover it.
    ///
    /// Subnormals start below 1.18e-38. Flushing at 1e-25 stops the decay well
    /// before that, and 1e-25 is roughly -500 dBFS, hundreds of decibels below
    /// the quietest audible sample, so nothing is lost.
    ///
    /// Flushing rather than adding a tiny DC term keeps silence exactly silent:
    /// a zero input into a settled filter still returns exactly zero.
    ///
    /// Both state variables are flushed together or not at all. They are in
    /// quadrature, so on a high Q section they cross any fixed floor at
    /// different samples; zeroing one on its own perturbs the coupled recurrence
    /// and the perturbation sustains itself as a limit cycle that never decays.
    /// A 100 Hz, Q 4, +12 dB section settles into exactly that, oscillating
    /// forever around 2e-23 instead of reaching zero.
    private static let denormalFloor: Float = 1e-25

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
        let next1 = coefficients.b1 * input - coefficients.a1 * output + state2
        let next2 = coefficients.b2 * input - coefficients.a2 * output

        // Both or neither. See the note on `denormalFloor`: flushing one state
        // variable alone leaves the section ringing forever at a level it can
        // never decay past.
        if abs(next1) < Self.denormalFloor, abs(next2) < Self.denormalFloor {
            state1 = 0
            state2 = 0
        } else {
            state1 = next1
            state2 = next2
        }

        return output
    }

    /// Clears the filter memory. Call after a sample rate or format change,
    /// never while audio is flowing, since it produces a discontinuity.
    public mutating func reset() {
        state1 = 0
        state2 = 0
    }
}
