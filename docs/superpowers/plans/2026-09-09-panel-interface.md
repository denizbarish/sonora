# Sonora Panel Interface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the status menu with the panel the design calls for: system volume and output device, preamp, ten band sliders under a live equalizer curve, and a preset strip.

**Architecture:** A single `NSPanel` hosting SwiftUI, anchored under the status item. An `@Observable` model owns the interface state and is the only thing that talks to `AudioEngineController`. The equalizer curve is computed by a pure function over band definitions rather than read from the live `EqualizerChain`, because that chain's coefficients are written by the audio thread and reading them from the interface would be an unsynchronised access.

**Tech Stack:** Swift 6.2, SwiftUI with `@Observable`, AppKit (`NSPanel`, `NSStatusItem`, `NSHostingView`), Core Audio for system volume.

**Spec:** `docs/superpowers/specs/2026-09-07-sonora-design.md`, section 7.1.

**Scope:** the panel only. Volume key capture, the accessibility permission, onboarding and notarised packaging are a separate plan, because they are system integration and distribution rather than interface.

## Global Constraints

- Deployment target macOS 14.4, Swift 6.2, language mode 6, strict concurrency, Xcode 26.3.
- Nothing in the interface may read from `EqualizerChain` or `DSPChain`. Those are owned by the audio thread. The interface reads `AudioEngineController.parameters`, which comes from the bridge's writer-side copy.
- Every interface type that touches AppKit or the engine is `@MainActor`. `@unchecked Sendable` is not an acceptable way to silence an isolation error; if something does not compile, report it.
- All user-facing strings in English. The repository is public and international.
- Signing is manual. Before building, `export SONORA_CODE_SIGN_IDENTITY="Apple Development: YOUR NAME (YOURTEAMID)"`, then `cd App && xcodegen generate && xcodebuild -project Sonora.xcodeproj -scheme Sonora -configuration Debug build`. Verify with `codesign -dv --verbose=4`: `flags=0x10000(runtime)` and an `Authority=Apple Development: ...` line. `flags=0x2(adhoc)` means it did not take.
- `App/project.yml` must keep having no `info:` or `entitlements:` keys. Those make XcodeGen regenerate those files and silently drop `NSAudioCaptureUsageDescription`.
- Tests use Swift Testing, not XCTest. Only the Swift package is testable; `App/` has no test target.
- Code, comments and commit messages in English. Conventional commit prefixes. No license headers.
- `swift test --sanitize=address` does not work on this machine or in CI: it builds and then hangs. Do not attempt it.

## File structure

| File | Responsibility |
|---|---|
| `Sources/SonoraDSP/EqualizerCurve.swift` | Pure curve math over band definitions. No state, no chain. |
| `App/Sonora/SystemVolume.swift` | Reads and writes the default output device's volume, and its name. |
| `App/Sonora/UI/PanelModel.swift` | The only type that talks to the engine. Owns interface state. |
| `App/Sonora/UI/PanelView.swift` | Root layout: output row, preamp, equalizer, presets. |
| `App/Sonora/UI/CurveView.swift` | Draws the curve behind the sliders. |
| `App/Sonora/UI/BandSliders.swift` | The ten band sliders. |
| `App/Sonora/UI/PresetStrip.swift` | Preset picker. |
| `App/Sonora/PanelController.swift` | Owns the `NSPanel`, anchors it to the status item, shows and hides it. |
| `App/Sonora/StatusMenuController.swift` | Reduced to: left click opens the panel, right click keeps a small menu. |

---

### Task 1: Pure equalizer curve

**Files:**
- Create: `Sources/SonoraDSP/EqualizerCurve.swift`
- Test: `Tests/SonoraDSPTests/EqualizerCurveTests.swift`

**Interfaces:**
- Consumes: `EqualizerBand`, `BiquadCoefficients` from the existing package.
- Produces: `enum EqualizerCurve` with
  `static func magnitudeDecibels(of bands: [EqualizerBand], atFrequency: Double, sampleRate: Double) -> Float`
  and
  `static func points(of bands: [EqualizerBand], sampleRate: Double, from: Double, to: Double, count: Int) -> [CurvePoint]`,
  plus `struct CurvePoint: Equatable, Sendable { let frequency: Double; let decibels: Float }`.

**Why this exists rather than reusing `EqualizerChain.magnitudeDecibels`:** that method reads `filters[index].coefficients`, and those are written by the audio thread through `applyCoefficients`. Drawing the curve from it would be an unsynchronised concurrent read of a five float struct, which is the same tearing the chain's own doc comment warns about. This function takes band definitions by value and shares nothing.

- [ ] **Step 1: Write the failing test**

Create `Tests/SonoraDSPTests/EqualizerCurveTests.swift`:

