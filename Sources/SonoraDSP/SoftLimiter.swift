import Foundation

/// A waveshaping limiter that keeps the signal below a fixed ceiling.
///
/// The preamp lets the user push past the system volume, so the chain has to end
/// in something that cannot clip. Below `threshold` the limiter is a straight
/// wire. Above it, the remaining headroom is compressed through `tanh`, which
/// approaches the ceiling asymptotically and never crosses it.
///
/// This is a static curve with no time constants: no attack, no release, no
/// lookahead. It is transparent on peaks and audibly soft on sustained overload,
/// which is the right trade for a system-wide effect that must never add latency.
public struct SoftLimiter: Sendable {

    /// Output ceiling, -0.3 dBFS.
    public static let ceiling: Float = 0.966_051

    /// Where the soft knee starts, -6 dBFS.
    public static let threshold: Float = 0.5

    /// Whether the limiter has shaped a sample since the flag was last cleared.
    /// The interface polls this to show the overload indicator.
    public private(set) var isEngaged = false

    public init() {}

    @inline(__always)
    public mutating func process(_ input: Float) -> Float {
        let magnitude = abs(input)
        guard magnitude > Self.threshold else { return input }

        isEngaged = true

        let headroom = Self.ceiling - Self.threshold
        let excess = magnitude - Self.threshold
        let shaped = Self.threshold + headroom * tanh(excess / headroom)
        return input < 0 ? -shaped : shaped
    }

    public mutating func clearEngagedFlag() {
        isEngaged = false
    }
}
