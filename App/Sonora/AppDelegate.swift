import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var statusItem: NSStatusItem!

    private let tap = ProcessTap()
    private var aggregate: AggregateDevice?
    private var renderLoop: RenderLoop?

    private let logger = Logger(subsystem: "com.sonora.Sonora", category: "AppDelegate")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "slider.horizontal.3",
            accessibilityDescription: "Sonora"
        )

        let statusTitle = startEngine()

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

    /// Starts the engine in passthrough mode and returns a line describing the
    /// result, including the measured latency budget.
    private func startEngine() -> String {
        do {
            try tap.activate()

            let aggregate = AggregateDevice(tap: tap)
            try aggregate.create()
            self.aggregate = aggregate

            let renderLoop = RenderLoop(aggregate: aggregate)
            try renderLoop.start()
            self.renderLoop = renderLoop

            let format = try tap.streamDescription()
            let bufferFrames = try aggregate.bufferFrameSize()
            let deviceFrames = try aggregate.outputLatencyFrames()
            let totalFrames = Double(bufferFrames + deviceFrames)
            let milliseconds = totalFrames / format.mSampleRate * 1_000

            let summary = String(
                format: "Passthrough, %.0f Hz, buffer %u, device %u, added ~%.1f ms",
                format.mSampleRate, bufferFrames, deviceFrames, milliseconds
            )
            logger.info("\(summary, privacy: .public)")
            return summary
        } catch {
            stopEngine()
            logger.error("\(error.localizedDescription, privacy: .public)")
            return "Bypassed: \(error.localizedDescription)"
        }
    }

    private func stopEngine() {
        renderLoop?.stop()
        renderLoop = nil
        aggregate?.destroy()
        aggregate = nil
        tap.invalidate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopEngine()
    }
}
