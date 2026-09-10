import ApplicationServices
import AppKit

/// The Accessibility permission, which a `CGEvent` tap needs.
///
/// This is a much larger thing to ask for than audio capture: it lets an app
/// observe and synthesise input everywhere. Sonora asks for it only when
/// someone turns volume key capture on, and works completely without it.
@MainActor
enum AccessibilityPermission {

    /// The option key `AXIsProcessTrustedWithOptions` reads, spelled out rather
    /// than taken from `kAXTrustedCheckOptionPrompt`.
    ///
    /// The SDK declares that constant as a plain `extern CFStringRef`, not a
    /// `const` one, so Swift imports it as a mutable global and language mode 6
    /// rejects reading it: "reference to var 'kAXTrustedCheckOptionPrompt' is
    /// not concurrency-safe because it involves shared mutable state". The
    /// alternative was to silence that with `nonisolated(unsafe)`, which trades
    /// a real guarantee for a string this framework cannot change without
    /// breaking every app that hardcodes it.
    private static let promptOption = "AXTrustedCheckOptionPrompt" as CFString

    /// Whether the app is trusted. Never prompts, so it is safe to call on
    /// every launch and whenever the panel opens.
    static var isTrusted: Bool {
        AXIsProcessTrustedWithOptions(
            [promptOption: false] as CFDictionary
        )
    }

    /// Asks the system to show its permission prompt.
    ///
    /// The prompt appears once per app identity; afterwards the system stays
    /// silent and the only route is System Settings, which is why
    /// `openSettings()` exists alongside this.
    static func request() {
        _ = AXIsProcessTrustedWithOptions(
            [promptOption: true] as CFDictionary
        )
    }

    /// Opens the Accessibility pane, for when the prompt will not appear again.
    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
