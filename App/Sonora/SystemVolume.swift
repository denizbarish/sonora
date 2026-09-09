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
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = device.id
        let size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectSetPropertyData(
            AudioObjectID.system, &address, 0, nil, size, &id
        )
        if status != noErr {
            logger.error("Could not switch output device: \(status, privacy: .public)")
        }
    }

    /// Enumerates devices that have at least one output channel.
    private func readAvailableOutputs() -> [OutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

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
            guard hasOutputChannels(id), let name = try? id.readString(kAudioObjectPropertyName) else {
                return nil
            }
            return OutputDevice(id: id, name: name)
        }
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
}
