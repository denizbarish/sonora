import CoreAudio
import Foundation

extension AudioObjectID {

    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    /// The device the system is currently playing through.
    static func readDefaultOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID.system, &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else {
            throw AudioEngineError.propertyReadFailed(
                kAudioHardwarePropertyDefaultOutputDevice, status
            )
        }
        guard deviceID.isValid else { throw AudioEngineError.noOutputDevice }
        return deviceID
    }

    /// Reads a `CFString` property, for example a device UID.
    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw AudioEngineError.propertyReadFailed(selector, status)
        }
        return value as String
    }

    /// Reads an `AudioStreamBasicDescription` property.
    func readStreamDescription(
        _ selector: AudioObjectPropertySelector
    ) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let status = AudioObjectGetPropertyData(
            self, &address, 0, nil, &size, &description
        )
        guard status == noErr else {
            throw AudioEngineError.propertyReadFailed(selector, status)
        }
        return description
    }

    /// Reads a `UInt32` property, used for buffer sizes and latencies.
    func readUInt32(_ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw AudioEngineError.propertyReadFailed(selector, status)
        }
        return value
    }

    /// Translates a process identifier into the Core Audio object that
    /// represents that process. Needed to exclude Sonora's own output from the
    /// global tap, otherwise the engine taps what it just played and feeds back.
    static func processObject(forPID pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputPID = pid
        var objectID = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID.system,
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &inputPID,
            &size,
            &objectID
        )
        guard status == noErr, objectID.isValid else {
            throw AudioEngineError.processObjectNotFound(pid)
        }
        return objectID
    }
}