```swift
import Testing
import Foundation
@testable import SonoraDSP

@Suite("EqualizerCurve")
struct EqualizerCurveTests {

    let sampleRate = 48_000.0

    @Test("a flat band set produces a flat curve")
    func flatIsFlat() {
        for frequency in [20.0, 100, 1_000, 10_000, 20_000] {
            let value = EqualizerCurve.magnitudeDecibels(
                of: EqualizerBand.graphicDefaults,
                atFrequency: frequency,
                sampleRate: sampleRate
            )
            #expect(abs(value) < 0.000_1)
        }
    }

    @Test("a boosted band lifts its own centre frequency")
    func boostedBand() {
        var bands = EqualizerBand.graphicDefaults
        bands[5].gainDecibels = 6  // 1 kHz

        let value = EqualizerCurve.magnitudeDecibels(
            of: bands, atFrequency: 1_000, sampleRate: sampleRate
        )
        #expect(abs(value - 6) < 0.3)
    }

    @Test("the curve agrees with a chain built from the same bands")
    func agreesWithTheChain() {
        var bands = EqualizerBand.graphicDefaults
        bands[2].gainDecibels = -7
        bands[8].gainDecibels = 4

        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        chain.update(bands: bands)

        // The interface must draw what the engine will actually do. If these
        // two ever disagree, the curve is lying to the user.
        for frequency in [32.0, 125, 1_000, 8_000, 16_000] {
            let curve = EqualizerCurve.magnitudeDecibels(
                of: bands, atFrequency: frequency, sampleRate: sampleRate
            )
            let engine = chain.magnitudeDecibels(atFrequency: frequency)
            #expect(abs(curve - engine) < 0.001)
        }
    }

    @Test("points are logarithmically spaced and cover the range")
    func pointSpacing() {
        let points = EqualizerCurve.points(
            of: EqualizerBand.graphicDefaults,
            sampleRate: sampleRate,
            from: 20, to: 20_000, count: 100
        )

        #expect(points.count == 100)
        #expect(abs(points.first!.frequency - 20) < 0.001)
        #expect(abs(points.last!.frequency - 20_000) < 0.001)

        // Logarithmic spacing means every step multiplies by the same ratio.
        let firstRatio = points[1].frequency / points[0].frequency
        let lastRatio = points[99].frequency / points[98].frequency
        #expect(abs(firstRatio - lastRatio) < 0.000_1)
    }

    @Test("a single point request returns the low end rather than dividing by zero")
    func degenerateCount() {
        let points = EqualizerCurve.points(
            of: EqualizerBand.graphicDefaults,
            sampleRate: sampleRate,
            from: 20, to: 20_000, count: 1
        )

        #expect(points.count == 1)
        #expect(points[0].frequency == 20)
    }

    @Test("a nonsensical count returns nothing rather than trapping")
    func zeroCount() {
        #expect(
            EqualizerCurve.points(
                of: EqualizerBand.graphicDefaults,
                sampleRate: sampleRate,
                from: 20, to: 20_000, count: 0
            ).isEmpty
        )
        #expect(
            EqualizerCurve.points(
                of: EqualizerBand.graphicDefaults,
                sampleRate: sampleRate,
                from: 20, to: 20_000, count: -5
            ).isEmpty
        )
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter EqualizerCurveTests`
Expected: FAIL, compiler error `cannot find 'EqualizerCurve' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SonoraDSP/EqualizerCurve.swift`:

