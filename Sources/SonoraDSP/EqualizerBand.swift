/// One band of the equalizer.
///
/// The graphic equalizer is a fixed set of these. The parametric mode in a later
/// phase is the same set with every field editable, which is why there is only
/// one band type.
public struct EqualizerBand: Codable, Equatable, Sendable {

    public var kind: FilterKind
    public var frequency: Double
    public var q: Double
    public var gainDecibels: Double

    public init(kind: FilterKind = .peaking, frequency: Double, q: Double = 1.41, gainDecibels: Double = 0) {
        self.kind = kind
        self.frequency = frequency
        self.q = q
        self.gainDecibels = gainDecibels
    }

    /// ISO standard centre frequencies for a ten band graphic equalizer.
    public static let graphicFrequencies: [Double] = [
        32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000
    ]

    /// The default graphic layout: ten flat peaking bands.
    public static let graphicDefaults: [EqualizerBand] = graphicFrequencies.map {
        EqualizerBand(kind: .peaking, frequency: $0, q: 1.41, gainDecibels: 0)
    }

    /// The gain range the interface offers, in decibels.
    public static let gainRange: ClosedRange<Double> = -12...12
}
