import AppKit
import SonoraDSP
import SwiftUI

/// Shared geometry for the equalizer, so the curve, the zero reference and the
/// band controls are all measured from the same numbers rather than from three
/// hand-tuned constants that drift apart.
enum BandMetrics {

    /// Full height of a band column's control area.
    static let trackHeight: Double = 104

    /// Width of one band control. Ten of these is 260 points, which leaves 72
    /// points for the nine gaps inside the panel's 332 points of content width.
    static let controlWidth: Double = 26

    /// Height of the handle. The groove is shortened by this much so the handle
    /// travels between the groove's ends instead of past them.
    static let handleHeight: Double = 9

    /// Distance in points from the zero line to a full boost or full cut.
    static let travel: Double = (trackHeight - handleHeight) / 2

    /// How far the curve must stay clear of the top and bottom edges to reach
    /// full scale at the same height as a handle at full scale.
    static let curveInset: Double = handleHeight / 2
}

/// One band's gain, drawn as a fill that grows out of the centre.
///
/// A stock `Slider` fills from its minimum, so a band sitting at 0 dB shows a
/// half filled track and the whole equalizer reads as boosted when it is flat.
/// This control anchors the fill at 0 dB instead: no gain, no fill; a boost
/// grows up from the line, a cut grows down from it.
///
/// It is a custom control, so the keyboard support a `Slider` gave for free is
/// rebuilt here: the column takes focus, the arrow keys step it, and VoiceOver
/// gets the same label and value plus an adjustable action.
struct BandControl: View {

    let frequency: Double

    @Binding var gain: Double

    @Environment(\.colorScheme) private var colorScheme

    @FocusState private var isFocused: Bool

    /// The gain the drag started from. Non-nil only while a drag is in flight,
    /// which is what makes the drag relative to where the band was grabbed
    /// rather than jumping the value to wherever the pointer landed.
    @State private var gainAtDragStart: Double?

    private static let range = EqualizerBand.gainRange
    private static let grooveWidth: Double = 5
    private static let handleWidth: Double = 20

    /// One arrow key press. Whole decibels, so stepping always lands on the
    /// round numbers and 0 dB is reachable from the keyboard exactly.
    private static let keyboardStep: Double = 1

    /// A drag that ends up within this much of the line snaps to exactly 0 dB.
    /// Without it the flat state the whole design is anchored on would be the
    /// one value a pointer could never actually produce.
    private static let zeroDetent: Double = 0.4

    /// The largest displacement the range asks for, in decibels. The control is
    /// centred on 0 dB, so a boost and a cut are measured from the same point.
    private static let magnitude = max(abs(range.lowerBound), abs(range.upperBound))

    var body: some View {
        ZStack {
            Capsule()
                .fill(.quaternary)
                .frame(width: Self.grooveWidth, height: BandMetrics.trackHeight - BandMetrics.handleHeight)

            Capsule()
                .fill(Color.accentColor)
                .frame(width: Self.grooveWidth, height: fillLength)
                .offset(y: fillOffset)

            handle
                .offset(y: handleOffset)
        }
        .frame(width: BandMetrics.controlWidth, height: BandMetrics.trackHeight)
        // The whole column is draggable, not just the handle, so a band can be
        // set without first hitting a 20 by 9 point target.
        .contentShape(Rectangle())
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
            }
        }
        .gesture(drag)
        .focusable()
        .focused($isFocused)
        // The ring above is drawn to fit this column; the system's own effect
        // would sit around the same rectangle a second time.
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            adjust(by: Self.keyboardStep)
            return .handled
        }
        .onKeyPress(.downArrow) {
            adjust(by: -Self.keyboardStep)
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(Self.label(for: frequency))
        .accessibilityValue(Self.value(for: gain))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: Self.keyboardStep)
            case .decrement: adjust(by: -Self.keyboardStep)
            @unknown default: break
            }
        }
    }

    /// A light chip in both appearances, the way an AppKit slider knob is.
    /// Naming an appearance-reactive control colour instead would make the
    /// handle dark on a dark panel, where it would sink into the groove rather
    /// than sit on top of it.
    private var handle: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(colorScheme == .dark ? Color(white: 0.78) : Color(white: 0.99))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.30 : 0.16), lineWidth: 0.5)
            )
            .frame(width: Self.handleWidth, height: BandMetrics.handleHeight)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.40 : 0.18), radius: 1, y: 0.5)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = gainAtDragStart ?? gain
                gainAtDragStart = start

                // Pointer motion maps 1:1 onto the track: a point of travel is
                // always the same number of decibels, up or down.
                let decibelsPerPoint = Self.magnitude / BandMetrics.travel
                gain = Self.settled(start - Double(value.translation.height) * decibelsPerPoint)
            }
            .onEnded { _ in
                gainAtDragStart = nil
            }
    }

    /// Signed position of the current gain, -1 at full cut, 0 at the line,
    /// 1 at full boost.
    private var normalised: Double {
        guard Self.magnitude > 0 else { return 0 }
        return min(max(gain / Self.magnitude, -1), 1)
    }

    /// Vertical offset of the handle's centre from the zero line. Negative is
    /// up, because SwiftUI's y axis grows downward.
    private var handleOffset: Double {
        -normalised * BandMetrics.travel
    }

    private var fillLength: Double {
        abs(normalised) * BandMetrics.travel
    }

    /// The fill runs from the zero line to the handle, so its centre is half
    /// way between the two.
    private var fillOffset: Double {
        handleOffset / 2
    }

    private func adjust(by delta: Double) {
        // Round onto the step grid first, so a band left at 3.4 dB by a drag
        // steps to 4 rather than to 4.4 and keeps drifting off the round
        // numbers for the rest of the session.
        let steps = (gain / Self.keyboardStep).rounded()
        gain = Self.settled(steps * Self.keyboardStep + delta)
    }

    private static func settled(_ value: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return abs(clamped) < zeroDetent ? 0 : clamped
    }

    private static func label(for frequency: Double) -> String {
        frequency >= 1_000
            ? "\(Int(frequency / 1_000)) kilohertz band"
            : "\(Int(frequency)) hertz band"
    }

    private static func value(for gain: Double) -> String {
        String(format: "%+.1f decibels", gain)
    }
}
