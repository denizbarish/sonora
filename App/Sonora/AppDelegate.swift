import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var statusItem: NSStatusItem!
    private let tap = ProcessTap()
    private let logger = Logger(subsystem: "com.sonora.Sonora", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "slider.horizontal.3",
            accessibilityDescription: "Sonora"
        )

        let statusTitle: String
        do {
            try tap.activate()
            let format = try tap.streamDescription()
            statusTitle = "Tap active, \(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch"
            logger.info("\(statusTitle, privacy: .public)")
        } catch {
            statusTitle = "Tap failed: \(error.localizedDescription)"
            logger.error("\(error.localizedDescription, privacy: .public)")
        }

        let menu = NSMenu()
        menu.addItem(withTitle: statusTitle, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Sonora",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusItem.menu = menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        tap.invalidate()
    }
}
