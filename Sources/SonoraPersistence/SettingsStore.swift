import SonoraProfiles
import Foundation

/// Reads and writes `Settings` as JSON on disk.
///
/// Loading never throws. A missing, unreadable, corrupt or too-new file returns
/// defaults and records why in `lastLoadFailure`, so the interface can tell the
/// user what happened instead of silently starting over.
public final class SettingsStore {

    public enum LoadFailure: Equatable, Sendable {
        /// No settings file yet. Expected on first launch.
        case missing
        /// The file exists but could not be read from disk.
        case unreadable
        /// The file could not be decoded. `backupURL` is where it was moved,
        /// or nil when it could not be moved at all, in which case the same
        /// file will fail again on the next launch.
        case corrupt(backupURL: URL?)
        /// The file was written by a newer version of Sonora.
        case futureVersion(Int)
        /// The file came from a schema older than anything this build can
        /// decode. Reported separately from `corrupt` so an out of date file is
        /// never mistaken for garbage and quarantined. A file from a schema the
        /// decoder does still read is not this: if it will not decode, it is
        /// corrupt.
        case staleVersion(Int)
    }

    public let fileURL: URL
    public private(set) var lastLoadFailure: LoadFailure?

    /// User presets the last load dropped because they claimed to be built in
    /// or reused a built-in identifier.
    ///
    /// Empty after a clean load. Kept separate from `lastLoadFailure` because
    /// the load itself succeeded: something was cleaned up, nothing was lost to
    /// an error. Without this the correction is invisible, and a preset that
    /// some future bug mislabels would simply disappear on the next launch with
    /// nothing to debug from.
    public private(set) var lastDroppedPresets: [Preset] = []

    private let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("settings.json")
    }

    /// `~/Library/Application Support/Sonora`.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sonora")
    }

    public func load() -> Settings {
        lastDroppedPresets = []

        guard fileManager.fileExists(atPath: fileURL.path) else {
            lastLoadFailure = .missing
            return .defaults
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            lastLoadFailure = .unreadable
            return .defaults
        }

        // Read the version before the full decode, so a version problem is
        // never reported as corruption.
        let storedVersion = (try? JSONDecoder().decode(SchemaEnvelope.self, from: data))?
            .schemaVersion

        if let storedVersion, storedVersion > Settings.currentSchemaVersion {
            lastLoadFailure = .futureVersion(storedVersion)
            return .defaults
        }

        do {
            let settings = try JSONDecoder().decode(Settings.self, from: data)
            lastLoadFailure = nil
            return reconciled(settings)
        } catch {
            if let storedVersion, storedVersion < Settings.oldestDecodableSchemaVersion {
                lastLoadFailure = .staleVersion(storedVersion)
                return .defaults
            }
            lastLoadFailure = .corrupt(backupURL: backUpCorruptFile())
            return .defaults
        }
    }

    /// Strips claims a settings file is not allowed to make.
    ///
    /// `Preset` is `Codable`, so a hand edited or corrupted file can present a
    /// user preset that claims to be built in, or one that reuses a built-in
    /// identifier. The interface refuses to edit or delete built-in presets, so
    /// such an entry becomes a ghost the user cannot remove, and a duplicated
    /// identifier makes every lookup ambiguous. This is the disk boundary, so
    /// this is where those claims are dropped.
    private func reconciled(_ settings: Settings) -> Settings {
        let builtInIdentifiers = Set(BuiltInPresets.all.map(\.id))

        // Each entry's fate is decided once, on its own. Deriving the dropped
        // list afterwards by asking "did anything with this id survive" loses a
        // dropped entry whenever it shares an id with a kept one, which is
        // exactly the duplicated-identifier file this step exists to clean up.
        var kept: [Preset] = []
        var dropped: [Preset] = []
        for preset in settings.userPresets {
            if !preset.isBuiltIn && !builtInIdentifiers.contains(preset.id) {
                kept.append(preset)
            } else {
                dropped.append(preset)
            }
        }

        var result = settings
        result.userPresets = kept
        lastDroppedPresets = dropped
        return result
    }

    public func save(_ settings: Settings) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var stored = settings
        stored.schemaVersion = Settings.currentSchemaVersion

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: fileURL, options: .atomic)
    }

    /// Moves the undecodable file aside so the next launch starts clean while
    /// the user keeps whatever was in it.
    ///
    /// Returns nil when the move fails, for example on a read-only volume or a
    /// full disk. Reporting that honestly matters: the alternative is naming a
    /// backup file that was never written, while the original stays in place
    /// and fails again on every launch with nothing to show for it.
    private func backUpCorruptFile() -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = directory.appendingPathComponent("settings-\(stamp).json.corrupt")

        do {
            try fileManager.moveItem(at: fileURL, to: backupURL)
            return backupURL
        } catch {
            return nil
        }
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }
}
