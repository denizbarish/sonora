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

    func start() throws {
        guard !isRunning else { return }
        guard AccessibilityPermission.isTrusted else { throw TapError.notTrusted }

        // `CGEventType` has no case for system defined events, so the mask is
        // built from the raw `NX_SYSDEFINED` value, 14. This is what the spike
        // measured; `CGEventType.systemDefined` does not compile.
        let mask = CGEventMask(1 << 14)

        // The callback cannot capture main-actor state, so it carries an
        // unmanaged pointer to self and hops back to the main actor with the
        // decoded key. Nothing else happens on the tap's own thread.
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

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
        isRunning = true
    }

    func stop() {
        guard let tap, let source else {
            isRunning = false
            return
        }

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        CFMachPortInvalidate(tap)

        self.tap = nil
        self.source = nil
        isRunning = false
    }

    private func reEnable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        // The run loop source and mach port die with the process. Tearing them
        // down here would need main-actor state a deinit cannot reach.
    }
}
