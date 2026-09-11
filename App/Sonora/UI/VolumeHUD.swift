import AppKit
import SwiftUI

/// What the overlay is showing at this instant.
///
/// A separate observable object rather than arguments to the view, because the
/// panel is built once and lives for the rest of the session: the controller
/// writes here and SwiftUI updates the window that is already on screen,
/// instead of a new view tree being handed in on every key press.
@MainActor
@Observable
final class VolumeHUDReadout {

    /// 0 to 1. Clamped by the controller before it lands here.
    var level: Float = 0

    /// The device's mute switch, which is a separate thing from a level of 0.
    var isMuted: Bool = false

    static let accessibilityLabel = "Volume"

    /// "70%", or "70%, muted".
    var accessibilityValue: String {
        let percent = Int((level * 100).rounded())
        return isMuted ? "\(percent)%, muted" : "\(percent)%"
    }

    /// The whole state as one phrase, for the spoken announcement.
    var accessibilityDescription: String {
        "\(Self.accessibilityLabel) \(accessibilityValue)"
    }
}

/// The overlay itself: a glyph that reflects the state, and the level under it.
///
/// Deliberately close to the system overlay it replaces. Sonora swallows the
/// volume key event, so the thing that used to appear here is gone, and the
/// user's expectation of what appears instead was set years ago by macOS.
/// Familiarity is worth more here than a look of Sonora's own.
struct VolumeHUDView: View {

    let readout: VolumeHUDReadout

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Layout margin. The glyph and the bar share it, so they align to the
    /// same two vertical edges and the bar's ends mark the full range.
    private static let margin: CGFloat = 20

    /// Twice the margin, so the bar reads as belonging to the glyph above it
    /// rather than as a separate row that happens to sit in the same box.
    private static let gap: CGFloat = 24

    private static let glyphSize: CGFloat = 64
    private static let barHeight: CGFloat = 8

    var body: some View {
        VStack(spacing: Self.gap) {
            glyph
            levelBar
        }
        .padding(Self.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(motion, value: readout.level)
        .animation(motion, value: readout.isMuted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(VolumeHUDReadout.accessibilityLabel)
        .accessibilityValue(readout.accessibilityValue)
    }

    /// One symbol, not four.
    ///
    /// `variableValue` fills the waves in step with the level, which is how
    /// macOS draws its own speaker, and it moves continuously instead of
    /// snapping between `speaker.wave.1` and `speaker.wave.2` at thresholds
    /// the user cannot see.
    ///
    /// Mute is the one state that gets a different symbol. A muted device at
    /// 70% and an unmuted device at 0% are not the same thing, so they are not
    /// allowed to look alike: the slash says the output is off, and the bar
    /// below goes on showing the level that is waiting behind it. At 0%
    /// unmuted there is no slash and the bar is empty. Neither the glyph nor
    /// the bar has to be read on its own to tell the two apart.
    private var glyph: some View {
        Image(
            systemName: readout.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill",
            variableValue: readout.isMuted ? nil : Double(readout.level)
        )
        .font(.system(size: Self.glyphSize, weight: .regular))
        .foregroundStyle(.primary)
        .contentTransition(.symbolEffect(.replace))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The track is always full width, so the level is read against the range
    /// rather than against nothing. Muted dims the fill to secondary: still
    /// clearly a level, no longer a level anything is coming out at.
    private var levelBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(.quaternary)

                Capsule(style: .continuous)
                    .fill(
                        readout.isMuted
                            ? AnyShapeStyle(.secondary)
                            : AnyShapeStyle(.primary)
                    )
                    .frame(width: fillWidth(in: proxy.size.width))
            }
        }
        .frame(height: Self.barHeight)
    }

    /// Zero has to look like zero, so the fill collapses to nothing rather
    /// than to a dot. Anything above zero gets at least a round end, because a
    /// sliver narrower than the bar is taller than it is wide and reads as a
    /// rendering fault rather than as a quiet volume.
    private func fillWidth(in width: CGFloat) -> CGFloat {
        let level = CGFloat(min(max(readout.level, 0), 1))
        guard level > 0 else { return 0 }
        return min(max(width * level, Self.barHeight), width)
    }

    /// Critically damped, no overshoot. The overlay is reporting a key press,
    /// not carrying momentum from a gesture, so a bounce would be describing
    /// something that did not happen. Reduce Motion drops the animation
    /// entirely rather than shortening it: there is nothing to understand from
    /// the movement, only the value it arrives at.
    private var motion: Animation? {
        reduceMotion ? nil : .spring(duration: 0.28, bounce: 0)
    }
}

/// An `NSPanel` that cannot become key or main, whatever it is asked.
///
/// `.nonactivatingPanel` on a borderless window already keeps it out of the
/// key window chain, but the whole value of this overlay is that it appears
/// while someone is typing in another app. Refusing here makes that structural
/// instead of a property of the style mask that a later edit could drop.
@MainActor
private final class NonFocusingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Shows the volume overlay and takes it away again.
///
/// One window for the life of the app, created the first time it is needed:
/// `show` is called once per key press and a held key sends many, so a window
/// per press would stack overlays on top of each other. Each call retargets
/// the same panel and pushes the dismissal back, which is what makes a run of
/// presses one overlay that stays for as long as the presses continue.
@MainActor
final class VolumeHUDController {

