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
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(backupURL.pathExtension == "corrupt")
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
}
