import AppKit
import SonoraPersistence

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var statusItem: NSStatusItem!

    private let engine = AudioEngineController(
        settingsStore: SettingsStore(directory: SettingsStore.defaultDirectory())
    )
    private let volume = SystemVolume()

    private lazy var model = PanelModel(engine: engine, volume: volume)
    private lazy var panelController = PanelController(model: model)
    private lazy var menuController = StatusMenuController(panelController: panelController)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "slider.horizontal.3",
            accessibilityDescription: "Sonora"
        )

        menuController.install(in: statusItem)
        engine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController.close()
        engine.stop()
    }
}
