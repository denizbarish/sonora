import Foundation

/// One sampled point of the equalizer's frequency response.
public struct CurvePoint: Equatable, Sendable {
    public let frequency: Double
    public let decibels: Float

    public init(frequency: Double, decibels: Float) {
        self.frequency = frequency
        self.decibels = decibels
    }
}

/// The equalizer's frequency response, computed from band definitions alone.
///
/// This deliberately does not go through `EqualizerChain`. That type's
/// coefficients are written by the audio thread through `applyCoefficients`, so
/// reading them to draw an interface would be an unsynchronised concurrent read
/// of a five float struct: the same tearing the chain's own threading contract
/// warns about, just in the other direction.
///
/// Taking bands by value shares nothing, which also makes the curve trivially
/// testable and safe to compute on any thread.
public enum EqualizerCurve {

    /// The combined response of every band at one frequency, in decibels.
    public static func magnitudeDecibels(
        of bands: [EqualizerBand],
        atFrequency frequency: Double,
        sampleRate: Double
    ) -> Float {
        bands.reduce(Float(0)) { total, band in
            let coefficients = BiquadCoefficients(
                kind: band.kind,
                frequency: band.frequency,
                q: band.q,
                gainDecibels: band.gainDecibels,
                sampleRate: sampleRate
            )
            return total + coefficients.magnitudeDecibels(
                atFrequency: frequency, sampleRate: sampleRate
            )
        }
    }

    /// The response sampled across a frequency range, spaced logarithmically
    /// because that is how the range reads to a listener and how it is drawn.
    public static func points(
        of bands: [EqualizerBand],
        sampleRate: Double,
        from lowest: Double,
        to highest: Double,
        count: Int
    ) -> [CurvePoint] {
        guard count > 0 else { return [] }

        // A non-positive bound makes the ratio below NaN or infinite, and every
        // frequency after the first comes out NaN. This codebase has been bitten
        // by exactly this class once already: an unguarded NaN from a zero
        // sample rate reached the coefficient math and silenced a channel for
        // the life of the process.
        guard lowest > 0, highest > 0 else { return [] }

        guard count > 1 else {
            return [
                CurvePoint(
                    frequency: lowest,
                    decibels: magnitudeDecibels(
                        of: bands, atFrequency: lowest, sampleRate: sampleRate
                    )
                )
            ]
        }

        let ratio = pow(highest / lowest, 1 / Double(count - 1))

        // Coefficients do not depend on the frequency they are evaluated at, so
        // they are built once rather than once per point. At 120 points and ten
        // bands that is ten constructions instead of twelve hundred.
        let coefficients = bands.map { band in
            BiquadCoefficients(
                kind: band.kind,
                frequency: band.frequency,
                q: band.q,
                gainDecibels: band.gainDecibels,
                sampleRate: sampleRate
            )
        }

        return (0..<count).map { index in
            let frequency = lowest * pow(ratio, Double(index))
            let decibels = coefficients.reduce(Float(0)) { total, filter in
                total + filter.magnitudeDecibels(
                    atFrequency: frequency, sampleRate: sampleRate
                )
            }
            return CurvePoint(frequency: frequency, decibels: decibels)
        }
    }
}
