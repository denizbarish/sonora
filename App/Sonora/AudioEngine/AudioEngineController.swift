import CoreAudio
import Foundation
import OSLog
import SonoraDSP
import SonoraPersistence

/// Owns the whole audio path and every state transition in it.
///
/// The controller guarantees the rule from the design document: any failure ends
/// in bypass, which means the tap is destroyed and the system's own audio route
/// is back. It never leaves the user without sound.
@MainActor
final class AudioEngineController {

    enum State: Equatable {
        case stopped
        case running
        /// Not processing. The string explains why, for the menu.
        case bypassed(String)
    }

    private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    var onStateChange: ((State) -> Void)?

    /// Called after the audio path has been rebuilt around a different output
    /// device.
    ///
    /// Separate from `onStateChange` because a device change does not change
    /// the state: the engine was running before it and is running after it, so
    /// that callback never fires and whoever is showing the device name would
    /// otherwise keep showing the old one.
    var onOutputDeviceChange: (() -> Void)?

    private let settingsStore: SettingsStore
    private let bridge: ParameterBridge
    private let logger = Logger(subsystem: "com.sonora.Sonora", category: "Engine")

    private var tap = ProcessTap()
    private var aggregate: AggregateDevice?
    private var renderLoop: RenderLoop?
    private var chain: DSPChain?
    private var watcher: DeviceWatcher?

    private var settings: Settings
    private var deviceChangeTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var hasPendingSave = false

