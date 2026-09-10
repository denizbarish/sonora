import AppKit
import SwiftUI

/// Explains the audio permission before, or after, the system asks for it.
///
/// The system's own prompt carries one sentence and no context. Someone who has
/// just downloaded a menu bar app and is immediately asked to let it record
/// system audio has good reason to say no. This says why first.
@MainActor
final class WelcomeWindow {

    private var window: NSWindow?
    private let onContinue: () -> Void

    init(onContinue: @escaping () -> Void) {
        self.onContinue = onContinue
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let view = WelcomeView(
            onContinue: { [weak self] in
                self?.close()
                self?.onContinue()
            },
            onOpenSettings: {
                guard let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
                ) else { return }
                NSWorkspace.shared.open(url)
            }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.layout()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sonora"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func close() {
        window?.orderOut(nil)
    }
}

private struct WelcomeView: View {

    let onContinue: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sonora needs permission to hear your Mac")
                .font(.system(size: 15, weight: .semibold))

            Text(
                """
                macOS has no equalizer, so Sonora captures what your Mac is \
                playing, runs it through the equalizer, and plays it back. \
                That capture is what the permission is for.

                The audio never leaves your Mac. It is processed as it plays \
                and is never recorded, stored or sent anywhere. Sonora is open \
                source, so you can check that for yourself.
                """
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text("Grant it under Privacy & Security, then System Audio Recording.")
                .font(.system(size: 12))

            HStack {
                Button("Open Settings", action: onOpenSettings)
                Spacer()
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
