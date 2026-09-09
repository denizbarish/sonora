import CoreAudio
import Foundation
import OSLog

/// The system output volume, which is the thing the top slider in the panel
/// moves. Distinct from Sonora's preamp, which is its own digital gain applied
/// inside the equalizer chain.
///
/// Main actor isolated: every caller is the interface, and the property
/// listener hops here before reporting.
@MainActor
final class SystemVolume {

    /// Called when the volume, the mute state, or the output device changes.
    var onChange: (() -> Void)?

    private(set) var outputDeviceName = "Unknown"

    /// One device the panel can switch to.
    struct OutputDevice: Identifiable, Equatable {
        let id: AudioObjectID
        let name: String
    }

    private var deviceID = AudioObjectID.unknown
    private let logger = Logger(subsystem: "com.sonora.Sonora", category: "SystemVolume")
    private let queue = DispatchQueue(label: "com.sonora.SystemVolume")
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        refresh()
    }

    deinit {
        // Listener removal needs the same addresses it registered with; the
        // objects die with the process anyway, so nothing is leaked in practice.
    }

    /// 0 to 1. Reads and writes `kAudioDevicePropertyVolumeScalar` on the
    /// output scope's main element.
    var scalar: Float {
        get {
            guard deviceID.isValid else { return 0 }
            var address = Self.volumeAddress
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)

            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
            guard status == noErr else { return 0 }
            return value
        }
        set {
            guard deviceID.isValid else { return }
            var address = Self.volumeAddress
            var value = Float32(min(max(newValue, 0), 1))
            let size = UInt32(MemoryLayout<Float32>.size)

            let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
            if status != noErr {
                logger.error("Could not set output volume: \(status, privacy: .public)")
            }
        }
    }

    var isMuted: Bool {
        get {
            guard deviceID.isValid else { return false }
            var address = Self.muteAddress
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)

            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
            guard status == noErr else { return false }
            return value != 0
        }
        set {
            guard deviceID.isValid else { return }
            var address = Self.muteAddress
            var value: UInt32 = newValue ? 1 : 0
            let size = UInt32(MemoryLayout<UInt32>.size)

            let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
            if status != noErr {
                logger.error("Could not set mute: \(status, privacy: .public)")
            }
        }
    }

    /// Every device that can play audio, for the panel's output picker.
    private(set) var availableOutputs: [OutputDevice] = []

    /// Makes a device the system default. The engine's own device watcher
    /// notices and rebuilds the audio path around it, so nothing here has to.
    func selectOutput(_ device: OutputDevice) {
        var address = Self.defaultOutputDeviceAddress
        var id = device.id
        let size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectSetPropertyData(
            AudioObjectID.system, &address, 0, nil, size, &id
        )
        if status != noErr {
            logger.error("Could not switch output device: \(status, privacy: .public)")
        }
    }

    /// Enumerates devices that have at least one output channel, minus the
    /// aggregates.
    private func readAvailableOutputs() -> [OutputDevice] {
        var address = Self.devicesAddress

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID.system, &address, 0, nil, &size
        ) == noErr else { return [] }

        var ids = [AudioObjectID](
            repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID.system, &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasOutputChannels(id),
                  !isAggregate(id),
                  let name = try? id.readString(kAudioObjectPropertyName) else {
                return nil
            }
            return OutputDevice(id: id, name: name)
        }
    }

    /// True for aggregate devices, which is how Sonora's own aggregate is kept
    /// out of the picker.
    ///
    /// The engine builds it with `kAudioAggregateDeviceIsPrivateKey`, which
    /// hides it from other processes but not from this one, and this scan runs
    /// in the process that created it. Offering it as an output would rebuild
    /// the audio path around the device that rebuild is about to destroy.
    ///
    /// A device whose transport cannot be read is kept: a real device missing
    /// from the picker is worse than one stray entry in it.
    private func isAggregate(_ device: AudioObjectID) -> Bool {
        guard let transport = try? device.readUInt32(kAudioDevicePropertyTransportType) else {
            return false
        }
        return transport == kAudioDeviceTransportTypeAggregate
    }

    private func hasOutputChannels(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
            return false
        }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    /// Re-reads the default output device and re-registers listeners on it.
    /// Call after the engine reports a device change.
    func refresh() {
        removeListeners()

        // On the system object rather than on a device, so the picker still
        // notices a device arriving, leaving, or becoming the default when the
        // engine's own state has not changed and it therefore reports nothing.
        addSystemListener(address: Self.defaultOutputDeviceAddress)
        addSystemListener(address: Self.devicesAddress)

        guard let device = try? AudioObjectID.readDefaultOutputDevice() else {
            deviceID = .unknown
            outputDeviceName = "No output device"
            onChange?()
            return
        }

        deviceID = device
        outputDeviceName = (try? device.readString(kAudioObjectPropertyName)) ?? "Unknown"
        availableOutputs = readAvailableOutputs()

        addListener(on: device, address: Self.volumeAddress)
        addListener(on: device, address: Self.muteAddress)
        onChange?()
    }

    private func addListener(on device: AudioObjectID, address: AudioObjectPropertyAddress) {
        var mutableAddress = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.onChange?() }
        }

        let status = AudioObjectAddPropertyListenerBlock(device, &mutableAddress, queue, block)
        guard status == noErr else {
            logger.error("Could not observe volume property: \(status, privacy: .public)")
            return
        }
        listeners.append((device, address, block))
    }

    /// Observes a system-wide property.
    ///
    /// These fire for changes nothing else here would learn about, so they
    /// re-read the device and the list rather than only reporting, and the
    /// report then goes out through `onChange` at the end of `refresh()` like
    /// every other one. Registering again from inside `refresh()` is safe:
    /// `refresh()` removes every listener first, and these are recorded in the
    /// same list as the rest, so they cannot stack up.
    private func addSystemListener(address: AudioObjectPropertyAddress) {
        var mutableAddress = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID.system, &mutableAddress, queue, block
        )
        guard status == noErr else {
            logger.error("Could not observe system audio property: \(status, privacy: .public)")
            return
        }
        listeners.append((AudioObjectID.system, address, block))
    }

    private func removeListeners() {
        for (device, address, block) in listeners {
            var mutableAddress = address
            AudioObjectRemovePropertyListenerBlock(device, &mutableAddress, queue, block)
        }
        listeners.removeAll()
    }

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let defaultOutputDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}
