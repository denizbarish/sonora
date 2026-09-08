import Testing
import Foundation
@testable import SonoraDSP

@Suite("ParameterBridge")
struct ParameterBridgeTests {

    @Test("a published change reaches the chain")
    func publishReachesChain() {
        let bridge = ParameterBridge(sampleRate: 48_000)
        let chain = DSPChain(sampleRate: 48_000, channelCount: 2)

        var parameters = EngineParameters.defaults
        parameters.preampDecibels = -5
        bridge.publish(parameters)
        bridge.applyPendingChanges(to: chain)

        #expect(abs(chain.preampDecibels - (-5)) < 0.001)
    }

    @Test("published band changes arrive as working coefficients")
    func publishReachesCoefficients() {
        let bridge = ParameterBridge(sampleRate: 48_000)
        let chain = DSPChain(sampleRate: 48_000, channelCount: 2)

        var parameters = EngineParameters.defaults
        parameters.bands[2].gainDecibels = -8  // 125 Hz
        bridge.publish(parameters)
        bridge.applyPendingChanges(to: chain)

        #expect(abs(chain.magnitudeDecibels(atFrequency: 125) + 8) < 0.3)
    }

    @Test("setSampleRate recomputes coefficients for the new rate")
    func sampleRateChangeRepublishes() {
        let bridge = ParameterBridge(sampleRate: 48_000)
        let chain = DSPChain(sampleRate: 96_000, channelCount: 2)

        var parameters = EngineParameters.defaults
        parameters.bands[8].gainDecibels = 9  // 8 kHz
        bridge.publish(parameters)

        bridge.setSampleRate(96_000)
        bridge.applyPendingChanges(to: chain)

        // The chain reports its curve at 96 kHz, so the coefficients must have
        // been built for 96 kHz too, or the peak lands at the wrong frequency.
        #expect(abs(chain.magnitudeDecibels(atFrequency: 8_000) - 9) < 0.3)
    }

    @Test("current reflects the last published value")
    func currentReflectsPublish() {
        let bridge = ParameterBridge(sampleRate: 48_000)

        var parameters = EngineParameters.defaults
        parameters.isBypassed = true
        bridge.publish(parameters)

        #expect(bridge.current.isBypassed == true)
    }

    @Test("applying twice without a new publish is a no-op")
    func appliesOnlyOnce() {
        let bridge = ParameterBridge(sampleRate: 48_000)
        let chain = DSPChain(sampleRate: 48_000, channelCount: 2)

        var parameters = EngineParameters.defaults
        parameters.preampDecibels = 3
        bridge.publish(parameters)
        bridge.applyPendingChanges(to: chain)

        // Something else changes the chain directly; a second apply with no new
        // publish must not overwrite it.
        chain.preampDecibels = 0
        bridge.applyPendingChanges(to: chain)

        #expect(chain.preampDecibels == 0)
    }

    @Test("only the newest of several publishes is applied")
    func coalescesPublishes() {
        let bridge = ParameterBridge(sampleRate: 48_000)
        let chain = DSPChain(sampleRate: 48_000, channelCount: 2)

        for value in [1.0, 2.0, 3.0] {
            var parameters = EngineParameters.defaults
            parameters.preampDecibels = value
            bridge.publish(parameters)
        }
        bridge.applyPendingChanges(to: chain)

        #expect(abs(chain.preampDecibels - 3) < 0.001)
    }

    @Test("a concurrent publish never leaves the chain with a mixed set")
    func neverCommitsATornSet() async {
        let bridge = ParameterBridge(sampleRate: 48_000)
        let chain = DSPChain(sampleRate: 48_000, channelCount: 2)

        // Two sets whose every band differs, so a torn copy lands on a curve
        // that matches neither.
        func parameters(gain: Double) -> EngineParameters {
            EngineParameters(
                isBypassed: false,
                preampDecibels: 0,
                bands: EqualizerBand.graphicDefaults.map { band in
                    var copy = band
                    copy.gainDecibels = gain
                    return copy
                }
            )
        }
        let quiet = parameters(gain: -6)
        let loud = parameters(gain: 6)

        // Reference curves, measured off the audio path.
        let quietChain = DSPChain(sampleRate: 48_000, channelCount: 2)
        quiet.apply(to: quietChain)
        let quietCurve = quietChain.magnitudeDecibels(atFrequency: 1_000)

        let loudChain = DSPChain(sampleRate: 48_000, channelCount: 2)
        loud.apply(to: loudChain)
        let loudCurve = loudChain.magnitudeDecibels(atFrequency: 1_000)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for index in 0..<2_000 {
                    bridge.publish(index.isMultiple(of: 2) ? quiet : loud)
                }
            }
            group.addTask {
                for _ in 0..<2_000 {
                    bridge.applyPendingChanges(to: chain)
                    let curve = chain.magnitudeDecibels(atFrequency: 1_000)
                    #expect(
                        abs(curve - quietCurve) < 0.5
                            || abs(curve - loudCurve) < 0.5
                            || curve == 0
                    )
                }
            }
        }
    }

    @Test("concurrent publishing never loses the final value")
    func concurrentPublishing() async {
        let bridge = ParameterBridge(sampleRate: 48_000)
        let chain = DSPChain(sampleRate: 48_000, channelCount: 2)

        await withTaskGroup(of: Void.self) { group in
            for value in 1...200 {
                group.addTask {
                    var parameters = EngineParameters.defaults
                    parameters.preampDecibels = Double(value)
                    bridge.publish(parameters)
                }
            }
            group.addTask {
                for _ in 0..<200 {
                    bridge.applyPendingChanges(to: chain)
                }
            }
        }

        // Whatever landed last must be a value that was actually published, and
        // the chain must agree with what the bridge reports as current.
        bridge.applyPendingChanges(to: chain)
        #expect((1...200).contains(Int(chain.preampDecibels.rounded())))
        #expect(abs(chain.preampDecibels - bridge.current.preampDecibels) < 0.001)
    }
}
