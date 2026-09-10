import AppKit
import CoreGraphics

// Does a CGEvent tap see the volume keys, and can it swallow them?
//
// Media keys arrive as NSSystemDefined events with subtype 8, carrying the key
// code in the event data rather than as an ordinary key code. The volume keys
// are the uncertain ones: the system often consumes them first. This asks the
// question directly rather than building a feature on an assumption.
//
// Run from a terminal that already holds the Accessibility permission.

// CGEventType has no case for system defined events, so the mask is built
// from the raw NX_SYSDEFINED value, 14. This is the standard idiom for tapping
// media keys.
let mask = CGEventMask(1 << 14)

guard let tap = CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: mask,
    callback: { _, _, event, _ in
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int32((nsEvent.data1 & 0xFFFF_0000) >> 16)
        let isPressed = ((nsEvent.data1 & 0x0000_FF00) >> 8) == 0x0A

        let name: String
        switch keyCode {
        case NX_KEYTYPE_SOUND_UP: name = "volume up"
        case NX_KEYTYPE_SOUND_DOWN: name = "volume down"
        case NX_KEYTYPE_MUTE: name = "mute"
        case NX_KEYTYPE_PLAY: name = "play"
        default: name = "other (\(keyCode))"
        }

        if isPressed {
            print("saw \(name)")
            fflush(stdout)
        }

        // Swallowing means returning nil. Try it for the volume keys only, so
        // the machine stays usable if this runs longer than expected.
        let isVolume = keyCode == NX_KEYTYPE_SOUND_UP
            || keyCode == NX_KEYTYPE_SOUND_DOWN
            || keyCode == NX_KEYTYPE_MUTE
        return isVolume ? nil : Unmanaged.passUnretained(event)
    },
    userInfo: nil
) else {
    print("tap could NOT be created: this process is not trusted for Accessibility")
    exit(1)
}

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

print("tap created. listening 30 seconds, press volume up, volume down and mute")
print("if the system volume changes anyway, the tap did not swallow them")
fflush(stdout)

DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    CGEvent.tapEnable(tap: tap, enable: false)
    print("done")
    exit(0)
}

CFRunLoopRun()
