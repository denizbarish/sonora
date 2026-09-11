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

    private lazy var welcome = WelcomeWindow(onContinue: { [weak self] in
        self?.engine.retry()
    })

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "slider.horizontal.3",
            accessibilityDescription: "Sonora"
        )

        menuController.install(in: statusItem)
        engine.start()

        // Only when the engine could not get the permission. On a machine that
        // already granted it, this window would be noise.
        if case .bypassed = engine.state {
            welcome.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController.close()
        engine.stop()
    }
}
