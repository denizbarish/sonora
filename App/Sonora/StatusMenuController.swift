import AppKit
import SonoraDSP
import SonoraProfiles

/// The minimal control surface for the engine.
///
/// This is a stepping stone, not the shipping interface. It exists so the engine
/// can be driven and verified before the panel is built in the next plan.
@MainActor
final class StatusMenuController: NSObject {

    private let engine: AudioEngineController
    private weak var statusItem: NSStatusItem?

    init(engine: AudioEngineController) {
        self.engine = engine
        super.init()
    }

    func install(in statusItem: NSStatusItem) {
        self.statusItem = statusItem
        engine.onStateChange = { [weak self] _ in
            self?.rebuildMenu()
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let statusItem else { return }

        let menu = NSMenu()

        switch engine.state {
        case .stopped:
            menu.addItem(withTitle: "Stopped", action: nil, keyEquivalent: "")
        case .running:
            menu.addItem(withTitle: "Running", action: nil, keyEquivalent: "")
        case .bypassed(let reason):
            menu.addItem(withTitle: "Bypassed", action: nil, keyEquivalent: "")
            let detail = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
            menu.addItem(
                withTitle: "Try Again",
                action: #selector(retry),
                keyEquivalent: ""
            ).target = self
        }

        menu.addItem(.separator())

        let bypassItem = NSMenuItem(
            title: "Bypass Equalizer",
            action: #selector(toggleBypass),
            keyEquivalent: ""
        )
        bypassItem.target = self
        bypassItem.state = engine.parameters.isBypassed ? .on : .off
        menu.addItem(bypassItem)

        menu.addItem(.separator())
        let presetsHeader = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        presetsHeader.isEnabled = false
        menu.addItem(presetsHeader)

        for preset in BuiltInPresets.all {
            let item = NSMenuItem(
                title: preset.name,
                action: #selector(selectPreset(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset
            item.state = engine.activePresetID == preset.id ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Sonora",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        statusItem.menu = menu
    }

    @objc private func retry() {
        engine.retry()
    }

    @objc private func toggleBypass() {
        var parameters = engine.parameters
        parameters.isBypassed.toggle()
        engine.update(parameters)
        rebuildMenu()
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? Preset else { return }

        var parameters = engine.parameters
        parameters.bands = preset.bands
        parameters.preampDecibels = preset.preampDecibels
        engine.update(parameters)
        engine.setActivePresetID(preset.id)
        rebuildMenu()
    }
}
