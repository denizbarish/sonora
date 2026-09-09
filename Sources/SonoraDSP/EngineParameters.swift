/// Everything the render loop needs to know, in one value.
///
/// The interface produces these; the real-time thread consumes them through
/// `ParameterBridge`. Keeping it a single value type is what makes the handoff
/// atomic: the audio thread never sees half of an update.
public struct EngineParameters: Equatable, Sendable {

    public var isBypassed: Bool
    public var preampDecibels: Double
    public var bands: [EqualizerBand]

    public init(
        isBypassed: Bool = false,
        preampDecibels: Double = 0,
        bands: [EqualizerBand] = EqualizerBand.graphicDefaults
    ) {
        self.isBypassed = isBypassed
        self.preampDecibels = preampDecibels
        self.bands = bands
    }

    public static let defaults = EngineParameters()

    /// Pushes these values into a chain. Called from the audio thread only when
    /// the bridge reports a change, because `update(bands:)` recomputes
    /// coefficients and is too slow to run on every buffer.
    public func apply(to chain: DSPChain) {
        chain.isBypassed = isBypassed
        chain.preampDecibels = preampDecibels
        chain.update(bands: bands)
    }
}
