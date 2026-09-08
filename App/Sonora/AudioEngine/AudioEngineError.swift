import CoreAudio
import Foundation

enum AudioEngineError: LocalizedError, Equatable {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case propertyReadFailed(AudioObjectPropertySelector, OSStatus)
    case noOutputDevice
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case processObjectNotFound(pid_t)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status):
            return "Could not create the system audio tap (\(status)). "
                 + "Check that Sonora has System Audio Recording permission."
        case .aggregateCreationFailed(let status):
            return "Could not create the audio device (\(status))."
        case .propertyReadFailed(let selector, let status):
            return "Could not read audio property \(selector.fourCharacterCode) (\(status))."
        case .noOutputDevice:
            return "No audio output device is available."
        case .ioProcCreationFailed(let status):
            return "Could not install the audio render callback (\(status))."
        case .deviceStartFailed(let status):
            return "Could not start the audio device (\(status))."
        case .processObjectNotFound(let pid):
            return "Could not find the audio process object for pid \(pid)."
        }
    }
}

extension AudioObjectPropertySelector {
    /// Core Audio selectors are four character codes. Printing them as text
    /// makes log output readable.
    var fourCharacterCode: String {
        let value = UInt32(self)
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "\(value)"
    }
}
