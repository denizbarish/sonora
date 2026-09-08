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

    private let settingsStore: SettingsStore
    private let bridge: ParameterBridge
    private let logger = Logger(subsystem: "com.sonora.Sonora", category: "Engine")

    private var tap = ProcessTap()
    private var aggregate: AggregateDevice?
    private var renderLoop: RenderLoop?
    private var chain: DSPChain?
    private var watcher: DeviceWatcher?

    private var settings: Settings

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
    func update(_ parameters: EngineParameters) {
        bridge.publish(parameters)

        settings.isBypassed = parameters.isBypassed
        settings.preampDecibels = parameters.preampDecibels
        settings.bands = parameters.bands
        do {
            try settingsStore.save(settings)
        } catch {
            logger.error("Could not save settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Records which preset the user picked, alongside the bands it produced.
    func setActivePresetID(_ id: String?) {
        settings.activePresetID = id
        try? settingsStore.save(settings)
    }

    var activePresetID: String? { settings.activePresetID }

    func start() {
        guard state != .running else { return }

        let watcher = DeviceWatcher { [weak self] in
            self?.handleOutputDeviceChange()
        }
        watcher.start()
        self.watcher = watcher

        buildAudioPath()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
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

            let format = try tap.streamDescription()
            let chain = DSPChain(
                sampleRate: format.mSampleRate,
                channelCount: Int(format.mChannelsPerFrame)
            )
            // Resolve coefficients for the real format before any audio flows.
            // This also republishes, so the first buffer picks the values up.
            bridge.setSampleRate(format.mSampleRate)
            self.chain = chain

            let bridge = self.bridge
            let renderLoop = RenderLoop(aggregate: aggregate)
            renderLoop.processBlock = { buffer, frameCount, _ in
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

    /// Rebuilds the path around the new output device, preserving settings.
    private func handleOutputDeviceChange() {
        logger.info("Default output device changed, rebuilding")
        tearDownAudioPath()

        // A fresh tap object: the old one belonged to the torn down aggregate.
        tap = ProcessTap()
        buildAudioPath()
    }

    /// Tries to leave bypass and run again. Called from the menu.
    func retry() {
        tearDownAudioPath()
        tap = ProcessTap()
        buildAudioPath()
    }
}