```swift
import Foundation

/// One sampled point of the equalizer's frequency response.
public struct CurvePoint: Equatable, Sendable {
    public let frequency: Double
    public let decibels: Float

    public init(frequency: Double, decibels: Float) {
        self.frequency = frequency
        self.decibels = decibels
    }
}

/// The equalizer's frequency response, computed from band definitions alone.
///
/// This deliberately does not go through `EqualizerChain`. That type's
/// coefficients are written by the audio thread through `applyCoefficients`, so
/// reading them to draw an interface would be an unsynchronised concurrent read
/// of a five float struct: the same tearing the chain's own threading contract
/// warns about, just in the other direction.
///
/// Taking bands by value shares nothing, which also makes the curve trivially
/// testable and safe to compute on any thread.
public enum EqualizerCurve {

    /// The combined response of every band at one frequency, in decibels.
    public static func magnitudeDecibels(
        of bands: [EqualizerBand],
        atFrequency frequency: Double,
        sampleRate: Double
    ) -> Float {
        bands.reduce(Float(0)) { total, band in
            let coefficients = BiquadCoefficients(
                kind: band.kind,
                frequency: band.frequency,
                q: band.q,
                gainDecibels: band.gainDecibels,
                sampleRate: sampleRate
            )
            return total + coefficients.magnitudeDecibels(
                atFrequency: frequency, sampleRate: sampleRate
            )
        }
    }

    /// The response sampled across a frequency range, spaced logarithmically
    /// because that is how the range reads to a listener and how it is drawn.
    public static func points(
        of bands: [EqualizerBand],
        sampleRate: Double,
        from lowest: Double,
        to highest: Double,
        count: Int
    ) -> [CurvePoint] {
        guard count > 0 else { return [] }
        guard count > 1 else {
            return [
                CurvePoint(
                    frequency: lowest,
                    decibels: magnitudeDecibels(
                        of: bands, atFrequency: lowest, sampleRate: sampleRate
                    )
                )
            ]
        }

        let ratio = pow(highest / lowest, 1 / Double(count - 1))

        return (0..<count).map { index in
            let frequency = lowest * pow(ratio, Double(index))
            return CurvePoint(
                frequency: frequency,
                decibels: magnitudeDecibels(
                    of: bands, atFrequency: frequency, sampleRate: sampleRate
                )
            )
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter EqualizerCurveTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS, 87 tests. It was 81 before this task.

- [ ] **Step 6: Commit**

```bash
git add Sources/SonoraDSP/EqualizerCurve.swift Tests/SonoraDSPTests/EqualizerCurveTests.swift
git commit -m "feat: add pure equalizer curve computed from band definitions"
```

---

### Task 2: System volume

**Files:**
- Create: `App/Sonora/SystemVolume.swift`

**Interfaces:**
- Consumes: `AudioObjectID` helpers from `App/Sonora/AudioEngine/AudioObjectID+Properties.swift`.
- Produces: `@MainActor final class SystemVolume` with `var scalar: Float { get set }`, `var isMuted: Bool { get set }`, `var outputDeviceName: String`, `var availableOutputs: [OutputDevice]`, `func selectOutput(_ device: OutputDevice)`, `func refresh()`, and `var onChange: (() -> Void)?`, plus `struct OutputDevice: Identifiable, Equatable { let id: AudioObjectID; let name: String }`.

**Note on scope:** this reads and writes the system output volume, which is a different thing from Sonora's preamp. The panel shows both, and the design document is explicit that the top slider is the system's and the preamp is Sonora's own digital gain.

- [ ] **Step 1: Write the implementation**

There is no unit test for this task: it reads and writes live Core Audio device state, and `App/` has no test target. It is verified by hand in Task 8's checklist.

Create `App/Sonora/SystemVolume.swift`:

```swift
import CoreAudio
import Foundation
import OSLog

/// The system output volume, which is the thing the top slider in the panel
/// moves. Distinct from Sonora's preamp, which is its own digital gain applied
/// inside the equalizer chain.
///
/// Main actor isolated: every caller is the interface, and the property
/// listener hops here before reporting.
@MainActor
final class SystemVolume {

    /// Called when the volume, the mute state, or the output device changes.
    var onChange: (() -> Void)?

    private(set) var outputDeviceName = "Unknown"

    /// One device the panel can switch to.
    struct OutputDevice: Identifiable, Equatable {
        let id: AudioObjectID
        let name: String
    }

