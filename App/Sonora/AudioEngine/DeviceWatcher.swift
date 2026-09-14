import CoreAudio
import Foundation

/// Watches for the system output device changing, for example when headphones
/// are plugged in or a Bluetooth speaker connects.
///
/// The aggregate device is built around one specific output device. When that
/// device changes, the aggregate must be torn down and rebuilt, otherwise audio
/// stops with no error.
final class DeviceWatcher {

    private let onChange: @Sendable () -> Void
    private var listener: AudioPropertyListener?

    private let address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(onDefaultOutputChange: @escaping @Sendable () -> Void) {
        self.onChange = onDefaultOutputChange
    }

    func start() throws {
        guard listener == nil else { return }

        // Captured on its own rather than through `self`, so the handler holds
        // nothing that has to outlive the registration.
        let onChange = self.onChange
        listener = try AudioPropertyListener(object: .system, address: address) {
            onChange()
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    deinit {
        stop()
    }
}
