import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// Installs an `IOProc` on the aggregate device and moves audio from the tap's
/// input buffers to the device's output buffers.
///
/// The `IOProc` block runs on a real-time thread. Inside it there is no
/// allocation, no locking, no logging and no Swift runtime work. `processBlock`
/// is captured once at `start` and must obey the same rules.
final class RenderLoop {

    /// Called for every buffer, on the real-time thread.
    /// Parameters: interleaved samples, frame count, channel count.
    var processBlock: ((UnsafeMutablePointer<Float>, Int, Int) -> Void)?

    private(set) var isRunning = false

    private let aggregate: AggregateDevice
    private var ioProcID: AudioDeviceIOProcID?
    private let logger = Logger(subsystem: "com.sonora.Sonora", category: "RenderLoop")

    init(aggregate: AggregateDevice) {
        self.aggregate = aggregate
    }

    func start() throws {
        guard !isRunning else { return }
        guard aggregate.isCreated else {
            throw AudioEngineError.ioProcCreationFailed(kAudioHardwareBadObjectError)
        }

        let block = processBlock

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregate.objectID,
            nil
        ) { _, inputData, _, outputData, _ in
            let inputBuffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData)
            )
            let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)

            guard let input = inputBuffers.first,
                  let output = outputBuffers.first,
                  let source = input.mData,
                  let destination = output.mData else {
                return
            }

            let byteCount = min(input.mDataByteSize, output.mDataByteSize)
            memcpy(destination, source, Int(byteCount))

            // A non-interleaved device presents one buffer per channel, and the
            // DSP chain only understands interleaved. Anything else falls
            // through as the straight copy above rather than being processed
            // into the wrong layout.
            guard inputBuffers.count == 1, outputBuffers.count == 1 else { return }

            let channelCount = Int(output.mNumberChannels)
            guard channelCount > 0 else { return }
            let frameCount = Int(byteCount) / MemoryLayout<Float>.size / channelCount

            block?(
                destination.assumingMemoryBound(to: Float.self),
                frameCount,
                channelCount
            )
        }

        guard createStatus == noErr, let procID else {
            throw AudioEngineError.ioProcCreationFailed(createStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregate.objectID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregate.objectID, procID)
            ioProcID = nil
            throw AudioEngineError.deviceStartFailed(startStatus)
        }

        isRunning = true
        logger.info("Render loop started")
    }

    func stop() {
        guard let procID = ioProcID, aggregate.isCreated else {
            isRunning = false
            return
        }

        AudioDeviceStop(aggregate.objectID, procID)
        AudioDeviceDestroyIOProcID(aggregate.objectID, procID)
        ioProcID = nil
        isRunning = false
        logger.info("Render loop stopped")
    }

    deinit {
        stop()
    }
}