    private var deviceID = AudioObjectID.unknown
    private let logger = Logger(subsystem: "com.sonora.Sonora", category: "SystemVolume")
    private let queue = DispatchQueue(label: "com.sonora.SystemVolume")
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        refresh()
    }

    deinit {
        // Listener removal needs the same addresses it registered with; the
        // objects die with the process anyway, so nothing is leaked in practice.
    }

    /// 0 to 1. Reads and writes `kAudioDevicePropertyVolumeScalar` on the
    /// output scope's main element.
    var scalar: Float {
        get {
            guard deviceID.isValid else { return 0 }
            var address = Self.volumeAddress
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)

            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
            guard status == noErr else { return 0 }
            return value
        }
        set {
            guard deviceID.isValid else { return }
            var address = Self.volumeAddress
            var value = Float32(min(max(newValue, 0), 1))
            let size = UInt32(MemoryLayout<Float32>.size)

            let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
            if status != noErr {
                logger.error("Could not set output volume: \(status, privacy: .public)")
            }
        }
    }

    var isMuted: Bool {
        get {
            guard deviceID.isValid else { return false }
            var address = Self.muteAddress
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)

            let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
            guard status == noErr else { return false }
            return value != 0
        }
        set {
            guard deviceID.isValid else { return }
            var address = Self.muteAddress
            var value: UInt32 = newValue ? 1 : 0
            let size = UInt32(MemoryLayout<UInt32>.size)

            let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
            if status != noErr {
                logger.error("Could not set mute: \(status, privacy: .public)")
            }
        }
    }

    /// Every device that can play audio, for the panel's output picker.
    private(set) var availableOutputs: [OutputDevice] = []

    /// Makes a device the system default. The engine's own device watcher
    /// notices and rebuilds the audio path around it, so nothing here has to.
    func selectOutput(_ device: OutputDevice) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = device.id
        let size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectSetPropertyData(
            AudioObjectID.system, &address, 0, nil, size, &id
        )
        if status != noErr {
            logger.error("Could not switch output device: \(status, privacy: .public)")
        }
    }

    /// Enumerates devices that have at least one output channel.
    private func readAvailableOutputs() -> [OutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID.system, &address, 0, nil, &size
        ) == noErr else { return [] }

        var ids = [AudioObjectID](
            repeating: .unknown, count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID.system, &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasOutputChannels(id), let name = try? id.readString(kAudioObjectPropertyName) else {
                return nil
            }
            return OutputDevice(id: id, name: name)
        }
    }

    private func hasOutputChannels(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
            return false
        }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    /// Re-reads the default output device and re-registers listeners on it.
    /// Call after the engine reports a device change.
    func refresh() {
        removeListeners()

        guard let device = try? AudioObjectID.readDefaultOutputDevice() else {
            deviceID = .unknown
            outputDeviceName = "No output device"
            onChange?()
            return
        }

        deviceID = device
        outputDeviceName = (try? device.readString(kAudioObjectPropertyName)) ?? "Unknown"
        availableOutputs = readAvailableOutputs()

        addListener(on: device, address: Self.volumeAddress)
        addListener(on: device, address: Self.muteAddress)
        onChange?()
    }

    private func addListener(on device: AudioObjectID, address: AudioObjectPropertyAddress) {
        var mutableAddress = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.onChange?() }
        }

        let status = AudioObjectAddPropertyListenerBlock(device, &mutableAddress, queue, block)
        guard status == noErr else {
            logger.error("Could not observe volume property: \(status, privacy: .public)")
            return
        }
        listeners.append((device, address, block))
    }

    private func removeListeners() {
        for (device, address, block) in listeners {
            var mutableAddress = address
            AudioObjectRemovePropertyListenerBlock(device, &mutableAddress, queue, block)
        }
        listeners.removeAll()
    }

    private static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
}
```

- [ ] **Step 2: Build**

Run:
```bash
export SONORA_CODE_SIGN_IDENTITY="Apple Development: YOUR NAME (YOURTEAMID)"
cd App && xcodegen generate && xcodebuild -project Sonora.xcodeproj -scheme Sonora -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/Sonora/SystemVolume.swift
git commit -m "feat: read and write the system output volume"
```

---

### Task 3: Panel model

**Files:**
- Create: `App/Sonora/UI/PanelModel.swift`

**Interfaces:**
- Consumes: `AudioEngineController` (`parameters`, `update(_:)`, `activePresetID`, `setActivePresetID(_:)`, `state`, `onStateChange`, `retry()`), `SystemVolume`, `EngineParameters`, `EqualizerBand`, `BuiltInPresets`, `Preset`, `EqualizerCurve`.
- Produces: `@MainActor @Observable final class PanelModel` with `var systemVolume: Float`, `var preampDecibels: Double`, `var isBypassed: Bool`, `var bandGains: [Double]`, `var activePresetID: String?`, `var outputDeviceName: String`, `var availableOutputs: [SystemVolume.OutputDevice]`, `func selectOutput(_:)`, `var stateDescription: String`, `var isRunning: Bool`, `let presets: [Preset]`, `func curvePoints(count: Int) -> [CurvePoint]`, `func selectPreset(_ preset: Preset)`, `func resetToFlat()`, `func retry()`.

**Design note:** this is the only type in the interface that touches the engine. Views read and write the model, never the controller. That keeps the thread rule in one place: the model is `@MainActor`, so nothing in a view can reach the engine off the main thread.

- [ ] **Step 1: Write the implementation**

Create `App/Sonora/UI/PanelModel.swift`:

```swift
import Foundation
import Observation
import SonoraDSP
import SonoraProfiles

/// Everything the panel shows and changes.
///
/// The only type in the interface that talks to `AudioEngineController`. Views
/// bind to this and never reach past it, so the rule that the engine is touched
/// from the main actor lives in exactly one file.
///
/// Band gains are held as a plain `[Double]` rather than `[EqualizerBand]`
/// because that is what a slider binds to. The full band definitions are
/// rebuilt from the graphic layout when publishing, which is also what keeps a
/// slider from silently changing a band's frequency or Q.
@MainActor
@Observable
final class PanelModel {

    let presets: [Preset] = BuiltInPresets.all

    var systemVolume: Float {
        didSet { volume.scalar = systemVolume }
    }

    var preampDecibels: Double {
        didSet { publish() }
    }

    var isBypassed: Bool {
        didSet { publish() }
    }