    /// Square, and the size macOS makes its own volume overlay, because this
    /// is standing in for that one.
    private static let size = CGSize(width: 200, height: 200)
    private static let cornerRadius: CGFloat = 18

    /// How far the bottom edge sits above the bottom of the display, matching
    /// where macOS puts the overlay this replaces.
    private static let bottomInset: CGFloat = 140

    /// Kept clear of the Dock, for a Dock tall enough to reach `bottomInset`.
    private static let edgeClearance: CGFloat = 16

    /// Appearing is immediate, because it is answering a key press and any
    /// delay reads as the key not having worked. Leaving is slower, because
    /// nothing is waiting on it.
    private static let fadeInDuration: TimeInterval = 0.12
    private static let fadeOutDuration: TimeInterval = 0.3

    /// From the last press to the start of the fade.
    private static let holdDuration: Duration = .seconds(1)

    private let readout = VolumeHUDReadout()
    private var panel: NonFocusingPanel?

    /// The pending dismissal. Cancelled and replaced by every press, which is
    /// what extends one overlay rather than stacking several.
    private var dismissal: Task<Void, Never>?

    /// Reports a volume change Sonora just made.
    ///
    /// Only ever called from the volume key handler. Nothing watching the
    /// device for changes calls this, so a change made in System Settings or
    /// by another app draws nothing.
    func show(level: Float, isMuted: Bool) {
        readout.level = min(max(level, 0), 1)
        readout.isMuted = isMuted

        let panel = panelForShowing()
        position(panel)

        dismissal?.cancel()

        // `orderFrontRegardless`, never `makeKeyAndOrderFront`, and the app is
        // never activated: the window arrives in front of whatever the user is
        // working in without that app losing focus.
        panel.orderFrontRegardless()

        // Animating to 1 rather than assigning it matters when a press lands
        // during a fade out. The animator starts from the alpha currently on
        // screen, so the overlay comes back from wherever it had faded to
        // instead of snapping to full and flashing.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        announce()

        dismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.holdDuration)
            guard let self, !Task.isCancelled else { return }
            await fadeOut()
        }
    }

    private func fadeOut() async {
        guard let panel else { return }

        // The awaiting form of the animation group returns once the
        // animation has finished, which is the only moment ordering the panel
        // out is safe: any earlier and the fade is cut off at its first frame.
        await NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }

        // A press during the fade cancels this task, and `show` has already
        // animated the alpha back up from wherever it had reached, so the
        // window must not be taken away after all.
        guard !Task.isCancelled else { return }
        panel.orderOut(nil)
    }

    /// Spoken, because the overlay is a window that never takes focus and
    /// VoiceOver has nothing to move to. Sonora swallows the key event, and
    /// the system's own spoken feedback goes with it; this puts it back. High
    /// priority so a run of presses interrupts itself and ends on the level
    /// that was actually reached.
    private func announce() {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: readout.accessibilityDescription,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }

    /// Bottom centre of the display the pointer is on.
    ///
    /// Where macOS has put this overlay for years, and the position that
    /// covers the least: the middle of the screen is where the window someone
    /// is reading has its text, and the bottom strip holds nothing but the
    /// desktop or the top of the Dock. Recomputed on every show, so unplugging
    /// a display or moving to another one does not leave it stranded.
    private func position(_ panel: NSPanel) {
        guard let screen = activeScreen() else { return }

        let bounds = screen.frame
        let lowest = screen.visibleFrame.minY + Self.edgeClearance

        panel.setFrameOrigin(
            NSPoint(
                x: (bounds.midX - Self.size.width / 2).rounded(),
                y: max(bounds.minY + Self.bottomInset, lowest).rounded()
            )
        )
    }

    /// `NSScreen.main` is documented as the screen holding the window with
    /// keyboard focus, and this app deliberately never has one, so the pointer
    /// is the better guess at which display the user is looking at.
    private func activeScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    }

    private func panelForShowing() -> NonFocusingPanel {
        if let panel { return panel }

        let panel = NonFocusingPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // A readout, not a control. It never takes focus, the pointer passes
        // straight through to whatever is underneath, and it does not hide
        // when the app it is floating over becomes active, which a panel
        // belonging to a menu bar app otherwise does immediately.
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle,
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        // Starts invisible and animates up in `show`. The system's own window
        // animation is turned off so it does not run alongside that.
        panel.alphaValue = 0
        panel.animationBehavior = .none

        // The HUD material, so the overlay picks up the wallpaper behind it and
        // follows the system appearance and Reduce Transparency without being
        // asked. Corner masking lives on the material's layer, since the
        // window itself is borderless and draws nothing.
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = Self.cornerRadius
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: VolumeHUDView(readout: readout))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: material.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])

        panel.contentView = material
        self.panel = panel
        return panel
    }
}
