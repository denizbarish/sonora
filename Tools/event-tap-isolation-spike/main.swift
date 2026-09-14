// Does a CGEvent tap callback written inside a @MainActor method survive being
// called on another thread, and does moving it to file scope fix that?
//
// Both variants build a real tap, serve it from a thread of their own, and
// post a system defined event to themselves. Each runs in its own process,
// because the failure is a trap that takes the process with it.
//
// Run: ./isolationspike            (runs both variants as children)
//      ./isolationspike closure    (one variant, in this process)

import AppKit
import CoreGraphics

@MainActor
final class ClosureVariant {
    nonisolated(unsafe) static var sawEvent = false

    /// The mistake: a closure formed here is isolated to the main actor, and
    /// the conversion to a C function pointer carries an isolation check.
    func start() -> CFMachPort? {
        CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << 14),
            callback: { _, _, event, _ in
                ClosureVariant.sawEvent = true
                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )
    }
}

nonisolated(unsafe) var functionSawEvent = false

/// The fix: a function at file scope, isolated to nothing.
private func fileScopeCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    functionSawEvent = true
    return Unmanaged.passUnretained(event)
}

@MainActor
final class FunctionVariant {
    func start() -> CFMachPort? {
        CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << 14),
            callback: fileScopeCallback,
            userInfo: nil
        )
    }
}

final class TapThread: Thread {
    private let source: CFRunLoopSource
    private let ready = DispatchSemaphore(value: 0)

    init(source: CFRunLoopSource) {
        self.source = source
        super.init()
        name = "spike.tap"
    }

    func startAndWait() {
        start()
        ready.wait()
    }

    override func main() {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        ready.signal()
        CFRunLoopRun()
    }
}

func postSystemDefined() {
    // Volume up, key down then up. listenOnly, so the system still handles it;
    // the mute key would be worse to leave behind than a volume step.
    for down in [true, false] {
        let data1 = Int((0 << 16) | ((down ? 0x0A : 0x0B) << 8))
        guard let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
            context: nil, subtype: 8, data1: data1, data2: -1
        ), let cgEvent = event.cgEvent else { continue }
        cgEvent.post(tap: .cghidEventTap)
    }
}

/// Everything a variant does, on the main actor, so no non-Sendable handle
/// ever crosses an isolation boundary. The tap's own thread is where the
/// callback actually runs, which is the whole point.
@MainActor
func probe(_ name: String) -> Never {
    let tap = name == "closure" ? ClosureVariant().start() : FunctionVariant().start()

    guard let tap, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
        print("  \(name): the tap could not be created, this process is not trusted for Accessibility")
        exit(3)
    }

    TapThread(source: source).startAndWait()
    CGEvent.tapEnable(tap: tap, enable: true)

    postSystemDefined()
    Thread.sleep(forTimeInterval: 1.5)

    let saw = name == "closure" ? ClosureVariant.sawEvent : functionSawEvent
    print("  \(name): survived, callback ran: \(saw)")
    exit(saw ? 0 : 4)
}

if CommandLine.arguments.count > 1 {
    MainActor.assumeIsolated { probe(CommandLine.arguments[1]) }
} else {
    print("callback written where, and does the process live through an event?")
    for variant in ["closure", "file-scope"] {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = [variant]
        try child.run()
        child.waitUntilExit()
        let status = child.terminationStatus
        let reason = child.terminationReason == .uncaughtSignal ? "killed by signal \(status)" : "exit \(status)"
        print("  \(variant): \(reason)")
    }
}
