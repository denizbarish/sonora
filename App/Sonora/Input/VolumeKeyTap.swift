import AppKit
import CoreGraphics

/// Puts the volume keys under Sonora's control.
///
/// Media keys arrive as `NSSystemDefined` events with subtype 8, carrying the
/// key in `data1` rather than as an ordinary key code. Returning nil from the
/// callback swallows the event, which is what stops the system's own volume
/// overlay from appearing alongside Sonora's panel.
///
/// The tap needs the Accessibility permission and fails cleanly without it.
///
/// Its run loop source lives on a thread of its own, never on the main one.
/// The tap sits at the head of the HID event stream for every system-defined
/// event on the machine, so whatever thread services it holds up every
/// application's media keys while it is busy. The main thread is busy often
/// enough, rebuilding the audio path around a device change creates a process
/// tap and an aggregate device, and the system's remedy for a slow tap is to
/// disable it, which the recovery path would then have to undo from that same
/// blocked thread.
@MainActor
final class VolumeKeyTap {

    enum Key {
        case up, down, mute
    }

    enum TapError: LocalizedError {
        case notTrusted
        case tapCreationFailed

        var errorDescription: String? {
            switch self {
            case .notTrusted:
                return "Sonora needs Accessibility permission for the volume keys. Grant it, then turn this on again."
            case .tapCreationFailed:
                return "The volume keys could not be captured."
            }
        }
    }

    var onKey: ((Key) -> Void)?

    private(set) var isRunning = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// The run loop of the tap's own thread, kept so `stop()` can reach it.
    /// `CFRunLoopGetCurrent()` would answer for the main thread instead.
    private var runLoop: CFRunLoop?

    func start() throws {
        guard !isRunning else { return }
        guard AccessibilityPermission.isTrusted else { throw TapError.notTrusted }

        // `CGEventType` has no case for system defined events, so the mask is
        // built from the raw `NX_SYSDEFINED` value, 14. This is what the spike
        // measured; `CGEventType.systemDefined` does not compile.
        let mask = CGEventMask(1 << 14)

        // The callback cannot capture main-actor state, so it carries an
        // unmanaged pointer to self and hops back to the main actor with the
        // decoded key. Decoding and that hop are all that runs on the tap's
        // own thread, which is what keeps the tap quick enough for the system
        // to leave it enabled.
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                // The system disables a tap that takes too long or when input
                // is interrupted. Re-enabling is the documented recovery.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let userInfo {
                        let tap = Unmanaged<VolumeKeyTap>.fromOpaque(userInfo)
                            .takeUnretainedValue()
                        Task { @MainActor in tap.reEnable() }
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard let nsEvent = NSEvent(cgEvent: event),
                      nsEvent.subtype.rawValue == 8,
                      let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = Int32((nsEvent.data1 & 0xFFFF_0000) >> 16)
                let isPressed = ((nsEvent.data1 & 0x0000_FF00) >> 8) == 0x0A
                let isRepeat = (nsEvent.data1 & 0x1) == 1

                let key: Key?
                switch keyCode {
                case NX_KEYTYPE_SOUND_UP: key = .up
                case NX_KEYTYPE_SOUND_DOWN: key = .down
                case NX_KEYTYPE_MUTE: key = .mute
                default: key = nil
                }

                guard let key else { return Unmanaged.passUnretained(event) }

                // Repeats are wanted for up and down, so holding either one
                // keeps stepping. Not for mute: each repeat would toggle the
                // device back again and flicker the overlay. Whether the mute
                // key produces repeats at all was never measured, and ignoring
                // them is right either way. Swallowed rather than passed on,
                // so the system's overlay does not appear for the repeat
                // Sonora chose to ignore.
                if isRepeat, key == .mute { return nil }

                if isPressed {
                    let owner = Unmanaged<VolumeKeyTap>.fromOpaque(userInfo)
                        .takeUnretainedValue()
                    Task { @MainActor in owner.onKey?(key) }
                }

                // Swallow it, so the system's own overlay stays out of the way.
                return nil
            },
            userInfo: context
        ) else {
            throw TapError.tapCreationFailed
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw TapError.tapCreationFailed
        }

        // `start()` is main-actor isolated, so adding the source here would
        // put it on the main run loop. The thread adds it to its own instead
        // and hands that run loop back.
        guard let runLoop = TapThread(source: source).startAndWaitForRunLoop() else {
            CFMachPortInvalidate(tap)
            throw TapError.tapCreationFailed
        }

        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
        self.runLoop = runLoop
        isRunning = true
    }

    func stop() {
        guard let tap, let source, let runLoop else {
            isRunning = false
            return
        }

        CGEvent.tapEnable(tap: tap, enable: false)
        // The tap's run loop, not whichever one is calling. `CFRunLoop` is the
        // one CoreFoundation type that is safe to touch from another thread.
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(tap)
        // With its last source gone the run loop has nothing to do; stopping
        // it lets `CFRunLoopRun()` return so the thread can finish.
        CFRunLoopStop(runLoop)

        self.tap = nil
        self.source = nil
        self.runLoop = nil
        isRunning = false
    }

    private func reEnable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Isolated, so it can reach the main-actor state `stop()` needs.
    ///
    /// Without this, releasing a running tap would leave the mach port and its
    /// run loop source alive with a `userInfo` pointing at freed memory, and
    /// the next volume key press would be a use-after-free that also swallowed
    /// the keys with nobody left to act on them. Nothing releases this object
    /// today, `AppDelegate` holds the model for the life of the process, which
    /// is the only reason that was ever survivable.
    isolated deinit {
        stop()
    }
}

/// The thread the tap's run loop lives on.
///
/// A `Thread` subclass rather than a `Thread { ... }` block because the block
/// is `@Sendable` and the handles the thread needs, `CFRunLoopSource` and
/// `CFRunLoop`, are not `Sendable`. Capturing them in one warns, and the ways
/// to quieten that warning are the escape hatches this app does not use. A
/// subclass keeps them as ordinary stored properties, and the semaphore is
/// what actually orders the write to `loop` on this thread against the read of
/// it on the caller's.
private final class TapThread: Thread {

    private let source: CFRunLoopSource
    private let ready = DispatchSemaphore(value: 0)
    private var loop: CFRunLoop?

    init(source: CFRunLoopSource) {
        self.source = source
        super.init()
        name = "com.sonora.volume-key-tap"
    }

    /// Starts the thread and blocks until its run loop is serving the source.
    ///
    /// The caller needs the run loop before it can stop the tap again, and the
    /// only thread that can ask for it is this one.
    func startAndWaitForRunLoop() -> CFRunLoop? {
        start()
        ready.wait()
        return loop
    }

    override func main() {
        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, .commonModes)
        self.loop = loop
        ready.signal()

        // Returns once `stop()` has removed the source and stopped the loop,
        // and the thread ends with it.
        CFRunLoopRun()
    }
}
