import SonoraDSP
import SonoraProfiles

/// Everything Sonora remembers between launches.
///
/// The schema is versioned. `SettingsStore` refuses to read a file written by a
/// newer version rather than guessing at fields it does not understand.
public struct Settings: Codable, Equatable, Sendable {

    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var isBypassed: Bool
    public var preampDecibels: Double
    public var bands: [EqualizerBand]
    public var activePresetID: String?
    public var userPresets: [Preset]

    public init(
        schemaVersion: Int = Settings.currentSchemaVersion,
        isBypassed: Bool = false,
        preampDecibels: Double = 0,
        bands: [EqualizerBand] = EqualizerBand.graphicDefaults,
        activePresetID: String? = BuiltInPresets.flat.id,
        userPresets: [Preset] = []
    ) {
        self.schemaVersion = schemaVersion
        self.isBypassed = isBypassed
        self.preampDecibels = preampDecibels
        self.bands = bands
        self.activePresetID = activePresetID
        self.userPresets = userPresets
    }

    public static let defaults = Settings()
}
