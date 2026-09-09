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
    ///
    /// It is also the thickness of the preamp's row, so the horizontal control
    /// gives a pointer the same margin around its handle that a band does.
    static let controlWidth: Double = 26

    /// The handle's extent along the axis it travels. The groove is shortened
    /// by this much so the handle travels between the groove's ends instead of
    /// past them.
    static let handleHeight: Double = 9

    /// How far the curve must stay clear of the top and bottom edges to reach
    /// full scale at the same height as a handle at full scale.
    static let curveInset: Double = handleHeight / 2
}

/// One gain, drawn as a fill that grows out of the centre, in either
/// orientation.
///
/// A stock `Slider` fills from its minimum, so a value sitting at 0 dB shows a
/// half filled track and reads as boosted when it is flat. This control anchors
/// the fill at 0 dB instead: no gain, no fill; a boost grows out of the line
/// one way and a cut grows out of it the other.
///
/// The ten bands run vertically and the preamp runs horizontally, and they are
/// one control because they are one quantity: a signed gain over
/// `EqualizerBand.gainRange`, centred on a neutral 0 dB. Drawing them twice
/// would be two chances to disagree about what neutral looks like.
///
/// It is a custom control, so the keyboard support a `Slider` gave for free is
/// rebuilt here: it takes focus, the arrow keys along its own axis step it, and
/// VoiceOver gets a label and a value plus an adjustable action.
struct GainSlider: View {

    /// Which way the control runs. A vertical control grows a boost upward; a
    /// horizontal one grows it to the right.
    let axis: Axis

    @Binding var gain: Double

    /// What this control is called, for VoiceOver. The bands name their
    /// frequency and the preamp names itself.
    let accessibilityLabel: String

    @Environment(\.colorScheme) private var colorScheme

    @FocusState private var isFocused: Bool

    /// The gain the drag started from. Non-nil only while a drag is in flight,
    /// which is what makes the drag relative to where the control was grabbed
    /// rather than jumping the value to wherever the pointer landed.
    @State private var gainAtDragStart: Double?

    private static let range = EqualizerBand.gainRange

    /// The groove's thickness across the axis.
    private static let grooveThickness: Double = 5

