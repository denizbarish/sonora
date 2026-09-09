import SonoraDSP
import SonoraProfiles

/// Everything Sonora remembers between launches.
///
/// The schema is versioned. `SettingsStore` refuses to read a file written by a
/// newer version rather than guessing at fields it does not understand.
public struct Settings: Codable, Equatable, Sendable {

    public static let currentSchemaVersion = 2

    /// How many recently used preset identifiers are kept on disk.
    ///
    /// More than the interface shows, so the row still has something to fall
    /// back on after a preset it was offering is deleted.
    public static let maximumRecentPresets = 8

    public var schemaVersion: Int
    public var isBypassed: Bool
    public var preampDecibels: Double
    public var bands: [EqualizerBand]
    public var activePresetID: String?
    public var userPresets: [Preset]

    /// Identifiers of the presets the user picked, most recent first.
    ///
    /// Identifiers rather than presets, because a preset can be renamed or
    /// edited and the list should follow it rather than keep a stale copy. An
    /// identifier that no longer names anything is simply skipped by whoever
    /// reads this.
    public var recentPresetIDs: [String]

    public init(
        schemaVersion: Int = Settings.currentSchemaVersion,
        isBypassed: Bool = false,
        preampDecibels: Double = 0,
        bands: [EqualizerBand] = EqualizerBand.graphicDefaults,
        activePresetID: String? = BuiltInPresets.flat.id,
        userPresets: [Preset] = [],
        recentPresetIDs: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.isBypassed = isBypassed
        self.preampDecibels = preampDecibels
        self.bands = bands
        self.activePresetID = activePresetID
        self.userPresets = userPresets
        self.recentPresetIDs = recentPresetIDs
    }

    /// Decoded by hand so that a file written before `recentPresetIDs` existed
    /// still loads.
    ///
    /// The synthesised decoder would demand the new key, so every settings file
    /// already on disk would fail to decode, be reported as corrupt, get
    /// quarantined, and leave the user with a flat equalizer. Its absence is not
    /// an error: it means nothing has been used yet.
    ///
    /// Every key that existed before stays required, so a genuinely broken or
    /// truncated file is still recognised as one.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.isBypassed = try container.decode(Bool.self, forKey: .isBypassed)
        self.preampDecibels = try container.decode(Double.self, forKey: .preampDecibels)
        self.bands = try container.decode([EqualizerBand].self, forKey: .bands)
        self.activePresetID = try container.decodeIfPresent(String.self, forKey: .activePresetID)
        self.userPresets = try container.decode([Preset].self, forKey: .userPresets)
        self.recentPresetIDs = try container.decodeIfPresent(
            [String].self, forKey: .recentPresetIDs
        ) ?? []
    }

    public static let defaults = Settings()
}