    var bandGains: [Double] {
        didSet {
            guard bandGains != oldValue else { return }

            // A hand moved a slider, so this is no longer any named preset.
            // Suppressed while a preset is being applied, which also moves
            // these values.
            if !isApplyingPreset, activePresetID != nil {
                activePresetID = nil
                engine.setActivePresetID(nil)
            }
            publish()
        }
    }

    private(set) var activePresetID: String?
    private(set) var outputDeviceName: String
    private(set) var availableOutputs: [SystemVolume.OutputDevice] = []
    private(set) var stateDescription: String
    private(set) var isRunning: Bool

    private let engine: AudioEngineController
    private let volume: SystemVolume
    private var isApplyingPreset = false

    init(engine: AudioEngineController, volume: SystemVolume) {
        self.engine = engine
        self.volume = volume

        let parameters = engine.parameters
        self.preampDecibels = parameters.preampDecibels
        self.isBypassed = parameters.isBypassed
        self.bandGains = parameters.bands.map(\.gainDecibels)
        self.activePresetID = engine.activePresetID
        self.systemVolume = volume.scalar
        self.outputDeviceName = volume.outputDeviceName
        self.availableOutputs = volume.availableOutputs
        self.stateDescription = Self.describe(engine.state)
        self.isRunning = engine.state == .running

        engine.onStateChange = { [weak self] state in
            Task { @MainActor in self?.engineStateChanged(state) }
        }
        volume.onChange = { [weak self] in
            Task { @MainActor in self?.volumeChanged() }
        }
    }

    /// The curve the view draws, computed from the band definitions rather than
    /// from the live chain, which the audio thread owns.
    func curvePoints(count: Int) -> [CurvePoint] {
        EqualizerCurve.points(
            of: bands(),
            sampleRate: 48_000,
            from: 20,
            to: 20_000,
            count: count
        )
    }

    func selectPreset(_ preset: Preset) {
        // The flag suppresses both the deselect logic and the intermediate
        // publishes the two assignments below would otherwise each trigger.
        // Every publish writes the settings file, so this is one write rather
        // than three.
        isApplyingPreset = true
        bandGains = preset.bands.map(\.gainDecibels)
        preampDecibels = preset.preampDecibels
        isApplyingPreset = false

        activePresetID = preset.id
        engine.setActivePresetID(preset.id)
        publish()
    }

    func selectOutput(_ device: SystemVolume.OutputDevice) {
        volume.selectOutput(device)
    }

    func resetToFlat() {
        selectPreset(BuiltInPresets.flat)
    }

    func retry() {
        engine.retry()
    }

    private func bands() -> [EqualizerBand] {
        zip(EqualizerBand.graphicFrequencies, bandGains).map { frequency, gain in
            EqualizerBand(kind: .peaking, frequency: frequency, q: 1.41, gainDecibels: gain)
        }
    }

    private func publish() {
        guard !isApplyingPreset else { return }

        engine.update(
            EngineParameters(
                isBypassed: isBypassed,
                preampDecibels: preampDecibels,
                bands: bands()
            )
        )
    }

    private func engineStateChanged(_ state: AudioEngineController.State) {
        stateDescription = Self.describe(state)
        isRunning = state == .running
        outputDeviceName = volume.outputDeviceName
    }

    private func volumeChanged() {
        systemVolume = volume.scalar
        outputDeviceName = volume.outputDeviceName
        availableOutputs = volume.availableOutputs
    }

    private static func describe(_ state: AudioEngineController.State) -> String {
        switch state {
        case .stopped: "Stopped"
        case .running: "Running"
        case .bypassed(let reason): reason
        }
    }
}
```

- [ ] **Step 2: Build**

Run:
```bash
export SONORA_CODE_SIGN_IDENTITY="Apple Development: YOUR NAME (YOURTEAMID)"
cd App && xcodegen generate && xcodebuild -project Sonora.xcodeproj -scheme Sonora -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

If the compiler objects to `volume.scalar` being set from `didSet` under strict concurrency, do not reach for `@unchecked Sendable`. Report the exact diagnostic.

- [ ] **Step 3: Commit**

```bash
git add App/Sonora/UI/PanelModel.swift
git commit -m "feat: add the panel model, the only interface type that talks to the engine"
```

---

### Task 4: Curve view

**Files:**
- Create: `App/Sonora/UI/CurveView.swift`

**Interfaces:**
- Consumes: `PanelModel.curvePoints(count:)`, `CurvePoint`.
- Produces: `struct CurveView: View` with `init(points: [CurvePoint], range: ClosedRange<Double>)`.

- [ ] **Step 1: Write the implementation**

Create `App/Sonora/UI/CurveView.swift`:

