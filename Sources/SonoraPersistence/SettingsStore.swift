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
        /// The file could not be decoded and was moved aside.
        case corrupt(backupURL: URL)
        /// The file was written by a newer version of Sonora.
        case futureVersion(Int)
    }

    public let fileURL: URL
    public private(set) var lastLoadFailure: LoadFailure?

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
        guard fileManager.fileExists(atPath: fileURL.path) else {
            lastLoadFailure = .missing
            return .defaults
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            lastLoadFailure = .unreadable
            return .defaults
        }

        // Read the version before the full decode, so a newer file is reported as
        // a version problem rather than as corruption.
        if let envelope = try? JSONDecoder().decode(SchemaEnvelope.self, from: data),
           envelope.schemaVersion > Settings.currentSchemaVersion {
            lastLoadFailure = .futureVersion(envelope.schemaVersion)
            return .defaults
        }

        do {
            let settings = try JSONDecoder().decode(Settings.self, from: data)
            lastLoadFailure = nil
            return settings
        } catch {
            lastLoadFailure = .corrupt(backupURL: backUpCorruptFile())
            return .defaults
        }
    }

    public func save(_ settings: Settings) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var stored = settings
        stored.schemaVersion = Settings.currentSchemaVersion

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: fileURL, options: .atomic)
    }

    /// Moves the unreadable file aside so the next launch starts clean while the
    /// user keeps whatever was in it.
    private func backUpCorruptFile() -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = directory.appendingPathComponent("settings-\(stamp).json.corrupt")
        try? fileManager.moveItem(at: fileURL, to: backupURL)
        return backupURL
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }
}
