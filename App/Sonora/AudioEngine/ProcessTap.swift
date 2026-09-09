import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// A global Core Audio process tap: everything the system plays, except Sonora
/// itself, muted at the source so that only our processed output is heard.
///
/// Three rules from hard experience, do not change them without reading the
/// design document:
///
/// 1. `init(stereoGlobalTapButExcludeProcesses:)` already sets the exclusive
///    flag. Assigning `isExclusive` afterwards flips the meaning from
///    "everything except these" to "only these" and the tap captures silence.
/// 2. Sonora's own process object must be in the exclude list. Without it the
///    tap captures our own output and the signal feeds back on itself.
/// 3. `muteBehavior = .mutedWhenTapped` is what removes the original audio from
///    the output. The mute lives with the tap object, so destroying the tap, or
///    crashing, restores normal audio.
final class ProcessTap {

    let uuid = UUID()
    private(set) var objectID = AudioObjectID.unknown

    private let logger = Logger(subsystem: "com.sonora.Sonora", category: "ProcessTap")

    var isActive: Bool { objectID.isValid }

    /// Creates the tap. Surfaces the system audio permission prompt on first run.
    func activate() throws {
        guard !isActive else { return }

        let ownProcess = try AudioObjectID.processObject(forPID: getpid())

        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: [ownProcess]
        )
        description.uuid = uuid
        description.name = "Sonora System Tap"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var id = AudioObjectID.unknown
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr, id.isValid else {
            throw AudioEngineError.tapCreationFailed(status)
        }

        objectID = id
        logger.info("Process tap active, object id \(id, privacy: .public)")
    }

    /// Destroys the tap and unmutes the system. Safe to call more than once.
    func invalidate() {
        guard isActive else { return }
        AudioHardwareDestroyProcessTap(objectID)
        logger.info("Process tap destroyed")
        objectID = .unknown
    }

    /// The audio format the tap delivers. Read after `activate`.
    func streamDescription() throws -> AudioStreamBasicDescription {
        try objectID.readStreamDescription(kAudioTapPropertyFormat)
    }

    deinit {
        invalidate()
    }
}