```swift
import SonoraDSP
import SwiftUI

/// The equalizer's response, drawn behind the band sliders.
///
/// Takes points rather than a model so it stays a pure function of its input,
/// which makes it previewable and keeps it from reaching the engine.
struct CurveView: View {

    let points: [CurvePoint]

    /// Vertical range in decibels. Matches the sliders' range so the curve and
    /// the handles line up.
    let range: ClosedRange<Double>

    var body: some View {
        Canvas { context, size in
            guard points.count > 1 else { return }

            var path = Path()
            for (index, point) in points.enumerated() {
                let x = size.width * Double(index) / Double(points.count - 1)
                let y = yPosition(for: Double(point.decibels), in: size.height)

                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            // A filled area under the line reads as "this much gain" at a
            // glance, where a bare line reads as a graph to be studied.
            var fill = path
            fill.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            fill.addLine(to: CGPoint(x: 0, y: size.height / 2))
            fill.closeSubpath()

            context.fill(
                fill,
                with: .linearGradient(
                    Gradient(colors: [.accentColor.opacity(0.35), .accentColor.opacity(0.05)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            context.stroke(path, with: .color(.accentColor), lineWidth: 2)

            // The zero line, so a boost is visibly distinct from a cut.
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: size.height / 2))
            zero.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(
                zero,
                with: .color(.secondary.opacity(0.3)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
        }
        .accessibilityHidden(true)
    }

    private func yPosition(for decibels: Double, in height: Double) -> Double {
        let clamped = min(max(decibels, range.lowerBound), range.upperBound)
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return height / 2 }

        let normalised = (clamped - range.lowerBound) / span
        return height * (1 - normalised)
    }
}
```

- [ ] **Step 2: Build**

Run the standard build. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/Sonora/UI/CurveView.swift
git commit -m "feat: draw the equalizer curve"
```

---

### Task 5: Band sliders

**Files:**
- Create: `App/Sonora/UI/BandSliders.swift`

**Interfaces:**
- Consumes: `EqualizerBand.graphicFrequencies`, `EqualizerBand.gainRange`.
- Produces: `struct BandSliders: View` with `init(gains: Binding<[Double]>)`.

- [ ] **Step 1: Write the implementation**

Create `App/Sonora/UI/BandSliders.swift`:

```swift
import SonoraDSP
import SwiftUI

/// The ten band sliders, laid out under the curve.
struct BandSliders: View {

