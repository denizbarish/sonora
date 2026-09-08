/// The presets that ship with the app.
///
/// Gains are ordered along the graphic band layout:
/// 32, 64, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz.
///
/// Presets that boost carry a negative preamp so the total does not slam into
/// the limiter on loud material.
public enum BuiltInPresets {

    public static let flat = Preset(
        id: "builtin.flat",
        name: "Flat",
        preampDecibels: 0,
        gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        isBuiltIn: true
    )

    public static let bassBoost = Preset(
        id: "builtin.bass-boost",
        name: "Bass Boost",
        preampDecibels: -3,
        gains: [8, 7, 5, 2, 0, 0, 0, 0, 0, 0],
        isBuiltIn: true
    )

    public static let trebleBoost = Preset(
        id: "builtin.treble-boost",
        name: "Treble Boost",
        preampDecibels: -2,
        gains: [0, 0, 0, 0, 0, 1, 3, 5, 6, 6],
        isBuiltIn: true
    )

    public static let vocal = Preset(
        id: "builtin.vocal",
        name: "Vocal",
        preampDecibels: -1,
        gains: [-3, -2, 0, 2, 4, 4, 3, 1, 0, -1],
        isBuiltIn: true
    )

    public static let loudness = Preset(
        id: "builtin.loudness",
        name: "Loudness",
        preampDecibels: -4,
        gains: [7, 5, 2, 0, -1, -1, 0, 2, 5, 6],
        isBuiltIn: true
    )

    public static let podcast = Preset(
        id: "builtin.podcast",
        name: "Podcast",
        preampDecibels: 0,
        gains: [-6, -4, -1, 2, 3, 3, 2, 1, -1, -3],
        isBuiltIn: true
    )

    /// Compensates for the thin low end of built-in laptop speakers without
    /// asking them for bass they physically cannot produce.
    public static let laptopSpeaker = Preset(
        id: "builtin.laptop-speaker",
        name: "Laptop Speaker",
        preampDecibels: -2,
        gains: [0, 2, 5, 3, -1, -2, 0, 3, 4, 2],
        isBuiltIn: true
    )

    public static let all: [Preset] = [
        flat, bassBoost, trebleBoost, vocal, loudness, podcast, laptopSpeaker
    ]
}
