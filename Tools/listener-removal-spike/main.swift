// Does a Core Audio property listener registration come off again?
//
// Each phase registers one listener, counts callbacks while it is registered,
// removes it, and counts again. The control count matters: a zero after removal
// means nothing unless the listener fired at all, and the function pointer
// listener is delivered on a background thread rather than the main run loop,
// so the count is taken with the run loop spinning.
//
// Every phase runs in its own process. A leaked block listener cannot be
// removed, which is the finding, so a later phase sharing the process would
// count an earlier phase's leftovers as its own and report a removal failure
// that was not its.
//
// Build and run:
//   swiftc -O main.swift -o listener-removal-spike && ./listener-removal-spike
//
// It nudges the system volume by 0.05 to provoke the notifications and puts it
// back afterwards.

import CoreAudio
import Foundation

// MARK: - Counting

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func take() -> Int {
        lock.lock()
        defer { value = 0; lock.unlock() }
        return value
    }
}

let counter = Counter()

/// The C callback for the function pointer API. One function for every
/// registration: the context pointer is what tells registrations apart.
func listenerProc(
    _ object: AudioObjectID,
    _ addressCount: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    counter.bump()
    return noErr
}

// MARK: - The device and its volume

var volumeAddress = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyVolumeScalar,
    mScope: kAudioDevicePropertyScopeOutput,
    mElement: kAudioObjectPropertyElementMain
)

func readDefaultOutput() -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    precondition(AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
    ) == noErr, "cannot read the default output device")
    return device
}

let device = readDefaultOutput()

func readVolume() -> Float32 {
    var address = volumeAddress
    var value: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)
    precondition(
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
        "this device does not expose a main element volume, so it cannot answer the question"
    )
    return value
}

func writeVolume(_ value: Float32) {
    var address = volumeAddress
    var value = value
    precondition(AudioObjectSetPropertyData(
        device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value
    ) == noErr, "cannot set the volume")
}

/// Changes the volume from a background thread while the main run loop runs,
/// puts it back, and returns how many callbacks arrived meanwhile.
func fireCount(original: Float32) -> Int {
    let nudged: Float32 = original > 0.5 ? original - 0.05 : original + 0.05
    DispatchQueue.global().async {
        writeVolume(nudged)
        Thread.sleep(forTimeInterval: 0.4)
        writeVolume(original)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    return counter.take()
}

// MARK: - The phases

enum Phase: String, CaseIterable {
    case direct = "direct"
    case classProperty = "class-property"
    case tupleArray = "tuple-array"
    case functionPointer = "function-pointer"

    var title: String {
        switch self {
        case .direct: "block, passed straight back"
        case .classProperty: "block, held in a class property"
        case .tupleArray: "block, held in a tuple array"
        case .functionPointer: "function pointer and context"
        }
    }
}

final class Holder {
    var block: AudioObjectPropertyListenerBlock?
}

func run(_ phase: Phase) {
    let original = readVolume()
    let queue = DispatchQueue(label: "listener-removal-spike")

    let addStatus: OSStatus
    let control: Int
    let removeStatus: OSStatus

    switch phase {
    case .functionPointer:
        addStatus = AudioObjectAddPropertyListener(device, &volumeAddress, listenerProc, nil)
        control = fireCount(original: original)
        removeStatus = AudioObjectRemovePropertyListener(
            device, &volumeAddress, listenerProc, nil
        )

    case .direct, .classProperty, .tupleArray:
        let block: AudioObjectPropertyListenerBlock = { _, _ in counter.bump() }
        addStatus = AudioObjectAddPropertyListenerBlock(device, &volumeAddress, queue, block)
        control = fireCount(original: original)

        // Where the block lived in between is the only thing that differs.
        let passedBack: AudioObjectPropertyListenerBlock
        switch phase {
        case .direct:
            passedBack = block
        case .classProperty:
            let holder = Holder()
            holder.block = block
            passedBack = holder.block!
        default:
            var stored: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
            stored.append((device, volumeAddress, block))
            passedBack = stored[0].2
        }

        removeStatus = AudioObjectRemovePropertyListenerBlock(
            device, &volumeAddress, queue, passedBack
        )
    }

    let afterRemoval = fireCount(original: original)
    writeVolume(original)

    let verdict: String
    if control == 0 {
        verdict = "inconclusive, it never fired while registered"
    } else if afterRemoval == 0 {
        verdict = "removed"
    } else {
        verdict = "STILL REGISTERED"
    }

    print(phase.title)
    print("  add \(addStatus), fires while registered \(control)")
    print("  remove \(removeStatus), fires after removal \(afterRemoval)")
    print("  verdict: \(verdict)")
}

// MARK: - Entry

if CommandLine.arguments.count > 1 {
    guard let phase = Phase(rawValue: CommandLine.arguments[1]) else {
        let names = Phase.allCases.map(\.rawValue).joined(separator: ", ")
        print("unknown phase. one of: \(names)")
        exit(2)
    }
    run(phase)
} else {
    print("device \(device), volume \(readVolume())\n")
    // Before the children write, not after they exit.
    fflush(stdout)
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL

    for phase in Phase.allCases {
        let child = Process()
        child.executableURL = executable
        child.arguments = [phase.rawValue]
        try child.run()
        child.waitUntilExit()
    }
}
