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

    var capturesVolumeKeys: Bool {
        didSet {
            guard capturesVolumeKeys != oldValue else { return }
            applyVolumeKeyPreference()
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

    /// Set when turning the feature on did not work, so the panel can explain
    /// rather than leaving a toggle that lies.
    private(set) var volumeKeyProblem: String?

    /// How many pills the row offers.
    private static let recentPresetCount = 3

    private let engine: AudioEngineController
    private let volume: SystemVolume
    private let volumeKeys = VolumeKeyTap()
    private let volumeHUD = VolumeHUDController()
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
        self.capturesVolumeKeys = engine.capturesVolumeKeys
        refreshRecentPresets()

        volumeKeys.onKey = { [weak self] key in
            self?.handleVolumeKey(key)
        }

        engine.onStateChange = { [weak self] state in
            Task { @MainActor in self?.engineStateChanged(state) }
        }
        volume.onChange = { [weak self] in
            Task { @MainActor in self?.volumeChanged() }
        }
        engine.onOutputDeviceChange = { [weak self] in
            Task { @MainActor in self?.outputDeviceChanged() }
        }

        if capturesVolumeKeys, AccessibilityPermission.isTrusted {
            do {
                try volumeKeys.start()
            } catch {
                // The same three steps, in the same order, that
                // `applyVolumeKeyPreference()` takes when starting fails: the
                // toggle goes back off, the engine's stored preference follows
                // it, and the reason is recorded last so the panel can explain
                // itself the first time it is opened. They are spelled out
                // rather than left to the `didSet`, because property observers
                // do not run for assignments made inside an initialiser.
                capturesVolumeKeys = false
                engine.setCapturesVolumeKeys(false)
                volumeKeyProblem = error.localizedDescription
            }
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

    /// Opens the Accessibility pane, for when the system will not prompt again.
    func openAccessibilitySettings() {
        AccessibilityPermission.openSettings()
    }

    /// Re-checks whether the tap is still allowed to run, and whether it is.
    ///
    /// `AccessibilityPermission.isTrusted` is a snapshot. Someone can remove
    /// Sonora from the Accessibility list while it runs, and then the tap stops
    /// receiving events with no error at all. The tap can also simply not be
    /// running: starting it at launch can fail while the app is trusted, and a
    /// preference that was saved as on says nothing about whether it took.
    /// Without both checks the checkbox would go on claiming the feature is
    /// active while the keys had quietly gone back to the system.
    ///
    /// The two cases get different messages because the remedies differ: one
    /// needs the permission granted again, the other only another attempt.
    ///
    /// Called when the panel is about to be shown, which is the only moment the
    /// answer matters to anyone looking.
    func refreshVolumeKeyState() {
        guard capturesVolumeKeys else { return }

        // Read once, so the message below describes the state that was tested.
        let isTrusted = AccessibilityPermission.isTrusted
        guard !isTrusted || !volumeKeys.isRunning else { return }

        volumeKeys.stop()
        // Setting this runs its `didSet`, which calls
        // `applyVolumeKeyPreference()` and clears `volumeKeyProblem`, so the
        // message has to be assigned after it rather than before.
        capturesVolumeKeys = false
        engine.setCapturesVolumeKeys(false)
        volumeKeyProblem = isTrusted
            ? "Sonora is not capturing the volume keys, so they stayed with the system. Turn this on again to try once more."
            : "Sonora is no longer trusted for Accessibility, so the volume keys went back to the system."
    }

    /// Starts or stops the tap, asking for permission when it is needed.
    ///
    /// If the app is still untrusted after asking, the toggle goes back off.
    /// A toggle that stays on while nothing is captured is worse than one that
    /// refuses, because the user has no way to tell the difference.
    private func applyVolumeKeyPreference() {
        volumeKeyProblem = nil

        guard capturesVolumeKeys else {
            volumeKeys.stop()
            engine.setCapturesVolumeKeys(false)
            return
        }

        if !AccessibilityPermission.isTrusted {
            AccessibilityPermission.request()
        }

        do {
            try volumeKeys.start()
            engine.setCapturesVolumeKeys(true)
        } catch {
            capturesVolumeKeys = false
            engine.setCapturesVolumeKeys(false)
            volumeKeyProblem = error.localizedDescription
        }
    }

    /// One key press. Steps match the system's own, a sixteenth of full scale.
    ///
    /// The only place that knows a volume key was pressed and that Sonora
    /// acted on it, which is why the overlay is shown from here and from
    /// nowhere else. `volumeChanged()` deliberately does not show it: a change
    /// made in System Settings or by another app is not Sonora's to report,
    /// and popping an overlay for it would be worse than the silence this
    /// feature is fixing.
    private func handleVolumeKey(_ key: VolumeKeyTap.Key) {
        // The tap is the only caller and it is stopped whenever the preference
        // is off, so this is belt and braces. It is here because the rule that
        // nothing is drawn while the feature is off should be readable in the
        // one method that draws.
        guard capturesVolumeKeys else { return }

        switch key {
        case .up:
            // Volume up unmutes, which is what the system's own handler does.
            // Mute is a separate device property from the level, so without
            // this the overlay would show a rising level beside a muted
            // speaker and nothing would come out of it.
            if volume.isMuted {
                volume.isMuted = false
            }
            systemVolume = min(systemVolume + 0.0625, 1)
        case .down:
            // Deliberately not the mirror image, including from zero. The
            // system leaves mute alone on volume down, and a key that means
            // "less" should not be the one that lets the sound back in: an
            // unmute here would be inaudible at zero and then turn the next
            // press into sound the user never asked to hear.
            systemVolume = max(systemVolume - 0.0625, 0)
        case .mute:
            volume.isMuted.toggle()
        }

        // Read back rather than assumed: the mute switch is the device's, and
        // after a step the level is whatever the clamp above settled on.
        volumeHUD.show(level: systemVolume, isMuted: volume.isMuted)
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

    /// The engine rebuilt the audio path around a different output device.
    ///
    /// The state does not change across that rebuild, so `engineStateChanged`
    /// never runs, and the device the panel talks to is a different Core Audio
    /// object afterwards: without the refresh the volume slider would keep
    /// writing to the old one, and the picker would keep offering whatever was
    /// plugged in at launch.
    private func outputDeviceChanged() {
        volume.refresh()
        outputDeviceName = volume.outputDeviceName
        availableOutputs = volume.availableOutputs
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
