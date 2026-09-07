import SonoraDSP

/// A named equalizer setting: a preamp value plus a full set of bands.
public struct Preset: Codable, Equatable, Identifiable, Sendable {

    public let id: String
    public var name: String
    public var preampDecibels: Double
    public var bands: [EqualizerBand]

    /// Built-in presets ship with the app and cannot be edited or deleted.
    public let isBuiltIn: Bool

    public init(
        id: String,
        name: String,
        preampDecibels: Double,
        bands: [EqualizerBand],
        isBuiltIn: Bool
    ) {
        self.id = id
        self.name = name
        self.preampDecibels = preampDecibels
        self.bands = bands
        self.isBuiltIn = isBuiltIn
    }

    /// Builds a preset from ten gain values laid over the graphic band layout.
    public init(
        id: String,
        name: String,
        preampDecibels: Double,
        gains: [Double],
        isBuiltIn: Bool
    ) {
        precondition(
            gains.count == EqualizerBand.graphicFrequencies.count,
            "A graphic preset needs exactly \(EqualizerBand.graphicFrequencies.count) gain values"
        )

        self.init(
            id: id,
            name: name,
            preampDecibels: preampDecibels,
            bands: zip(EqualizerBand.graphicFrequencies, gains).map { frequency, gain in
                EqualizerBand(kind: .peaking, frequency: frequency, q: 1.41, gainDecibels: gain)
            },
            isBuiltIn: isBuiltIn
        )
    }
}
