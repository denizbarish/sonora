import AppKit
import SwiftUI

/// Owns the panel window and anchors it under the status item.
///
/// An `NSPanel` rather than a popover: a popover steals focus in ways that
/// fight with a menu bar utility, and a non-activating panel lets the user keep
/// working while they drag a slider.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {

    private let model: PanelModel
    private var panel: NSPanel?

    init(model: PanelModel) {
        self.model = model
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(from button: NSStatusBarButton) {
        if isVisible {
            close()
        } else {
            show(from: button)
        }
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func show(from button: NSStatusBarButton) {
        let panel = existingOrNewPanel()

        guard let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.frame)

        // Centred under the status item, nudged in from the screen edge so the
        // panel is never half off the display on a narrow menu bar position.
        var origin = NSPoint(
            x: buttonRect.midX - panel.frame.width / 2,
            y: buttonRect.minY - panel.frame.height - 6
        )
        if let screen = buttonWindow.screen {
            let limit = screen.visibleFrame
            origin.x = min(max(origin.x, limit.minX + 8), limit.maxX - panel.frame.width - 8)
        }

        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func existingOrNewPanel() -> NSPanel {
        if let panel { return panel }

        let hosting = NSHostingView(rootView: PanelView(model: model))
        hosting.layout()

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = true
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.delegate = self
        panel.setContentSize(hosting.fittingSize)

        self.panel = panel
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