    /// The handle's extent across the axis. Along the axis it is
    /// `BandMetrics.handleHeight`, which is the figure the curve's inset is
    /// measured from, so the handle and the curve stay tied to one number.
    private static let handleBreadth: Double = 20

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
        // A band column's length is fixed, but the preamp's comes from the
        // panel's width, so the length along the axis is measured rather than
        // assumed and every offset below is derived from it.
        GeometryReader { proxy in
            let travel = travel(forLength: axis == .vertical ? proxy.size.height : proxy.size.width)

            ZStack {
                groove(travel: travel)

                fill(travel: travel)
                    // The fill runs from the zero line to the handle, so its
                    // centre is half way between the two.
                    .offset(displacement(along: normalised * travel / 2))

                handle
                    .offset(displacement(along: normalised * travel))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            // The whole control is draggable, not just the handle, so a value
            // can be set without first hitting the handle itself.
            .contentShape(Rectangle())
            .gesture(drag(travel: travel))
        }
        .frame(
            width: axis == .vertical ? BandMetrics.controlWidth : nil,
            height: axis == .vertical ? BandMetrics.trackHeight : BandMetrics.controlWidth
        )
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 2)
            }
        }
        .focusable()
        .focused($isFocused)
        // The ring above is drawn to fit this control; the system's own effect
        // would sit around the same rectangle a second time.
        .focusEffectDisabled()
        .onKeyPress(incrementKey) {
            adjust(by: Self.keyboardStep)
            return .handled
        }
        .onKeyPress(decrementKey) {
            adjust(by: -Self.keyboardStep)
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(Self.value(for: gain))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjust(by: Self.keyboardStep)
            case .decrement: adjust(by: -Self.keyboardStep)
            @unknown default: break
            }
        }
    }

    // MARK: - Parts

    private func groove(travel: Double) -> some View {
        let size = size(along: travel * 2, across: Self.grooveThickness)
        return Capsule()
            .fill(.quaternary)
            .frame(width: size.width, height: size.height)
    }

    private func fill(travel: Double) -> some View {
        let size = size(along: abs(normalised) * travel, across: Self.grooveThickness)
        return Capsule()
            .fill(Color.accentColor)
            .frame(width: size.width, height: size.height)
    }

    /// A light chip in both appearances, the way an AppKit slider knob is.
    /// Naming an appearance-reactive control colour instead would make the
    /// handle dark on a dark panel, where it would sink into the groove rather
    /// than sit on top of it.
    private var handle: some View {
        let size = size(along: BandMetrics.handleHeight, across: Self.handleBreadth)
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(colorScheme == .dark ? Color(white: 0.78) : Color(white: 0.99))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.30 : 0.16), lineWidth: 0.5)
            )
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.40 : 0.18), radius: 1, y: 0.5)
    }

    // MARK: - Axis

    /// Turns a measurement along and across the axis into a frame.
    private func size(along length: Double, across breadth: Double) -> CGSize {
        axis == .vertical
            ? CGSize(width: breadth, height: length)
            : CGSize(width: length, height: breadth)
    }

    /// Turns a signed displacement along the axis into an offset. A positive
    /// displacement is a boost, which is upward on a vertical control, and
    /// SwiftUI's y axis grows downward, which is where the sign comes from.
    private func displacement(along value: Double) -> CGSize {
        axis == .vertical
            ? CGSize(width: 0, height: -value)
            : CGSize(width: value, height: 0)
    }

    /// Distance in points from the zero line to a full boost or full cut.
    private func travel(forLength length: Double) -> Double {
        max((length - BandMetrics.handleHeight) / 2, 0)
    }

    private var incrementKey: KeyEquivalent {
        axis == .vertical ? .upArrow : .rightArrow
    }

    private var decrementKey: KeyEquivalent {
        axis == .vertical ? .downArrow : .leftArrow
    }

    // MARK: - Value

    private func drag(travel: Double) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if gainAtDragStart == nil {
                    gainAtDragStart = gain

                    // The drag takes focus itself. On macOS a `.focusable()`
                    // view is not focused by being clicked, unlike the stock
                    // `Slider` this replaced, so without this a band moved with
                    // the mouse still would not answer the arrow keys.
                    isFocused = true
                }

                // Non-nil: the branch above just set it.
                let start = gainAtDragStart ?? gain

                // A control with no room to travel would divide by zero, and
                // there is no value a drag on it could mean anyway.
                guard travel > 0 else { return }

                // Pointer motion maps 1:1 onto the track: a point of travel is
                // always the same number of decibels, either way.
                let decibelsPerPoint = Self.magnitude / travel
                let movement = axis == .vertical
                    ? -Double(value.translation.height)
                    : Double(value.translation.width)
                gain = Self.settled(start + movement * decibelsPerPoint)
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

    private func adjust(by delta: Double) {
        // Round onto the step grid first, so a control left at 3.4 dB by a drag
        // steps to 4 rather than to 4.4 and keeps drifting off the round
        // numbers for the rest of the session.
        let steps = (gain / Self.keyboardStep).rounded()
        gain = Self.settled(steps * Self.keyboardStep + delta)
    }

    private static func settled(_ value: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return abs(clamped) < zeroDetent ? 0 : clamped
    }

    private static func value(for gain: Double) -> String {
        String(format: "%+.1f decibels", gain)
    }
}

/// One band's gain: a vertical `GainSlider` that knows its frequency.
struct BandControl: View {

    let frequency: Double

    @Binding var gain: Double

    var body: some View {
        GainSlider(
            axis: .vertical,
            gain: $gain,
            accessibilityLabel: Self.label(for: frequency)
        )
    }

    private static func label(for frequency: Double) -> String {
        frequency >= 1_000
            ? "\(Int(frequency / 1_000)) kilohertz band"
            : "\(Int(frequency)) hertz band"
    }
}
