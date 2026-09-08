import AppKit
import SonoraPersistence

final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var statusItem: NSStatusItem!

    private let engine = AudioEngineController(
        settingsStore: SettingsStore(directory: SettingsStore.defaultDirectory())
    )
    private lazy var menuController = StatusMenuController(engine: engine)

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
        engine.stop()
    }
}