    /// How long after the last change the settings file is written.
    ///
    /// Long enough that a drag writes once when the hand stops rather than on
    /// every frame, short enough that any ordinary way of leaving the app
    /// reaches the write first.
    private static let saveDelay: Duration = .milliseconds(400)

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        let loaded = settingsStore.load()
        self.settings = loaded
        self.bridge = ParameterBridge(
            initial: EngineParameters(
                isBypassed: loaded.isBypassed,
                preampDecibels: loaded.preampDecibels,
                bands: loaded.bands
            )
        )
    }

    var parameters: EngineParameters { bridge.current }

    /// Publishes new parameters and persists them.
    ///
    /// The publish is immediate, because it is the real-time path and the point
    /// of the panel. The write is not: see `scheduleSave()`.
    func update(_ parameters: EngineParameters) {
        bridge.publish(parameters)

        settings.isBypassed = parameters.isBypassed
        settings.preampDecibels = parameters.preampDecibels
        settings.bands = parameters.bands
        scheduleSave()
    }

    /// Records which preset the user picked, alongside the bands it produced.
    ///
    /// Picking one also moves it to the front of the recent list. A nil
    /// identifier means a slider moved and the curve is no longer any named
    /// preset: that clears the selection but leaves the recent list alone,
    /// because the user did reach for that preset a moment ago.
    func setActivePresetID(_ id: String?) {
        settings.activePresetID = id
        if let id {
            var recent = settings.recentPresetIDs
            recent.removeAll { $0 == id }
            recent.insert(id, at: 0)
            settings.recentPresetIDs = Array(recent.prefix(Settings.maximumRecentPresets))
        }
        scheduleSave()
    }

    /// Writes the settings file a little after the last change instead of on
    /// every one.
    ///
    /// `bandGains` publishes from `didSet`, so a drag arrives here once per
    /// frame, and `SettingsStore.save` pretty-prints the whole file and writes
    /// it atomically: a temporary file and a rename, on the main actor, per
    /// frame. The in-memory `settings` is already current by the time this is
    /// called, so only the write is deferred.
    private func scheduleSave() {
        hasPendingSave = true
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.writePendingSave()
        }
    }

    /// Writes whatever the debounce is still holding, right now.
    private func flushPendingSave() {
        saveTask?.cancel()
        saveTask = nil
        writePendingSave()
    }

    private func writePendingSave() {
        guard hasPendingSave else { return }
        hasPendingSave = false

        do {
            try settingsStore.save(settings)
        } catch {
            logger.error("Could not save settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    var activePresetID: String? { settings.activePresetID }

    /// Identifiers of the presets the user picked, most recent first.
    var recentPresetIDs: [String] { settings.recentPresetIDs }

    var capturesVolumeKeys: Bool { settings.capturesVolumeKeys }

    /// Records the preference. The tap itself is owned by the interface, which
    /// is where the permission conversation belongs.
    func setCapturesVolumeKeys(_ enabled: Bool) {
        settings.capturesVolumeKeys = enabled
        scheduleSave()
    }

    func start() {
        guard state != .running else { return }

        let watcher = DeviceWatcher { [weak self] in
            Task { @MainActor in self?.scheduleOutputDeviceChange() }
        }
        do {
            try watcher.start()
        } catch {
            logger.error("Could not start device watcher: \(error.localizedDescription, privacy: .public)")
        }
        self.watcher = watcher

        buildAudioPath()
    }

    func stop() {
        // Before anything else: quitting must not lose the last change, and
        // `AppDelegate.applicationWillTerminate` gets here.
        flushPendingSave()

        watcher?.stop()
        watcher = nil
        deviceChangeTask?.cancel()
        deviceChangeTask = nil
        tearDownAudioPath()
        state = .stopped
    }

    /// Builds tap, aggregate and render loop. Any failure lands in bypass.
    private func buildAudioPath() {
        do {
            try tap.activate()

            let aggregate = AggregateDevice(tap: tap)
            try aggregate.create()
            self.aggregate = aggregate

            // The output format, not the tap's. The chain indexes the output
            // buffer, so it has to be built for the shape of that buffer.
            let format = try aggregate.outputStreamDescription()
            let chainChannelCount = Int(format.mChannelsPerFrame)
            let chain = DSPChain(
                sampleRate: format.mSampleRate,
                channelCount: chainChannelCount
            )
            // Resolve coefficients for the real format before any audio flows.
            // This also republishes, so the first buffer picks the values up.
            bridge.setSampleRate(format.mSampleRate)
            self.chain = chain

            let bridge = self.bridge
            let renderLoop = RenderLoop(aggregate: aggregate)
            renderLoop.processBlock = { buffer, frameCount, channelCount in
                // The chain indexes the buffer with its own channel count. If
                // the device is handing us a different shape, processing would
                // write past the end of the buffer, and the chain cannot be
                // rebuilt from the render thread. Returning leaves the straight
                // copy the render loop already made, so audio still passes.
                guard channelCount == chainChannelCount else { return }

                bridge.applyPendingChanges(to: chain)
                chain.process(buffer, frameCount: frameCount)
            }
            try renderLoop.start()
            self.renderLoop = renderLoop

            state = .running
            logger.info("Engine running at \(format.mSampleRate, privacy: .public) Hz")
        } catch {
            tearDownAudioPath()
            state = .bypassed(error.localizedDescription)
            logger.error("Engine bypassed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Destroys everything, which returns audio to the normal system route.
    private func tearDownAudioPath() {
        renderLoop?.stop()
        renderLoop = nil
        aggregate?.destroy()
        aggregate = nil
        chain = nil
        tap.invalidate()
    }

    /// Coalesces a burst of device notifications into one rebuild.
    ///
    /// Plugging in headphones emits several default-output changes back to
    /// back. Rebuilding for each one means several teardowns, several new taps,
    /// and an audible gap for each.
    private func scheduleOutputDeviceChange() {
        deviceChangeTask?.cancel()
        deviceChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.handleOutputDeviceChange()
        }
    }

    /// Rebuilds the path around the new output device, preserving settings.
    private func handleOutputDeviceChange() {
        // A notification already in flight when stop() ran still arrives, and
        // rebuilding here would take the engine back to .running after a
        // deliberate .stopped.
        guard state != .stopped else { return }

        // Several notifications can name the device we are already built on.
        if let current = try? AudioObjectID.readDefaultOutputDevice(),
           current == aggregate?.outputDeviceID {
            return
        }

        logger.info("Default output device changed, rebuilding")
        tearDownAudioPath()

        // A fresh tap object: the old one belonged to the torn down aggregate.
        tap = ProcessTap()
        buildAudioPath()

        // After the rebuild, so anyone reading the current device reads the one
        // the engine actually settled on.
        onOutputDeviceChange?()
    }

    /// Tries to leave bypass and run again. Called from the menu.
    func retry() {
        tearDownAudioPath()
        tap = ProcessTap()
        buildAudioPath()
    }
}
