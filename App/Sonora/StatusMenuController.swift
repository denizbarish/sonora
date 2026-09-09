import AppKit

/// The status item's behaviour: left click opens the panel, right click gives a
/// small menu.
///
/// The menu is deliberately kept, rather than folded into the panel, so the app
/// is always quittable even if the panel fails to show.
@MainActor
final class StatusMenuController: NSObject {

    private let panelController: PanelController
    private weak var statusItem: NSStatusItem?

    init(panelController: PanelController) {
        self.panelController = panelController
        super.init()
    }

    func install(in statusItem: NSStatusItem) {
        self.statusItem = statusItem

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem?.button else { return }

        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(from: button)
        } else {
            panelController.toggle(from: button)
        }
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Quit Sonora",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // Attaching the menu makes the next click open it; detaching afterwards
        // gives the left click back to the panel.
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }
}
