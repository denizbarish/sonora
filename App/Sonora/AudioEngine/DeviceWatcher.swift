import CoreAudio
import Foundation

/// Watches for the system output device changing, for example when headphones
/// are plugged in or a Bluetooth speaker connects.
///
/// The aggregate device is built around one specific output device. When that
/// device changes, the aggregate must be torn down and rebuilt, otherwise audio
/// stops with no error.
final class DeviceWatcher {

    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.sonora.DeviceWatcher")
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(onDefaultOutputChange: @escaping @Sendable () -> Void) {
        self.onChange = onDefaultOutputChange
    }

    func start() throws {
        guard listenerBlock == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.onChange()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID.system, &address, queue, block
        )
        guard status == noErr else {
            throw AudioEngineError.propertyReadFailed(
                kAudioHardwarePropertyDefaultOutputDevice, status
            )
        }
        listenerBlock = block
    }

    func stop() {
        guard let block = listenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID.system, &address, queue, block)
        listenerBlock = nil
    }

    deinit {
        stop()
    }
}
