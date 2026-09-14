import CoreAudio
import Foundation
import OSLog

/// The one C callback every registration shares.
///
/// The context pointer is what tells one registration from another, so this
/// function has to be the same function every time, which is why it is a plain
/// global rather than anything captured.
private func audioPropertyListenerProc(
    _ object: AudioObjectID,
    _ addressCount: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let context else { return noErr }
    Unmanaged<AudioPropertyListener.Handler>
        .fromOpaque(context)
        .takeUnretainedValue()
        .invoke()
    return noErr
}

/// One Core Audio property listener registration that can actually be undone.
///
/// Core Audio offers two ways to register. The block based pair looks like the
/// modern one and reads better, and from Swift its removal does not work:
/// `AudioObjectRemovePropertyListenerBlock` returns `noErr` and leaves the
/// listener installed, because the closure is bridged into a fresh block at
/// each crossing while the HAL matches registrations by block pointer.
///
/// That is worse than leaking memory. A listener nobody can remove keeps being
/// called, so code that re-registers on every change multiplies the callbacks
/// for a single event, and when those callbacks re-register in turn the count
/// grows with no ceiling until the main actor stops draining and the interface
/// stops answering.
///
/// The older function pointer API identifies a registration by the pair of the
/// C function and the context pointer, and both cross the boundary unchanged,
/// so removal removes. Measured on macOS 26.5.2 in
/// `Tools/listener-removal-spike`: every block based shape kept firing after a
/// successful looking removal, this one fired four times while registered and
/// not once after.
final class AudioPropertyListener {

    /// The handler, on the far side of the C boundary.
    ///
    /// A class so the registration has one stable address for its whole life.
    /// That address is the context pointer, which is half of the pair the HAL
    /// matches on.
    fileprivate final class Handler: Sendable {
        private let body: @Sendable () -> Void

        init(_ body: @escaping @Sendable () -> Void) {
            self.body = body
        }

        func invoke() {
            body()
        }
    }

    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private var context: UnsafeMutableRawPointer?
    private let logger = Logger(subsystem: "com.sonora.Sonora", category: "AudioProperty")

    /// Registers `handler` for one property on one object.
    ///
    /// The handler runs on whichever thread the HAL delivers on, measured as a
    /// background one, so it must do nothing but hand the work to wherever
    /// that work belongs.
    init(
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        handler: @escaping @Sendable () -> Void
    ) throws {
        self.object = object
        self.address = address

        let context = Unmanaged.passRetained(Handler(handler)).toOpaque()
        let status = AudioObjectAddPropertyListener(
            object, &self.address, audioPropertyListenerProc, context
        )
        guard status == noErr else {
            Unmanaged<Handler>.fromOpaque(context).release()
            throw AudioEngineError.propertyReadFailed(address.mSelector, status)
        }
        self.context = context
    }

    /// Removes the registration. Idempotent, and the only thing that frees the
    /// handler.
    func cancel() {
        guard let context else { return }
        self.context = nil

        let status = AudioObjectRemovePropertyListener(
            object, &address, audioPropertyListenerProc, context
        )
        if status != noErr {
            // Reported rather than ignored. A removal that quietly does
            // nothing is exactly how the callback storm this type exists to
            // prevent got started.
            let selector = address.mSelector.fourCharacterCode
            logger.error(
                "Could not remove the listener for \(selector, privacy: .public): \(status, privacy: .public)"
            )
        }
        Unmanaged<Handler>.fromOpaque(context).release()
    }

    deinit {
        cancel()
    }
}