    @Binding var gains: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(EqualizerBand.graphicFrequencies.enumerated()), id: \.offset) { index, frequency in
                VStack(spacing: 4) {
                    Slider(
                        value: binding(for: index),
                        in: EqualizerBand.gainRange
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 90, height: 20)
                    .frame(height: 110)
                    .accessibilityLabel(Self.label(for: frequency))
                    .accessibilityValue(Self.value(for: gains[safe: index] ?? 0))

                    Text(Self.shortLabel(for: frequency))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    /// Guards the index, because a settings file with the wrong band count
    /// would otherwise crash the interface rather than showing something wrong.
    private func binding(for index: Int) -> Binding<Double> {
        Binding(
            get: { gains[safe: index] ?? 0 },
            set: { newValue in
                guard gains.indices.contains(index) else { return }
                gains[index] = newValue
            }
        )
    }

    private static func shortLabel(for frequency: Double) -> String {
        frequency >= 1_000
            ? "\(Int(frequency / 1_000))k"
            : "\(Int(frequency))"
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

extension Array {
    /// Index access that returns nil rather than trapping. The interface reads
    /// band gains that ultimately came off disk, and a wrong count there should
    /// look wrong, not crash.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
```

- [ ] **Step 2: Build**

Run the standard build. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/Sonora/UI/BandSliders.swift
git commit -m "feat: add the ten band sliders"
```

---

### Task 6: Preset strip

**Files:**
- Create: `App/Sonora/UI/PresetStrip.swift`

**Interfaces:**
- Consumes: `Preset`, `PanelModel.presets`, `PanelModel.activePresetID`, `PanelModel.selectPreset(_:)`.
- Produces: `struct PresetStrip: View` with `init(presets: [Preset], activeID: String?, onSelect: @escaping (Preset) -> Void)`.

- [ ] **Step 1: Write the implementation**

Create `App/Sonora/UI/PresetStrip.swift`:

```swift
import SonoraProfiles
import SwiftUI

/// The preset picker, a horizontal row of pills.
struct PresetStrip: View {

    let presets: [Preset]
    let activeID: String?
    let onSelect: (Preset) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(presets) { preset in
                    Button {
                        onSelect(preset)
                    } label: {
                        Text(preset.name)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(
                                    preset.id == activeID
                                        ? AnyShapeStyle(.tint)
                                        : AnyShapeStyle(.quaternary)
                                )
                            )
                            .foregroundStyle(preset.id == activeID ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(preset.id == activeID ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollIndicators(.never)
    }
}
```

- [ ] **Step 2: Build**

Run the standard build. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/Sonora/UI/PresetStrip.swift
git commit -m "feat: add the preset strip"
```

---

### Task 7: Panel layout

**Files:**
- Create: `App/Sonora/UI/PanelView.swift`

**Interfaces:**
- Consumes: `PanelModel`, `CurveView`, `BandSliders`, `PresetStrip`.
- Produces: `struct PanelView: View` with `init(model: PanelModel)`.

**Layout, from the design document's section 7.1, top to bottom:** system volume with the output device name, Sonora's preamp, the curve with the band sliders under it, the preset strip.

- [ ] **Step 1: Write the implementation**

Create `App/Sonora/UI/PanelView.swift`:

```swift
import SonoraDSP
import SwiftUI

struct PanelView: View {

    @Bindable var model: PanelModel

    private static let gainRange = EqualizerBand.gainRange

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            preamp
            equalizer
            Divider()
            PresetStrip(
                presets: model.presets,
                activeID: model.activePresetID,
                onSelect: model.selectPreset
            )
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Menu {
                    ForEach(model.availableOutputs) { device in
                        Button(device.name) { model.selectOutput(device) }
                    }
                } label: {
                    Text(model.outputDeviceName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Output device")

                Spacer()
                Toggle("Bypass", isOn: $model.isBypassed)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel("Bypass equalizer")
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Slider(value: $model.systemVolume, in: 0...1)
                    .accessibilityLabel("System volume")
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }
        }
    }

    private var preamp: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Preamp")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%+.1f dB", model.preampDecibels))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    // Above unity the limiter starts doing real work, so the
                    // number says so rather than leaving it to be discovered.
                    .foregroundStyle(model.preampDecibels > 0 ? .orange : .secondary)
            }
            Slider(value: $model.preampDecibels, in: Self.gainRange)
                .accessibilityLabel("Preamp")
        }
    }

    private var equalizer: some View {
        ZStack(alignment: .top) {
            CurveView(
                points: model.curvePoints(count: 120),
                range: Self.gainRange
            )
            .frame(height: 110)
            .opacity(model.isBypassed ? 0.25 : 1)

            BandSliders(gains: $model.bandGains)
        }
        .frame(height: 140)
    }

    private var footer: some View {
        HStack {
            Text(model.stateDescription)
                .font(.system(size: 10))
                .foregroundStyle(model.isRunning ? .secondary : .orange)
                .lineLimit(1)

            Spacer()

            if !model.isRunning {
                Button("Try Again", action: model.retry)
                    .controlSize(.small)
            }

            Button("Flat", action: model.resetToFlat)
                .controlSize(.small)
        }
    }
}
```

- [ ] **Step 2: Build**

Run the standard build. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/Sonora/UI/PanelView.swift
git commit -m "feat: lay out the panel"
```

---

### Task 8: Panel window and status item wiring

**Files:**
- Create: `App/Sonora/PanelController.swift`
- Modify: `App/Sonora/StatusMenuController.swift`
- Modify: `App/Sonora/AppDelegate.swift`

**Interfaces:**
- Consumes: `PanelModel`, `PanelView`, `AudioEngineController`, `SystemVolume`.
- Produces: `@MainActor final class PanelController` with `init(model: PanelModel)`, `func toggle(from button: NSStatusBarButton)`, `func close()`.

**Behaviour:** left click on the status item opens the panel under it and closes it on the next click or when it loses focus. Right click keeps a small menu with Quit, so the app is always quittable even if the panel misbehaves.

- [ ] **Step 1: Write the panel controller**

Create `App/Sonora/PanelController.swift`:

```swift
import AppKit
import SwiftUI

/// Owns the panel window and anchors it under the status item.
///
/// An `NSPanel` rather than a popover: a popover steals focus in ways that
/// fight with a menu bar utility, and a non-activating panel lets the user keep
/// working while they drag a slider.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {

    private let model: PanelModel
    private var panel: NSPanel?

    init(model: PanelModel) {
        self.model = model
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(from button: NSStatusBarButton) {
        if isVisible {
            close()
        } else {
            show(from: button)
        }
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func show(from button: NSStatusBarButton) {
        let panel = existingOrNewPanel()

        guard let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.frame)

        // Centred under the status item, nudged in from the screen edge so the
        // panel is never half off the display on a narrow menu bar position.
        var origin = NSPoint(
            x: buttonRect.midX - panel.frame.width / 2,
            y: buttonRect.minY - panel.frame.height - 6
        )
        if let screen = buttonWindow.screen {
            let limit = screen.visibleFrame
            origin.x = min(max(origin.x, limit.minX + 8), limit.maxX - panel.frame.width - 8)
        }

        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func existingOrNewPanel() -> NSPanel {
        if let panel { return panel }

        let hosting = NSHostingView(rootView: PanelView(model: model))
        hosting.layout()

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = true
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.delegate = self
        panel.setContentSize(hosting.fittingSize)

        self.panel = panel
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
```

