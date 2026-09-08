import Foundation

/// The filter shapes the equalizer can produce.
public enum FilterKind: String, Codable, Sendable, CaseIterable {
    /// Bell shape. The default for every graphic equalizer band.
    case peaking
    /// Lifts or cuts everything below the corner frequency.
    case lowShelf
    /// Lifts or cuts everything above the corner frequency.
    case highShelf
    /// Removes content below the cutoff frequency.
    case highPass
    /// Removes content above the cutoff frequency.
    case lowPass
}

/// Normalized second order filter coefficients, in direct form.
///
/// Coefficients follow the Audio EQ Cookbook by Robert Bristow-Johnson and are
/// divided through by `a0`, so the difference equation is:
///
///     y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
public struct BiquadCoefficients: Equatable, Sendable {

    public let b0: Float
    public let b1: Float
    public let b2: Float
    public let a1: Float
    public let a2: Float

    /// Coefficients that pass the signal through unchanged.
    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    public init(
        kind: FilterKind,
        frequency: Double,
        q: Double,
        gainDecibels: Double,
        sampleRate: Double
    ) {
        // A sample rate of zero makes every coefficient NaN, and a NaN
        // coefficient cannot be healed the way NaN state can: `output` is
        // computed from it on every sample, so the section emits NaN forever,
        // the limiter turns that into zeroes, and the channel is silent for the
        // life of the process. Core Audio reports a rate of zero for a device
        // whose format has not resolved yet, so this is reachable. Passing the
        // signal through untouched is the safe answer, matching what
        // `SmoothedValue` does for the same degenerate input.
        guard sampleRate > 0 else {
            self = .identity
            return
        }

        // Keep w0 strictly inside (0, pi). This is not NaN protection: a
        // frequency at or above Nyquist is well behaved at any positive sample
        // rate. It just avoids a degenerate filter design at the boundary.
        let nyquist = sampleRate / 2
        let f0 = min(max(frequency, 1), nyquist - 1)
        let safeQ = max(q, 0.0001)

        let a = pow(10, gainDecibels / 40)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * safeQ)

        let b0: Double
        let b1: Double
        let b2: Double
        let a0: Double
        let a1: Double
        let a2: Double

        switch kind {
        case .peaking:
            b0 = 1 + alpha * a
            b1 = -2 * cosW0
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosW0
            a2 = 1 - alpha / a

        case .lowShelf:
            let sqrtA = sqrt(a)
            b0 = a * ((a + 1) - (a - 1) * cosW0 + 2 * sqrtA * alpha)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW0)
            b2 = a * ((a + 1) - (a - 1) * cosW0 - 2 * sqrtA * alpha)
            a0 = (a + 1) + (a - 1) * cosW0 + 2 * sqrtA * alpha
            a1 = -2 * ((a - 1) + (a + 1) * cosW0)
            a2 = (a + 1) + (a - 1) * cosW0 - 2 * sqrtA * alpha

        case .highShelf:
            let sqrtA = sqrt(a)
            b0 = a * ((a + 1) + (a - 1) * cosW0 + 2 * sqrtA * alpha)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
            b2 = a * ((a + 1) + (a - 1) * cosW0 - 2 * sqrtA * alpha)
            a0 = (a + 1) - (a - 1) * cosW0 + 2 * sqrtA * alpha
            a1 = 2 * ((a - 1) - (a + 1) * cosW0)
            a2 = (a + 1) - (a - 1) * cosW0 - 2 * sqrtA * alpha

        case .highPass:
            b0 = (1 + cosW0) / 2
            b1 = -(1 + cosW0)
            b2 = (1 + cosW0) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW0
            a2 = 1 - alpha

        case .lowPass:
            b0 = (1 - cosW0) / 2
            b1 = 1 - cosW0
            b2 = (1 - cosW0) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW0
            a2 = 1 - alpha
        }

        self.b0 = Float(b0 / a0)
        self.b1 = Float(b1 / a0)
        self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0)
        self.a2 = Float(a2 / a0)
    }

    /// The magnitude of the filter's frequency response, in decibels.
    ///
    /// Evaluates the transfer function on the unit circle. Used by tests to check
    /// the coefficients against theory, and by the interface to draw the curve.
    public func magnitudeDecibels(atFrequency frequency: Double, sampleRate: Double) -> Float {
        let w = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w)
        let sinW = sin(w)
        let cos2W = cos(2 * w)
        let sin2W = sin(2 * w)

        let numeratorReal = Double(b0) + Double(b1) * cosW + Double(b2) * cos2W
        let numeratorImaginary = -(Double(b1) * sinW + Double(b2) * sin2W)
        let denominatorReal = 1 + Double(a1) * cosW + Double(a2) * cos2W
        let denominatorImaginary = -(Double(a1) * sinW + Double(a2) * sin2W)

        let numeratorMagnitude = sqrt(
            numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary
        )
        let denominatorMagnitude = sqrt(
            denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary
        )

        guard denominatorMagnitude > 0, numeratorMagnitude > 0 else { return -120 }
        return Float(20 * log10(numeratorMagnitude / denominatorMagnitude))
    }
}
