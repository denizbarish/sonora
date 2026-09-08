import Testing
import Foundation
@testable import SonoraPersistence
import SonoraProfiles
import SonoraDSP

@Suite("SettingsStore")
struct SettingsStoreTests {

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonora-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("defaults are flat, unbypassed, and use the graphic layout")
    func defaults() {
        let settings = Settings.defaults

        #expect(settings.schemaVersion == Settings.currentSchemaVersion)
        #expect(settings.isBypassed == false)
        #expect(settings.preampDecibels == 0)
        #expect(settings.bands == EqualizerBand.graphicDefaults)
        #expect(settings.activePresetID == BuiltInPresets.flat.id)
        #expect(settings.userPresets.isEmpty)
    }

    @Test("loading from an empty directory returns defaults")
    func loadMissingFile() throws {
        let store = SettingsStore(directory: try makeTemporaryDirectory())

        #expect(store.load() == Settings.defaults)
        #expect(store.lastLoadFailure == .missing)
    }

    @Test("settings survive a save and load round trip")
    func roundTrip() throws {
        let store = SettingsStore(directory: try makeTemporaryDirectory())

        var settings = Settings.defaults
        settings.preampDecibels = -3
        settings.isBypassed = true
        settings.bands[2].gainDecibels = 7
        settings.activePresetID = "custom-1"
        settings.userPresets = [
            Preset(
                id: "custom-1", name: "Mine", preampDecibels: -3,
                gains: [1, 1, 1, 0, 0, 0, 0, 0, 0, 0], isBuiltIn: false
            )
        ]

        try store.save(settings)

        #expect(store.load() == settings)
        #expect(store.lastLoadFailure == nil)
    }

    @Test("a corrupt file falls back to defaults and is backed up")
    func corruptFile() throws {
        let directory = try makeTemporaryDirectory()
        let store = SettingsStore(directory: directory)
        try Data("this is not json".utf8).write(to: store.fileURL)

        #expect(store.load() == Settings.defaults)

        guard case .corrupt(let backupURL) = store.lastLoadFailure else {
            Issue.record("expected a corrupt failure, got \(String(describing: store.lastLoadFailure))")
            return
        }
        let backup = try #require(backupURL, "the file should have been quarantined")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(backup.pathExtension == "corrupt")
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path) == false)
    }

    @Test("a file from a newer schema falls back to defaults")
    func futureVersion() throws {
        let directory = try makeTemporaryDirectory()
        let store = SettingsStore(directory: directory)
        let payload = #"{"schemaVersion": 99, "isBypassed": false, "preampDecibels": 0, "bands": [], "userPresets": []}"#
        try Data(payload.utf8).write(to: store.fileURL)

        #expect(store.load() == Settings.defaults)
        #expect(store.lastLoadFailure == .futureVersion(99))
    }

    @Test("an unreadable file is reported rather than treated as missing")
    func unreadableFile() throws {
        let directory = try makeTemporaryDirectory()
        let store = SettingsStore(directory: directory)
        try Data("{}".utf8).write(to: store.fileURL)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path
            )
        }

        #expect(store.load() == Settings.defaults)
        #expect(store.lastLoadFailure == .unreadable)
    }

    @Test("a user preset cannot claim to be built in")
    func rejectsForgedBuiltInPresets() throws {
        let store = SettingsStore(directory: try makeTemporaryDirectory())

        var settings = Settings.defaults
        settings.userPresets = [
            Preset(
                id: "forged", name: "Forged", preampDecibels: 0,
                gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], isBuiltIn: true
            ),
            Preset(
                id: BuiltInPresets.flat.id, name: "Impostor", preampDecibels: 0,
                gains: [9, 0, 0, 0, 0, 0, 0, 0, 0, 0], isBuiltIn: false
            ),
            Preset(
                id: "genuine", name: "Genuine", preampDecibels: -1,
                gains: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0], isBuiltIn: false
            ),
        ]
        try store.save(settings)

        // The forged built-in and the identifier collision are both dropped;
        // the honest one survives untouched.
        #expect(store.load().userPresets.map(\.id) == ["genuine"])
    }

    @Test("an older schema is reported as stale, not as corrupt")
    func staleVersionIsNotCorruption() throws {
        let directory = try makeTemporaryDirectory()
        let store = SettingsStore(directory: directory)
        let payload = #"{"schemaVersion": 0, "isBypassed": false}"#
        try Data(payload.utf8).write(to: store.fileURL)

        #expect(store.load() == Settings.defaults)
        #expect(store.lastLoadFailure == .staleVersion(0))
        // A recoverable old file must not be quarantined.
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("saving creates the directory if it does not exist")
    func createsDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonora-tests-\(UUID().uuidString)")
        let store = SettingsStore(directory: directory)

        try store.save(Settings.defaults)

        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("the default directory sits under Application Support")
    func defaultDirectory() {
        let path = SettingsStore.defaultDirectory().path

        #expect(path.contains("Application Support"))
        #expect(path.hasSuffix("/Sonora"))
    }

    @Test("dropped presets are reported rather than vanishing quietly")
    func reportsDroppedPresets() throws {
        let store = SettingsStore(directory: try makeTemporaryDirectory())

        var settings = Settings.defaults
        settings.userPresets = [
            Preset(
                id: "forged", name: "Forged", preampDecibels: 0,
                gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], isBuiltIn: true
            ),
            Preset(
                id: "genuine", name: "Genuine", preampDecibels: 0,
                gains: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0], isBuiltIn: false
            ),
        ]
        try store.save(settings)

        #expect(store.load().userPresets.map(\.id) == ["genuine"])
        #expect(store.lastDroppedPresets.map(\.id) == ["forged"])
    }

    @Test("a dropped preset sharing an id with a survivor is still reported")
    func reportsDroppedPresetSharingAnIdentifier() throws {
        let store = SettingsStore(directory: try makeTemporaryDirectory())

        var settings = Settings.defaults
        settings.userPresets = [
            Preset(
                id: "shared", name: "Genuine", preampDecibels: 0,
                gains: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0], isBuiltIn: false
            ),
            Preset(
                id: "shared", name: "Forged", preampDecibels: 0,
                gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], isBuiltIn: true
            ),
        ]
        try store.save(settings)

        let loaded = store.load()
        #expect(loaded.userPresets.map(\.name) == ["Genuine"])
        #expect(store.lastDroppedPresets.map(\.name) == ["Forged"])
    }

    @Test("a clean load reports nothing dropped")
    func cleanLoadDropsNothing() throws {
        let store = SettingsStore(directory: try makeTemporaryDirectory())

        var settings = Settings.defaults
        settings.userPresets = [
            Preset(
                id: "genuine", name: "Genuine", preampDecibels: 0,
                gains: [1, 0, 0, 0, 0, 0, 0, 0, 0, 0], isBuiltIn: false
            ),
        ]
        try store.save(settings)

        #expect(store.load().userPresets.count == 1)
        #expect(store.lastDroppedPresets.isEmpty)
    }

    @Test("a quarantine that cannot be written is reported as such")
    func unquarantinableCorruptFile() throws {
        let directory = try makeTemporaryDirectory()
        let store = SettingsStore(directory: directory)
        try Data("this is not json".utf8).write(to: store.fileURL)

        // A read-only directory means the corrupt file cannot be moved aside.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path
            )
        }

        #expect(store.load() == Settings.defaults)
        #expect(store.lastLoadFailure == .corrupt(backupURL: nil))
    }
}