- [ ] **Step 2: Reduce the status menu to a right-click menu**

Replace `App/Sonora/StatusMenuController.swift` in full:

```swift
import AppKit

/// The status item's behaviour: left click opens the panel, right click gives a
/// small menu.
///
/// The menu is deliberately kept, rather than folded into the panel, so the app
/// is always quittable even if the panel fails to show.
@MainActor
final class StatusMenuController: NSObject {

    private let panelController: PanelController
    private weak var statusItem: NSStatusItem?

    init(panelController: PanelController) {
        self.panelController = panelController
        super.init()
    }

    func install(in statusItem: NSStatusItem) {
        self.statusItem = statusItem

        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem?.button else { return }

        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(from: button)
        } else {
            panelController.toggle(from: button)
        }
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Quit Sonora",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // Attaching the menu makes the next click open it; detaching afterwards
        // gives the left click back to the panel.
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }
}
```

- [ ] **Step 3: Wire it up**

Replace `App/Sonora/AppDelegate.swift` in full:

```swift
import AppKit
import SonoraPersistence

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var statusItem: NSStatusItem!

    private let engine = AudioEngineController(
        settingsStore: SettingsStore(directory: SettingsStore.defaultDirectory())
    )
    private let volume = SystemVolume()

    private lazy var model = PanelModel(engine: engine, volume: volume)
    private lazy var panelController = PanelController(model: model)
    private lazy var menuController = StatusMenuController(panelController: panelController)

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
        panelController.close()
        engine.stop()
    }
}
```

- [ ] **Step 4: Build**

Run:
```bash
export SONORA_CODE_SIGN_IDENTITY="Apple Development: YOUR NAME (YOURTEAMID)"
cd App && xcodegen generate && xcodebuild -project Sonora.xcodeproj -scheme Sonora -configuration Debug build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Verify the signature**

Run: `codesign -dv --verbose=4 <built app>`
Expected: `flags=0x10000(runtime)` and an `Authority=Apple Development: ...` line.

- [ ] **Step 6: Run the package suite**

Run: `swift test`
Expected: PASS, 87 tests.

- [ ] **Step 7: Commit**

```bash
git add App/Sonora
git commit -m "feat: open the panel from the status item"
```

- [ ] **Step 8: Hand the runtime checklist to a human**

These cannot be verified without a person at the machine, with audio playing. List them in the report rather than marking them done:

1. Left click on the status item opens the panel under it; a second click closes it.
2. Clicking elsewhere closes the panel.
3. Right click gives the Quit menu.
4. Dragging a band slider changes the sound as it moves, with no clicks.
5. The curve follows the sliders.
6. Choosing a preset moves both the sliders and the curve, and changes the sound.
7. Moving a band slider after choosing a preset deselects the preset.
8. The preamp slider changes loudness, and its number turns orange above 0 dB.
9. The system volume slider moves the actual system volume, and moving the system volume elsewhere moves the slider.
10. Bypass silences the effect and restores it, and dims the curve.
11. The output device name is correct, and updates when headphones are plugged in.
12. Quit and relaunch: the last state is restored.

---

## Definition of done

1. `swift test` passes at 87 tests.
2. The app builds signed, with Hardened Runtime on.
3. The panel opens from the status item and every control in it drives the engine.
4. The runtime checklist above has been run by a human and its results recorded.

## What comes next

A separate plan covers system integration and distribution: volume key capture through `CGEventTap`, the accessibility permission and its onboarding, the first-run permission explanation, and a notarised DMG with a Homebrew cask.

## Carried over, not addressed here

From the engine review, still open and deliberately not in this plan:
- `EqualizerChain`'s threading contract does not mention `magnitudeDecibels`, `bands` or `reset()`, all of which cross threads. This plan avoids the interface half of that problem by not calling `magnitudeDecibels` from the interface at all, but the contract is still incomplete.
- `bands` and `bandCount` can diverge after `applyCoefficients`.
- No path exists to change a chain's sample rate after construction; the engine rebuilds the chain instead, which works but leaves `SmoothedValue.setSampleRate` unreachable from production code.
- `Codable` round trips encode and decode with the same code, so no test fails on a schema change. A golden JSON fixture would fix that.
- `EqualizerBand.gainRange` is declared and tested but never enforced against data read from disk.
- `swift_beginAccess` is on the render path in release builds, which can allocate on its first call per thread. Settling exclusivity checking for `SonoraDSP` would remove it.
