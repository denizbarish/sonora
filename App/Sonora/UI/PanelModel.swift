import Foundation
import Observation
import SonoraDSP
import SonoraProfiles

/// Everything the panel shows and changes.
///
/// The only type in the interface that talks to `AudioEngineController`. Views
/// bind to this and never reach past it, so the rule that the engine is touched
/// from the main actor lives in exactly one file.
///
/// Band gains are held as a plain `[Double]` rather than `[EqualizerBand]`
/// because that is what a slider binds to. The full band definitions are
/// rebuilt from the graphic layout when publishing, which is also what keeps a
/// slider from silently changing a band's frequency or Q.
@MainActor
@Observable
final class PanelModel {

    let presets: [Preset] = BuiltInPresets.all

    var systemVolume: Float {
        didSet {
            // The device's own listener writes back into this property, so
            // without a guard the two chase each other and the slider jitters
            // under the hand that is dragging it.
            guard abs(systemVolume - volume.scalar) > 0.001 else { return }
            volume.scalar = systemVolume
        }
    }

    var preampDecibels: Double {
        didSet { publish() }
    }

    var isBypassed: Bool {
        didSet { publish() }
    }

    var bandGains: [Double] {
        didSet {
            guard bandGains != oldValue else { return }

            // A hand moved a slider, so this is no longer any named preset.
            // Suppressed while a preset is being applied, which also moves
            // these values.
            if !isApplyingPreset, activePresetID != nil {
                activePresetID = nil
                engine.setActivePresetID(nil)
            }
            publish()
        }
    }

    /// The presets to offer as one-tap pills, most recently used first.
    ///
    /// Padded with the first built-ins until the user has actually used three,
    /// so the row is never empty on a fresh install.
    private(set) var recentPresets: [Preset] = []

    private(set) var activePresetID: String?
    private(set) var outputDeviceName: String
    private(set) var availableOutputs: [SystemVolume.OutputDevice] = []
    private(set) var stateDescription: String
    private(set) var isRunning: Bool

    /// How many pills the row offers.
    private static let recentPresetCount = 3

    private let engine: AudioEngineController
    private let volume: SystemVolume
    private var isApplyingPreset = false

    init(engine: AudioEngineController, volume: SystemVolume) {
        self.engine = engine
        self.volume = volume

        let parameters = engine.parameters
        self.preampDecibels = parameters.preampDecibels
        self.isBypassed = parameters.isBypassed
        self.bandGains = parameters.bands.map(\.gainDecibels)
        self.activePresetID = engine.activePresetID
        self.systemVolume = volume.scalar
        self.outputDeviceName = volume.outputDeviceName
        self.availableOutputs = volume.availableOutputs
        self.stateDescription = Self.describe(engine.state)
        self.isRunning = engine.state == .running
        refreshRecentPresets()

        engine.onStateChange = { [weak self] state in
            Task { @MainActor in self?.engineStateChanged(state) }
        }
        volume.onChange = { [weak self] in
            Task { @MainActor in self?.volumeChanged() }
        }
    }

    /// The curve the view draws, computed from the band definitions rather than
    /// from the live chain, which the audio thread owns.
    func curvePoints(count: Int) -> [CurvePoint] {
        EqualizerCurve.points(
            of: bands(),
            sampleRate: 48_000,
            from: 20,
            to: 20_000,
            count: count
        )
    }

    func selectPreset(_ preset: Preset) {
        // The flag suppresses both the deselect logic and the intermediate
        // publishes the two assignments below would otherwise each trigger.
        // Every publish writes the settings file, so this is one write rather
        // than three.
        isApplyingPreset = true
        bandGains = preset.bands.map(\.gainDecibels)
        preampDecibels = preset.preampDecibels
        isApplyingPreset = false

        activePresetID = preset.id
        engine.setActivePresetID(preset.id)
        refreshRecentPresets()
        publish()
    }

    func selectOutput(_ device: SystemVolume.OutputDevice) {
        volume.selectOutput(device)
    }

    func resetToFlat() {
        selectPreset(BuiltInPresets.flat)
    }

    func retry() {
        engine.retry()
    }

    /// Rebuilds `recentPresets` from what the engine remembers.
    ///
    /// The engine stores identifiers, which outlive the presets they name, so
    /// anything that no longer matches a known preset is dropped rather than
    /// shown as a dead pill.
    private func refreshRecentPresets() {
        let knownPresets = Dictionary(
            presets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let used = engine.recentPresetIDs.compactMap { knownPresets[$0] }

        var result: [Preset] = []
        var seen: Set<String> = []
        for preset in used + presets where result.count < Self.recentPresetCount {
            if seen.insert(preset.id).inserted {
                result.append(preset)
            }
        }
        recentPresets = result
    }

    private func bands() -> [EqualizerBand] {
        zip(EqualizerBand.graphicFrequencies, bandGains).map { frequency, gain in
            EqualizerBand(kind: .peaking, frequency: frequency, q: 1.41, gainDecibels: gain)
        }
    }

    private func publish() {
        guard !isApplyingPreset else { return }

        engine.update(
            EngineParameters(
                isBypassed: isBypassed,
                preampDecibels: preampDecibels,
                bands: bands()
            )
        )
    }

    private func engineStateChanged(_ state: AudioEngineController.State) {
        stateDescription = Self.describe(state)
        isRunning = state == .running
        outputDeviceName = volume.outputDeviceName
    }

    private func volumeChanged() {
        // Same guard in the other direction: only take the device's value when
        // it genuinely differs from what the slider already shows.
        let current = volume.scalar
        if abs(systemVolume - current) > 0.001 {
            systemVolume = current
        }
        outputDeviceName = volume.outputDeviceName
        availableOutputs = volume.availableOutputs
    }

    private static func describe(_ state: AudioEngineController.State) -> String {
        switch state {
        case .stopped: "Stopped"
        case .running: "Running"
        case .bypassed(let reason): reason
        }
    }
}
