import Testing
import Foundation
@testable import SonoraDSP

@Suite("EngineParameters")
struct EngineParametersTests {

    @Test("defaults are flat and active")
    func defaults() {
        let parameters = EngineParameters.defaults

        #expect(parameters.isBypassed == false)
        #expect(parameters.preampDecibels == 0)
        #expect(parameters.bands == EqualizerBand.graphicDefaults)
    }

    @Test("applying parameters moves them into the chain")
    func applyToChain() {
        let chain = DSPChain(sampleRate: 48_000, channelCount: 2)
        var parameters = EngineParameters.defaults
        parameters.preampDecibels = -4
        parameters.isBypassed = true
        parameters.bands[1].gainDecibels = 5

        parameters.apply(to: chain)

        #expect(abs(chain.preampDecibels - (-4)) < 0.001)
        #expect(chain.isBypassed == true)
        #expect(abs(chain.magnitudeDecibels(atFrequency: 64) - 5) < 0.3)
    }

    @Test("parameters compare by value")
    func equality() {
        var a = EngineParameters.defaults
        var b = EngineParameters.defaults
        #expect(a == b)

        a.preampDecibels = 1
        #expect(a != b)

        b.preampDecibels = 1
        #expect(a == b)
    }
}
