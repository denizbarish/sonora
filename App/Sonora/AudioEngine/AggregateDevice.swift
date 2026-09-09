import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// A private aggregate device that pairs the real output device with the
/// process tap, so that one `IOProc` receives tapped audio as input and writes
/// processed audio to the speakers as output.
///
/// The layout matters and is easy to get wrong. The real output device is the
/// main sub-device. The tap rides along as a sub-tap. Making the tap the main
/// sub-device, or leaving the sub-device list empty, produces an aggregate that
/// reports success and then delivers zero samples forever.
final class AggregateDevice {

    private(set) var objectID = AudioObjectID.unknown
    private(set) var outputDeviceID = AudioObjectID.unknown

    private let tap: ProcessTap
    private let logger = Logger(subsystem: "com.sonora.Sonora", category: "AggregateDevice")

    var isCreated: Bool { objectID.isValid }

    init(tap: ProcessTap) {
        self.tap = tap
    }

    /// Builds the aggregate around whatever the current default output device is.
    func create() throws {
        guard !isCreated else { return }

        let outputDevice = try AudioObjectID.readDefaultOutputDevice()
        let outputUID = try outputDevice.readString(kAudioDevicePropertyDeviceUID)

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sonora Output",
            kAudioAggregateDeviceUIDKey: "com.sonora.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tap.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var id = AudioObjectID.unknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id.isValid else {
            throw AudioEngineError.aggregateCreationFailed(status)
        }

        objectID = id
        outputDeviceID = outputDevice
        logger.info("Aggregate device \(id, privacy: .public) built on \(outputUID, privacy: .public)")
    }

    func destroy() {
        guard isCreated else { return }
        AudioHardwareDestroyAggregateDevice(objectID)
        logger.info("Aggregate device destroyed")
        objectID = .unknown
        outputDeviceID = .unknown
    }

    /// How many frames the device asks for per callback. The main contributor to
    /// added latency.
    func bufferFrameSize() throws -> UInt32 {
        try objectID.readUInt32(kAudioDevicePropertyBufferFrameSize)
    }

    /// The format the aggregate presents on its output side.
    ///
    /// This is what the render callback actually writes into, and it is not
    /// necessarily the tap's format. A mono device, such as a Bluetooth headset
    /// in HFP mode, reports one channel where the stereo global tap reports two.
    /// Sizing the DSP chain from the tap instead walks off the end of the output
    /// buffer, on the real-time thread, on every callback.
    func outputStreamDescription() throws -> AudioStreamBasicDescription {
        try objectID.readStreamDescription(
            kAudioDevicePropertyStreamFormat,
            scope: kAudioObjectPropertyScopeOutput
        )
    }

    /// The output device's own reported latency, in frames.
    func outputLatencyFrames() throws -> UInt32 {
        let latency = (try? outputDeviceID.readUInt32(kAudioDevicePropertyLatency)) ?? 0
        let safetyOffset = (try? outputDeviceID.readUInt32(kAudioDevicePropertySafetyOffset)) ?? 0
        return latency + safetyOffset
    }

    deinit {
        destroy()
    }
}
