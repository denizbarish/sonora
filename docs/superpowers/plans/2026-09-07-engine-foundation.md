# Sonora Engine Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the tested DSP core and a signed macOS app that captures system audio through a Core Audio process tap, applies a 10-band equalizer in real time, and survives output device changes.

**Architecture:** A dependency-free Swift package (`SonoraDSP` -> `SonoraProfiles` -> `SonoraPersistence`) holds all logic that can be unit tested without Core Audio. A thin Xcode app target, generated from `project.yml` by XcodeGen, owns the Core Audio layer: a global process tap muted at the source, wrapped in a private aggregate device whose main sub-device is the real output device, driven by an `IOProc` block that runs the DSP chain. Parameters cross into the real-time thread through a lock-free double-buffered snapshot.

**Tech Stack:** Swift 6.2, Swift Testing, Swift Package Manager, XcodeGen 2.46.0, swift-atomics 1.3.1, Core Audio (`CATapDescription`, `AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice`, `AudioDeviceCreateIOProcIDWithBlock`), Accelerate, AppKit.

**Scope:** This plan covers Phase 0 and the engine half of Phase 1 from the design document. It ends with a working app that applies equalization, controlled from a minimal status bar menu. The full panel UI, media key capture, onboarding and release packaging are a separate plan, written after Task 12 produces the latency measurement that decides whether the tap architecture holds.

**Spec:** `docs/superpowers/specs/2026-09-07-sonora-design.md`

## Global Constraints

- Deployment target is exactly macOS 14.4. Lower versions land in a different TCC category.
- Swift 6.2, Swift language mode 6, strict concurrency. Xcode 26.3.
- Never use `AVAudioEngine` or `AVAudioUnitEQ` on the tap path. They cannot be retargeted to a tap-backed aggregate device and fail silently.
- Never set `CATapDescription.isExclusive` after using `init(stereoGlobalTapButExcludeProcesses:)`. It is a direction flag, not a lock toggle.
- The aggregate device's main sub-device must be a real output device. The tap is attached as a sub-tap.
- Inside the `IOProc` block: no locks, no memory allocation, no Swift runtime metadata calls, no Objective-C messages, no logging, no file access. This includes Swift array traffic: audio path storage is preallocated `UnsafeMutableBufferPointer`, never `Array`.
- Filter coefficients are computed on the interface thread only. The audio thread receives finished coefficients and copies plain floats. Nothing on the audio path calls `BiquadCoefficients.init(kind:frequency:q:gainDecibels:sampleRate:)`.
- All gain and coefficient changes ramp over 30 ms. `rampCoefficient = 1 - exp(-1 / (sampleRate * 0.030))`.
- Every failure path must end in bypass (tap destroyed, audio back on the normal system route) or a user-visible warning. No silently swallowed errors.
- App Sandbox off (`com.apple.security.app-sandbox = false`), Hardened Runtime on.
- `NSAudioCaptureUsageDescription` must be in `Info.plist`. It is not in Xcode's key dropdown, type it manually.
- Process taps require a signed binary. Unsigned builds compile and run but never surface the permission prompt.
- Code, comments, commit messages, and user-facing UI strings are in English. The repository is public and international.
- License is MIT. Every new source file gets no license header; the root `LICENSE` covers the repository.
- Commit after every task. Conventional commit prefixes: `feat:`, `fix:`, `test:`, `docs:`, `chore:`, `refactor:`.

---

### Task 1: Package skeleton and SmoothedValue

**Files:**
- Create: `Package.swift`
- Create: `Sources/SonoraDSP/SmoothedValue.swift`
- Test: `Tests/SonoraDSPTests/SmoothedValueTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `SmoothedValue` with `init(value: Float, sampleRate: Double, rampSeconds: Float = 0.030)`, `var target: Float`, `var current: Float { get }`, `mutating func nextValue() -> Float`, `mutating func snap(to: Float)`, `mutating func setSampleRate(_ sampleRate: Double)`. Used by Task 5 (`DSPChain` preamp) and Task 4 (`EqualizerChain` gain interpolation).

- [ ] **Step 1: Create the package manifest**

The manifest declares only the targets that have source files. SwiftPM refuses to
resolve a package containing an empty target, so `SonoraProfiles` and
`SonoraPersistence` are added later, by the tasks that populate them (Task 6 and
Task 7). Do not declare them here, and do not create placeholder source files to
work around the validation error.

Create `Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SonoraCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SonoraDSP", targets: ["SonoraDSP"]),
    ],
    targets: [
        .target(name: "SonoraDSP"),
        .testTarget(name: "SonoraDSPTests", dependencies: ["SonoraDSP"]),
    ]
)
```

- [ ] **Step 2: Write the failing test**

Create `Tests/SonoraDSPTests/SmoothedValueTests.swift`:

```swift
import Testing
import Foundation
@testable import SonoraDSP

@Suite("SmoothedValue")
struct SmoothedValueTests {

    @Test("reaches roughly one time constant after the ramp duration")
    func oneTimeConstant() {
        var value = SmoothedValue(value: 0, sampleRate: 48_000, rampSeconds: 0.030)
        value.target = 1

        let samplesInRamp = Int(48_000 * 0.030)
        for _ in 0..<samplesInRamp {
            _ = value.nextValue()
        }

        // An exponential ramp covers 1 - 1/e of the distance in one time constant.
        #expect(abs(value.current - 0.632) < 0.01)
    }

    @Test("converges to the target after five time constants")
    func convergence() {
        var value = SmoothedValue(value: 0, sampleRate: 48_000, rampSeconds: 0.030)
        value.target = 2

        for _ in 0..<Int(48_000 * 0.030 * 5) {
            _ = value.nextValue()
        }

        // A one-pole ramp leaves exp(-5) of the distance after five time
        // constants, which is 0.0135 out of 2. Anything tighter is impossible
        // for this filter, not a bug.
        #expect(abs(value.current - 2) < 0.02)
    }

    @Test("snap jumps immediately without ramping")
    func snap() {
        var value = SmoothedValue(value: 0, sampleRate: 48_000)
        value.snap(to: 0.5)

        #expect(value.current == 0.5)
        #expect(value.nextValue() == 0.5)
    }

    @Test("changing sample rate keeps the ramp duration in seconds")
    func sampleRateChange() {
        var value = SmoothedValue(value: 0, sampleRate: 48_000, rampSeconds: 0.030)
        value.setSampleRate(96_000)
        value.target = 1

        for _ in 0..<Int(96_000 * 0.030) {
            _ = value.nextValue()
        }

        #expect(abs(value.current - 0.632) < 0.01)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter SmoothedValueTests`
Expected: FAIL, compiler error `cannot find 'SmoothedValue' in scope`.

- [ ] **Step 4: Write the implementation**

Create `Sources/SonoraDSP/SmoothedValue.swift`:

```swift
import Foundation

/// A value that moves toward its target along a one-pole exponential ramp.
///
/// Every gain change in the signal path goes through this type. Applying a new
/// gain instantly produces an audible click, so changes are spread over
/// `rampSeconds` worth of samples.
///
/// This is a value type with no allocations, safe to advance from the real-time
/// audio thread.
public struct SmoothedValue: Sendable {

    /// The value the ramp is heading toward.
    public var target: Float

    /// The value the ramp has reached.
    public private(set) var current: Float

    private var rampSeconds: Float
    private var coefficient: Float

    public init(value: Float, sampleRate: Double, rampSeconds: Float = 0.030) {
        self.target = value
        self.current = value
        self.rampSeconds = rampSeconds
        self.coefficient = Self.coefficient(sampleRate: sampleRate, rampSeconds: rampSeconds)
    }

    /// Advances the ramp by one sample and returns the new value.
    public mutating func nextValue() -> Float {
        current += (target - current) * coefficient
        return current
    }

    /// Jumps to a value with no ramp. Use when starting the engine or after a
    /// format change, never in response to a user gesture.
    public mutating func snap(to value: Float) {
        target = value
        current = value
    }

    /// Recomputes the ramp for a new sample rate, keeping the duration in seconds.
    public mutating func setSampleRate(_ sampleRate: Double) {
        coefficient = Self.coefficient(sampleRate: sampleRate, rampSeconds: rampSeconds)
    }

    /// A coefficient of 1 means "no smoothing": `nextValue` jumps straight to
    /// the target. That is the deliberate fallback for a nonsensical sample rate
    /// or ramp duration, including NaN, which fails both comparisons. Snapping is
    /// wrong-sounding but safe; a NaN coefficient would poison the whole signal.
    ///
    /// Computed in `Double` and narrowed at the end. This runs in `init` and
    /// `setSampleRate`, never on the audio path, so there is no reason to give up
    /// the precision.
    private static func coefficient(sampleRate: Double, rampSeconds: Float) -> Float {
        guard sampleRate > 0, rampSeconds > 0 else { return 1 }
        return Float(1 - exp(-1 / (sampleRate * Double(rampSeconds))))
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter SmoothedValueTests`
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/SonoraDSP/SmoothedValue.swift Tests/SonoraDSPTests/SmoothedValueTests.swift
git commit -m "feat: add SmoothedValue exponential ramp and package skeleton"
```

---

### Task 2: Biquad coefficients

**Files:**
- Create: `Sources/SonoraDSP/BiquadCoefficients.swift`
- Test: `Tests/SonoraDSPTests/BiquadCoefficientsTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum FilterKind { case peaking, lowShelf, highShelf, highPass, lowPass }` and `struct BiquadCoefficients` with stored `b0, b1, b2, a1, a2: Float` (normalized by `a0`), `static let identity: BiquadCoefficients`, `init(kind:frequency:q:gainDecibels:sampleRate:)`, and `func magnitudeDecibels(atFrequency:sampleRate:) -> Float`. Used by Task 3 (`Biquad`), Task 4 (`EqualizerChain`) and the curve view in a later plan.

- [ ] **Step 1: Write the failing test**

Create `Tests/SonoraDSPTests/BiquadCoefficientsTests.swift`:

```swift
import Testing
import Foundation
@testable import SonoraDSP

@Suite("BiquadCoefficients")
struct BiquadCoefficientsTests {

    let sampleRate = 48_000.0

    @Test("peaking filter hits its exact gain at the centre frequency")
    func peakingGainAtCentre() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 1_000, q: 1.41, gainDecibels: 6, sampleRate: sampleRate
        )

        let magnitude = coefficients.magnitudeDecibels(atFrequency: 1_000, sampleRate: sampleRate)
        #expect(abs(magnitude - 6) < 0.01)
    }

    @Test("peaking filter is transparent far from the centre frequency")
    func peakingTransparentAway() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 1_000, q: 1.41, gainDecibels: 6, sampleRate: sampleRate
        )

        #expect(abs(coefficients.magnitudeDecibels(atFrequency: 20, sampleRate: sampleRate)) < 0.2)
        #expect(abs(coefficients.magnitudeDecibels(atFrequency: 18_000, sampleRate: sampleRate)) < 0.2)
    }

    @Test("cut is the mirror of boost at the centre frequency")
    func symmetricCut() {
        let cut = BiquadCoefficients(
            kind: .peaking, frequency: 2_000, q: 1.41, gainDecibels: -9, sampleRate: sampleRate
        )

        let magnitude = cut.magnitudeDecibels(atFrequency: 2_000, sampleRate: sampleRate)
        #expect(abs(magnitude + 9) < 0.01)
    }

    @Test("zero gain produces a flat response at every frequency")
    func zeroGainIsFlat() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 1_000, q: 1.41, gainDecibels: 0, sampleRate: sampleRate
        )

        for frequency in [20.0, 100, 1_000, 5_000, 20_000] as [Double] {
            let magnitude = coefficients.magnitudeDecibels(
                atFrequency: frequency, sampleRate: sampleRate
            )
            #expect(abs(magnitude) < 0.0001)
        }
    }

    @Test("low shelf lifts the bottom and leaves the top alone")
    func lowShelf() {
        let coefficients = BiquadCoefficients(
            kind: .lowShelf, frequency: 200, q: 0.707, gainDecibels: 6, sampleRate: sampleRate
        )

        #expect(abs(coefficients.magnitudeDecibels(atFrequency: 20, sampleRate: sampleRate) - 6) < 0.3)
        #expect(abs(coefficients.magnitudeDecibels(atFrequency: 10_000, sampleRate: sampleRate)) < 0.2)
    }

    @Test("high shelf lifts the top and leaves the bottom alone")
    func highShelf() {
        let coefficients = BiquadCoefficients(
            kind: .highShelf, frequency: 4_000, q: 0.707, gainDecibels: 6, sampleRate: sampleRate
        )

        #expect(abs(coefficients.magnitudeDecibels(atFrequency: 18_000, sampleRate: sampleRate) - 6) < 0.3)
        #expect(abs(coefficients.magnitudeDecibels(atFrequency: 100, sampleRate: sampleRate)) < 0.2)
    }

    @Test("high pass is down 3 dB at the cutoff frequency")
    func highPassCutoff() {
        let coefficients = BiquadCoefficients(
            kind: .highPass, frequency: 1_000, q: 0.707, gainDecibels: 0, sampleRate: sampleRate
        )

        let magnitude = coefficients.magnitudeDecibels(atFrequency: 1_000, sampleRate: sampleRate)
        #expect(abs(magnitude + 3.01) < 0.1)
    }

    @Test("low pass is down 3 dB at the cutoff frequency")
    func lowPassCutoff() {
        let coefficients = BiquadCoefficients(
            kind: .lowPass, frequency: 1_000, q: 0.707, gainDecibels: 0, sampleRate: sampleRate
        )

        let magnitude = coefficients.magnitudeDecibels(atFrequency: 1_000, sampleRate: sampleRate)
        #expect(abs(magnitude + 3.01) < 0.1)
    }

    @Test("identity coefficients pass the signal untouched")
    func identity() {
        let coefficients = BiquadCoefficients.identity

        #expect(coefficients.b0 == 1)
        #expect(coefficients.b1 == 0)
        #expect(coefficients.b2 == 0)
        #expect(coefficients.a1 == 0)
        #expect(coefficients.a2 == 0)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter BiquadCoefficientsTests`
Expected: FAIL, compiler error `cannot find 'BiquadCoefficients' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SonoraDSP/BiquadCoefficients.swift`:

```swift
import Foundation

/// The filter shapes the equalizer can produce.
public enum FilterKind: String, Codable, Sendable, CaseIterable {
    /// Bell shape. The default for every graphic equalizer band.
    case peaking
    /// Lifts or cuts everything below the corner frequency.
    case lowShelf
    /// Lifts or cuts everything above the corner frequency.
    case highShelf
    /// Removes content below the cutoff frequency.
    case highPass
    /// Removes content above the cutoff frequency.
    case lowPass
}

/// Normalized second order filter coefficients, in direct form.
///
/// Coefficients follow the Audio EQ Cookbook by Robert Bristow-Johnson and are
/// divided through by `a0`, so the difference equation is:
///
///     y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]
public struct BiquadCoefficients: Equatable, Sendable {

    public let b0: Float
    public let b1: Float
    public let b2: Float
    public let a1: Float
    public let a2: Float

    /// Coefficients that pass the signal through unchanged.
    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    public init(
        kind: FilterKind,
        frequency: Double,
        q: Double,
        gainDecibels: Double,
        sampleRate: Double
    ) {
        // Guard against a frequency at or above Nyquist, which produces NaN.
        let nyquist = sampleRate / 2
        let f0 = min(max(frequency, 1), nyquist - 1)
        let safeQ = max(q, 0.0001)

        let a = pow(10, gainDecibels / 40)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * safeQ)

        let b0: Double
        let b1: Double
        let b2: Double
        let a0: Double
        let a1: Double
        let a2: Double

        switch kind {
        case .peaking:
            b0 = 1 + alpha * a
            b1 = -2 * cosW0
            b2 = 1 - alpha * a
            a0 = 1 + alpha / a
            a1 = -2 * cosW0
            a2 = 1 - alpha / a

        case .lowShelf:
            let sqrtA = sqrt(a)
            b0 = a * ((a + 1) - (a - 1) * cosW0 + 2 * sqrtA * alpha)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW0)
            b2 = a * ((a + 1) - (a - 1) * cosW0 - 2 * sqrtA * alpha)
            a0 = (a + 1) + (a - 1) * cosW0 + 2 * sqrtA * alpha
            a1 = -2 * ((a - 1) + (a + 1) * cosW0)
            a2 = (a + 1) + (a - 1) * cosW0 - 2 * sqrtA * alpha

        case .highShelf:
            let sqrtA = sqrt(a)
            b0 = a * ((a + 1) + (a - 1) * cosW0 + 2 * sqrtA * alpha)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
            b2 = a * ((a + 1) + (a - 1) * cosW0 - 2 * sqrtA * alpha)
            a0 = (a + 1) - (a - 1) * cosW0 + 2 * sqrtA * alpha
            a1 = 2 * ((a - 1) - (a + 1) * cosW0)
            a2 = (a + 1) - (a - 1) * cosW0 - 2 * sqrtA * alpha

        case .highPass:
            b0 = (1 + cosW0) / 2
            b1 = -(1 + cosW0)
            b2 = (1 + cosW0) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW0
            a2 = 1 - alpha

        case .lowPass:
            b0 = (1 - cosW0) / 2
            b1 = 1 - cosW0
            b2 = (1 - cosW0) / 2
            a0 = 1 + alpha
            a1 = -2 * cosW0
            a2 = 1 - alpha
        }

        self.b0 = Float(b0 / a0)
        self.b1 = Float(b1 / a0)
        self.b2 = Float(b2 / a0)
        self.a1 = Float(a1 / a0)
        self.a2 = Float(a2 / a0)
    }

    /// The magnitude of the filter's frequency response, in decibels.
    ///
    /// Evaluates the transfer function on the unit circle. Used by tests to check
    /// the coefficients against theory, and by the interface to draw the curve.
    public func magnitudeDecibels(atFrequency frequency: Double, sampleRate: Double) -> Float {
        let w = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w)
        let sinW = sin(w)
        let cos2W = cos(2 * w)
        let sin2W = sin(2 * w)

        let numeratorReal = Double(b0) + Double(b1) * cosW + Double(b2) * cos2W
        let numeratorImaginary = -(Double(b1) * sinW + Double(b2) * sin2W)
        let denominatorReal = 1 + Double(a1) * cosW + Double(a2) * cos2W
        let denominatorImaginary = -(Double(a1) * sinW + Double(a2) * sin2W)

        let numeratorMagnitude = sqrt(
            numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary
        )
        let denominatorMagnitude = sqrt(
            denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary
        )

        guard denominatorMagnitude > 0, numeratorMagnitude > 0 else { return -120 }
        return Float(20 * log10(numeratorMagnitude / denominatorMagnitude))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter BiquadCoefficientsTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/SonoraDSP/BiquadCoefficients.swift Tests/SonoraDSPTests/BiquadCoefficientsTests.swift
git commit -m "feat: add RBJ biquad coefficient math with magnitude response"
```

---

### Task 3: Biquad filter

**Files:**
- Create: `Sources/SonoraDSP/Biquad.swift`
- Test: `Tests/SonoraDSPTests/BiquadTests.swift`

**Interfaces:**
- Consumes: `BiquadCoefficients` from Task 2.
- Produces: `struct Biquad` with `init(coefficients: BiquadCoefficients = .identity)`, `var coefficients: BiquadCoefficients { get set }`, `mutating func process(_ input: Float) -> Float`, `mutating func reset()`. Used by Task 4.

- [ ] **Step 1: Write the failing test**

Create `Tests/SonoraDSPTests/BiquadTests.swift`:

```swift
import Testing
import Foundation
@testable import SonoraDSP

@Suite("Biquad")
struct BiquadTests {

    let sampleRate = 48_000.0

    /// Feeds a sine wave through the filter and measures the steady state
    /// amplitude of the output, in decibels relative to the input.
    private func measuredGainDecibels(
        of coefficients: BiquadCoefficients,
        atFrequency frequency: Double
    ) -> Float {
        var filter = Biquad(coefficients: coefficients)
        let totalSamples = 48_000
        let settleSamples = 24_000
        var peak: Float = 0

        for index in 0..<totalSamples {
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
            let output = filter.process(Float(sin(phase)))
            if index >= settleSamples {
                peak = max(peak, abs(output))
            }
        }

        return 20 * log10(peak)
    }

    @Test("identity coefficients return the input unchanged")
    func identityPassthrough() {
        var filter = Biquad()

        #expect(filter.process(0.25) == 0.25)
        #expect(filter.process(-0.5) == -0.5)
        #expect(filter.process(0) == 0)
    }

    @Test("measured gain matches the analytic response at the centre frequency")
    func measuredMatchesAnalytic() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 1_000, q: 1.41, gainDecibels: 6, sampleRate: sampleRate
        )

        let measured = measuredGainDecibels(of: coefficients, atFrequency: 1_000)
        #expect(abs(measured - 6) < 0.1)
    }

    @Test("measured cut matches the analytic response")
    func measuredCut() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 500, q: 1.41, gainDecibels: -6, sampleRate: sampleRate
        )

        let measured = measuredGainDecibels(of: coefficients, atFrequency: 500)
        #expect(abs(measured + 6) < 0.1)
    }

    @Test("the filter stays stable over a long run")
    func stability() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 60, q: 4, gainDecibels: 12, sampleRate: sampleRate
        )
        var filter = Biquad(coefficients: coefficients)
        var maximum: Float = 0

        for index in 0..<480_000 {
            let phase = 2 * Double.pi * 60 * Double(index) / sampleRate
            let output = filter.process(Float(sin(phase)))
            maximum = max(maximum, abs(output))
            #expect(output.isFinite)
        }

        // A +12 dB peak on a unit sine cannot exceed roughly 4x amplitude.
        #expect(maximum < 5)
    }

    @Test("reset clears both state variables")
    func reset() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 1_000, q: 1, gainDecibels: 12, sampleRate: sampleRate
        )
        var reference = Biquad(coefficients: coefficients)
        var filter = Biquad(coefficients: coefficients)

        for _ in 0..<100 { _ = filter.process(1) }
        filter.reset()

        // With cleared state the first sample only sees the b0 term. The
        // reference filter consumes the same sample so the two stay in step.
        #expect(abs(filter.process(1) - coefficients.b0) < 0.000_01)
        #expect(abs(reference.process(1) - coefficients.b0) < 0.000_01)

        // state2 does not reach the output until the second sample, so a reset
        // that cleared only state1 would still pass the assertion above. Running
        // the reset filter alongside a fresh one catches it: from here on the
        // two must agree sample for sample.
        for _ in 0..<8 {
            #expect(abs(filter.process(1) - reference.process(1)) < 0.000_01)
        }
    }

    @Test("state is flushed instead of decaying into subnormals")
    func denormalFlush() {
        let coefficients = BiquadCoefficients(
            kind: .peaking, frequency: 100, q: 4, gainDecibels: 12, sampleRate: sampleRate
        )
        var filter = Biquad(coefficients: coefficients)

        for _ in 0..<1_000 { _ = filter.process(1) }

        var output: Float = 0
        for _ in 0..<200_000 { output = filter.process(0) }

        // Without flushing, the ringing tail decays through the subnormal range
        // and never reaches exactly zero.
        #expect(output == 0)
    }

    @Test("an impulse produces a decaying finite response")
    func impulseResponse() {
        let coefficients = BiquadCoefficients(
            kind: .lowPass, frequency: 1_000, q: 0.707, gainDecibels: 0, sampleRate: sampleRate
        )
        var filter = Biquad(coefficients: coefficients)

        var response: [Float] = [filter.process(1)]
        for _ in 0..<999 { response.append(filter.process(0)) }

        #expect(response.allSatisfy { $0.isFinite })
        #expect(abs(response[999]) < abs(response[0]))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter BiquadTests`
Expected: FAIL, compiler error `cannot find 'Biquad' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/SonoraDSP/Biquad.swift`:

```swift
/// A second order filter section in transposed direct form II.
///
/// Transposed direct form II is the standard choice for floating point audio:
/// it needs two state variables per channel and has better numerical behaviour
/// than direct form I at low frequencies.
///
/// One instance holds the state for one channel. Stereo needs two.
///
/// Processing allocates nothing and takes no locks, so it is safe to call from
/// the real-time audio thread.
public struct Biquad: Sendable {

    /// The smallest state magnitude the filter keeps. Anything under this is
    /// flushed to zero.
    ///
    /// An IIR filter's state decays exponentially toward zero whenever the input
    /// goes quiet, between tracks or during a fade. Once it reaches subnormal
    /// floats, some CPUs fall back to microcode where a single multiply can cost
    /// hundreds of cycles. That is enough to stall a render callback that is
    /// otherwise allocation free and lock free, so the usual real-time
    /// discipline does not cover it.
    ///
    /// Subnormals start below 1.18e-38. Flushing at 1e-25 stops the decay well
    /// before that, and 1e-25 is roughly -500 dBFS, hundreds of decibels below
    /// the quietest audible sample, so nothing is lost.
    ///
    /// Flushing rather than adding a tiny DC term keeps silence exactly silent:
    /// a zero input into a settled filter still returns exactly zero.
    ///
    /// Both state variables are flushed together or not at all. They are in
    /// quadrature, so on a high Q section they cross any fixed floor at
    /// different samples; zeroing one on its own perturbs the coupled recurrence
    /// and the perturbation sustains itself as a limit cycle that never decays.
    /// A 100 Hz, Q 4, +12 dB section settles into exactly that, oscillating
    /// forever around 2e-23 instead of reaching zero.
    private static let denormalFloor: Float = 1e-25

    /// The filter shape. Assigning new coefficients does not clear the state,
    /// which is what keeps the audio continuous while a slider moves.
    public var coefficients: BiquadCoefficients

    private var state1: Float = 0
    private var state2: Float = 0

    public init(coefficients: BiquadCoefficients = .identity) {
        self.coefficients = coefficients
    }

    /// Filters one sample.
    @inline(__always)
    public mutating func process(_ input: Float) -> Float {
        let output = coefficients.b0 * input + state1
        let next1 = coefficients.b1 * input - coefficients.a1 * output + state2
        let next2 = coefficients.b2 * input - coefficients.a2 * output

        // Non-finite state is flushed first, and for a different reason than
        // denormals. Every comparison with NaN is false, so the floor test
        // below can never catch it, and a NaN in the state feeds itself: from
        // then on every sample comes out NaN however clean the input is. The
        // limiter downstream turns that into silence, so one glitchy sample
        // would mute the channel until the app restarts. Flushing lets the
        // section heal on the very next sample instead.
        //
        // Then the denormal case, both or neither. See the note on
        // `denormalFloor`: flushing one state variable alone leaves the section
        // ringing forever at a level it can never decay past.
        if !next1.isFinite || !next2.isFinite {
            state1 = 0
            state2 = 0
        } else if abs(next1) < Self.denormalFloor, abs(next2) < Self.denormalFloor {
            state1 = 0
            state2 = 0
        } else {
            state1 = next1
            state2 = next2
        }

        return output
    }

    /// Clears the filter memory. Call after a sample rate or format change,
    /// never while audio is flowing, since it produces a discontinuity.
    public mutating func reset() {
        state1 = 0
        state2 = 0
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter BiquadTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/SonoraDSP/Biquad.swift Tests/SonoraDSPTests/BiquadTests.swift
git commit -m "feat: add transposed direct form II biquad filter"
```

---

### Task 4: Equalizer band definition and chain

**Files:**
- Create: `Sources/SonoraDSP/EqualizerBand.swift`
- Create: `Sources/SonoraDSP/EqualizerChain.swift`
- Test: `Tests/SonoraDSPTests/EqualizerChainTests.swift`

**Interfaces:**
- Consumes: `Biquad`, `BiquadCoefficients`, `FilterKind` from Tasks 2 and 3.
- Produces:
  - `struct EqualizerBand: Codable, Equatable, Sendable` with `var kind: FilterKind`, `var frequency: Double`, `var q: Double`, `var gainDecibels: Double`, and `static let graphicDefaults: [EqualizerBand]` (the ten ISO bands at 0 dB).
  - `static let graphicFrequencies: [Double]` on `EqualizerBand`.
  - `final class EqualizerChain` with `static let maximumBandCount = 32`, `init(sampleRate: Double, channelCount: Int)`, `func update(bands: [EqualizerBand])` (interface thread), `func applyCoefficients(_ source: UnsafePointer<BiquadCoefficients>, count: Int)` (real-time thread), `func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int)`, `func reset()`, `func magnitudeDecibels(atFrequency: Double) -> Float`, `var bands: [EqualizerBand] { get }`, and `static func coefficients(for bands: [EqualizerBand], sampleRate: Double) -> [BiquadCoefficients]`.
- Used by Task 5 (`DSPChain`) and Task 13 (parameter bridge).

- [ ] **Step 1: Write the failing test**

Create `Tests/SonoraDSPTests/EqualizerChainTests.swift`:

```swift
import Testing
import Foundation
@testable import SonoraDSP

@Suite("EqualizerChain")
struct EqualizerChainTests {

    let sampleRate = 48_000.0

    /// Runs a stereo sine through the chain and returns the steady state gain
    /// of each channel in decibels.
    private func measuredGainDecibels(
        chain: EqualizerChain,
        frequency: Double
    ) -> (left: Float, right: Float) {
        let frameCount = 48_000
        let settleFrames = 24_000
        var buffer = [Float](repeating: 0, count: frameCount * 2)

        for frame in 0..<frameCount {
            let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
            let sample = Float(sin(phase))
            buffer[frame * 2] = sample
            buffer[frame * 2 + 1] = sample
        }

        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: frameCount)
        }

        var leftPeak: Float = 0
        var rightPeak: Float = 0
        for frame in settleFrames..<frameCount {
            leftPeak = max(leftPeak, abs(buffer[frame * 2]))
            rightPeak = max(rightPeak, abs(buffer[frame * 2 + 1]))
        }

        return (20 * log10(leftPeak), 20 * log10(rightPeak))
    }

    @Test("there are ten graphic bands on ISO centre frequencies")
    func graphicBandLayout() {
        #expect(EqualizerBand.graphicFrequencies == [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000])
        #expect(EqualizerBand.graphicDefaults.count == 10)
        #expect(EqualizerBand.graphicDefaults.allSatisfy { $0.gainDecibels == 0 })
        #expect(EqualizerBand.graphicDefaults.allSatisfy { $0.kind == .peaking })
    }

    @Test("a flat chain leaves the signal untouched")
    func flatIsTransparent() {
        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        chain.update(bands: EqualizerBand.graphicDefaults)

        let gain = measuredGainDecibels(chain: chain, frequency: 1_000)
        #expect(abs(gain.left) < 0.01)
        #expect(abs(gain.right) < 0.01)
    }

    @Test("a boosted band raises its own centre frequency")
    func boostedBand() {
        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        var bands = EqualizerBand.graphicDefaults
        bands[5].gainDecibels = 6  // 1 kHz
        chain.update(bands: bands)

        let gain = measuredGainDecibels(chain: chain, frequency: 1_000)
        #expect(abs(gain.left - 6) < 0.3)
        #expect(abs(gain.right - 6) < 0.3)
    }

    @Test("a boosted band leaves distant frequencies alone")
    func boostIsLocal() {
        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        var bands = EqualizerBand.graphicDefaults
        bands[0].gainDecibels = 12  // 32 Hz
        chain.update(bands: bands)

        let gain = measuredGainDecibels(chain: chain, frequency: 4_000)
        #expect(abs(gain.left) < 0.5)
    }

    @Test("both channels are filtered independently but identically")
    func channelsMatch() {
        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        var bands = EqualizerBand.graphicDefaults
        bands[7].gainDecibels = -9  // 4 kHz
        chain.update(bands: bands)

        let gain = measuredGainDecibels(chain: chain, frequency: 4_000)
        #expect(abs(gain.left - gain.right) < 0.001)
        #expect(abs(gain.left + 9) < 0.5)
    }

    @Test("the analytic curve agrees with the measured response")
    func curveMatchesMeasurement() {
        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        var bands = EqualizerBand.graphicDefaults
        bands[3].gainDecibels = 8  // 250 Hz
        chain.update(bands: bands)

        let predicted = chain.magnitudeDecibels(atFrequency: 250)
        let measured = measuredGainDecibels(chain: chain, frequency: 250).left
        #expect(abs(predicted - measured) < 0.3)
    }

    @Test("precomputed coefficients produce the same response as update")
    func applyCoefficientsMatchesUpdate() {
        var bands = EqualizerBand.graphicDefaults
        bands[6].gainDecibels = -7  // 2 kHz

        let viaUpdate = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        viaUpdate.update(bands: bands)

        let viaCoefficients = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        let computed = EqualizerChain.coefficients(for: bands, sampleRate: sampleRate)
        computed.withUnsafeBufferPointer { pointer in
            viaCoefficients.applyCoefficients(pointer.baseAddress!, count: computed.count)
        }

        let expected = measuredGainDecibels(chain: viaUpdate, frequency: 2_000).left
        let actual = measuredGainDecibels(chain: viaCoefficients, frequency: 2_000).left
        #expect(abs(actual - expected) < 0.001)
        #expect(abs(actual + 7) < 0.5)
    }

    @Test("applyCoefficients clamps to the maximum band count")
    func applyCoefficientsClamps() {
        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        let tooMany = [BiquadCoefficients](
            repeating: .identity, count: EqualizerChain.maximumBandCount + 8
        )

        tooMany.withUnsafeBufferPointer { pointer in
            chain.applyCoefficients(pointer.baseAddress!, count: tooMany.count)
        }

        // What this proves: an oversized source is accepted, the clamp keeps
        // the loop inside the allocation, and the chain stays transparent.
        //
        // What it cannot prove: that the clamp lands on exactly
        // maximumBandCount. Writes past the boundary land in the next channel's
        // slots and are then overwritten by that channel's own pass, so an
        // off-by-one is self-masking and invisible to any behavioural check.
        // Bounds correctness rests on three other things instead: the
        // arithmetic being derived by hand, `UnsafeMutableBufferPointer`
        // subscripts being bounds checked in debug builds so the whole suite
        // already exercises indexing, and the AddressSanitizer job in CI.
        var buffer = [Float](repeating: 0.3, count: 256)
        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 128)
        }
        #expect(buffer.allSatisfy { abs($0 - 0.3) < 0.000_01 })
    }

    @Test("update beyond the maximum band count keeps only what fits")
    func updateClamps() {
        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        let tooMany = (0..<(EqualizerChain.maximumBandCount + 5)).map { index in
            EqualizerBand(frequency: 100 + Double(index) * 100, gainDecibels: 0)
        }

        chain.update(bands: tooMany)

        #expect(chain.bands.count == EqualizerChain.maximumBandCount)
    }

    @Test("processing never produces a non-finite sample")
    func staysFinite() {
        let chain = EqualizerChain(sampleRate: sampleRate, channelCount: 2)
        var bands = EqualizerBand.graphicDefaults
        for index in bands.indices { bands[index].gainDecibels = 12 }
        chain.update(bands: bands)

        var buffer = [Float](repeating: 0, count: 2_048)
        for index in buffer.indices { buffer[index] = Float.random(in: -1...1) }

        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 1_024)
        }

        #expect(buffer.allSatisfy { $0.isFinite })
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter EqualizerChainTests`
Expected: FAIL, compiler error `cannot find 'EqualizerBand' in scope`.

- [ ] **Step 3: Write the band definition**

Create `Sources/SonoraDSP/EqualizerBand.swift`:

```swift
/// One band of the equalizer.
///
/// The graphic equalizer is a fixed set of these. The parametric mode in a later
/// phase is the same set with every field editable, which is why there is only
/// one band type.
public struct EqualizerBand: Codable, Equatable, Sendable {

    public var kind: FilterKind
    public var frequency: Double
    public var q: Double
    public var gainDecibels: Double

    public init(kind: FilterKind = .peaking, frequency: Double, q: Double = 1.41, gainDecibels: Double = 0) {
        self.kind = kind
        self.frequency = frequency
        self.q = q
        self.gainDecibels = gainDecibels
    }

    /// ISO standard centre frequencies for a ten band graphic equalizer.
    public static let graphicFrequencies: [Double] = [
        32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000
    ]

    /// The default graphic layout: ten flat peaking bands.
    public static let graphicDefaults: [EqualizerBand] = graphicFrequencies.map {
        EqualizerBand(kind: .peaking, frequency: $0, q: 1.41, gainDecibels: 0)
    }

    /// The gain range the interface offers, in decibels.
    public static let gainRange: ClosedRange<Double> = -12...12
}
```

- [ ] **Step 4: Write the chain**

Create `Sources/SonoraDSP/EqualizerChain.swift`:

```swift
/// A cascade of biquad sections applied to an interleaved audio buffer.
///
/// Filter state lives in one flat buffer allocated once at construction and
/// sized for the maximum band count. Nothing on the audio path touches Swift
/// `Array` storage, so `process` and `applyCoefficients` allocate nothing, take
/// no locks, and do no reference counting.
///
/// The thread split is deliberate. Coefficients are expensive to compute and are
/// produced on the interface thread, either through `update(bands:)` or through
/// the static `coefficients(for:sampleRate:)` helper. The audio thread only ever
/// calls `applyCoefficients`, which copies finished floats.
///
/// ## Threading contract
///
/// This is a contract, not a suggestion. The chain has no internal
/// synchronisation, and `@unchecked Sendable` asserts that callers honour the
/// split below rather than providing any safety itself.
///
/// - `update(bands:)` is the setup path. Call it before the render callback
///   starts, or while it is stopped. Never while audio is flowing.
/// - `applyCoefficients` is the live path. Call it only from the render callback
///   itself, with coefficients already resolved elsewhere. In Sonora the
///   parameter bridge does that resolving on the interface thread and hands the
///   finished floats across.
///
/// Calling `update(bands:)` while the render callback runs is a data race. A
/// five float coefficient set has no atomic store, so the audio thread can read
/// a torn mix of old and new values and land on an unstable pole pair, which is
/// audible as a burst of noise rather than the click the split exists to avoid.
public final class EqualizerChain: @unchecked Sendable {

    /// Upper bound on bands, so storage is allocated once. The graphic
    /// equalizer uses ten; the parametric mode in a later phase stays under this.
    public static let maximumBandCount = 32

    public private(set) var bands: [EqualizerBand]

    private let sampleRate: Double
    private let channelCount: Int

    /// `channelCount * maximumBandCount` filters, laid out channel-major.
    private let filters: UnsafeMutableBufferPointer<Biquad>

    /// How many of the per-channel slots are in use.
    private var bandCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        let channels = max(channelCount, 1)
        self.sampleRate = sampleRate
        self.channelCount = channels
        // Left empty on purpose: `update` below is the single source of truth
        // for both, and setting them here would only make the coefficient work
        // it does look like it had already happened.
        self.bands = []
        self.bandCount = 0

        let storage = UnsafeMutableBufferPointer<Biquad>.allocate(
            capacity: channels * Self.maximumBandCount
        )
        storage.initialize(repeating: Biquad())
        self.filters = storage

        update(bands: EqualizerBand.graphicDefaults)
    }

    deinit {
        filters.deinitialize()
        filters.deallocate()
    }

    /// Replaces the band definitions and recomputes coefficients.
    ///
    /// Setup path only. See the threading contract on the type: call this before
    /// the render callback starts, or while it is stopped, never while audio is
    /// flowing. Live changes go through `applyCoefficients` instead.
    ///
    /// Filter state is left alone, which is what lets the chain be reconfigured
    /// and restarted without a discontinuity.
    public func update(bands newBands: [EqualizerBand]) {
        let clamped = Array(newBands.prefix(Self.maximumBandCount))
        bands = clamped
        bandCount = clamped.count

        // Every channel gets the same coefficients, so the trigonometry runs
        // once per band rather than once per band per channel.
        for index in 0..<clamped.count {
            let band = clamped[index]
            let computed = BiquadCoefficients(
                kind: band.kind,
                frequency: band.frequency,
                q: band.q,
                gainDecibels: band.gainDecibels,
                sampleRate: sampleRate
            )
            for channel in 0..<channelCount {
                filters[channel * Self.maximumBandCount + index].coefficients = computed
            }
        }
    }

    /// Installs precomputed coefficients.
    ///
    /// Real-time safe: reads a caller-owned buffer and copies plain floats.
    /// No allocation, no locks, no coefficient math. `bands` is deliberately not
    /// updated, because it is interface-side bookkeeping.
    public func applyCoefficients(_ source: UnsafePointer<BiquadCoefficients>, count: Int) {
        // A negative count would make `0..<usable` trap, and trapping on the
        // audio thread kills the render callback outright.
        //
        // Every channel below shares this one bound, which is also what makes a
        // wrong bound detectable: the last channel's pass would run off the end
        // of the whole allocation and trip the debug bounds check. Give each
        // channel its own bound and that safety net disappears.
        let usable = min(max(count, 0), Self.maximumBandCount)
        bandCount = usable

        for channel in 0..<channelCount {
            let base = channel * Self.maximumBandCount
            for index in 0..<usable {
                filters[base + index].coefficients = source[index]
            }
        }
    }

    /// Filters an interleaved buffer in place. Real-time safe.
    ///
    /// - Parameters:
    ///   - buffer: interleaved samples, `frameCount * channelCount` of them.
    ///   - frameCount: number of frames, not samples.
    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard bandCount > 0, frameCount > 0 else { return }

        for channel in 0..<channelCount {
            let base = channel * Self.maximumBandCount
            for frame in 0..<frameCount {
                let offset = frame * channelCount + channel
                var sample = buffer[offset]
                for index in 0..<bandCount {
                    sample = filters[base + index].process(sample)
                }
                buffer[offset] = sample
            }
        }
    }

    /// Clears every filter's memory. Call after a format change.
    public func reset() {
        for index in 0..<(channelCount * Self.maximumBandCount) {
            filters[index].reset()
        }
    }

    /// The combined response of the active bands at one frequency, in decibels.
    /// Used to draw the equalizer curve.
    ///
    /// Reads channel zero's slots, which start at offset zero, because every
    /// channel always holds identical coefficients. If per-channel bands are
    /// ever added, this has to take a channel argument.
    public func magnitudeDecibels(atFrequency frequency: Double) -> Float {
        var total: Float = 0
        for index in 0..<bandCount {
            total += filters[index].coefficients.magnitudeDecibels(
                atFrequency: frequency, sampleRate: sampleRate
            )
        }
        return total
    }

    /// Computes coefficients for a band list without touching a chain.
    /// This is how the parameter bridge does its work on the interface thread.
    public static func coefficients(
        for bands: [EqualizerBand],
        sampleRate: Double
    ) -> [BiquadCoefficients] {
        bands.prefix(maximumBandCount).map { band in
            BiquadCoefficients(
                kind: band.kind,
                frequency: band.frequency,
                q: band.q,
                gainDecibels: band.gainDecibels,
                sampleRate: sampleRate
            )
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter EqualizerChainTests`
Expected: PASS, 10 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/SonoraDSP/EqualizerBand.swift Sources/SonoraDSP/EqualizerChain.swift Tests/SonoraDSPTests/EqualizerChainTests.swift
git commit -m "feat: add ten band equalizer chain over interleaved buffers"
```

---

### Task 5: Soft limiter and the full DSP chain

**Files:**
- Create: `Sources/SonoraDSP/SoftLimiter.swift`
- Create: `Sources/SonoraDSP/DSPChain.swift`
- Test: `Tests/SonoraDSPTests/SoftLimiterTests.swift`
- Test: `Tests/SonoraDSPTests/DSPChainTests.swift`

**Interfaces:**
- Consumes: `SmoothedValue`, `EqualizerBand`, `EqualizerChain`.
- Produces:
  - `struct SoftLimiter` with `static let ceiling: Float` (0.966, which is -0.3 dBFS), `static let threshold: Float` (0.5), `func process(_ input: Float) -> Float`, `private(set) var isEngaged: Bool`, `mutating func clearEngagedFlag()`.
  - `final class DSPChain` with `init(sampleRate: Double, channelCount: Int)`, `var preampDecibels: Double { get set }` (computed over the ramp target), `var isBypassed: Bool { get set }`, `func update(bands: [EqualizerBand])` (interface thread), `func applyResolved(isBypassed: Bool, preampGain: Float, coefficients: UnsafePointer<BiquadCoefficients>, count: Int)` (real-time thread), `func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int)`, `func reset()`, `var limiterIsEngaged: Bool { get }`, `func magnitudeDecibels(atFrequency: Double) -> Float`.
- Used by Task 13 (render loop).

- [ ] **Step 1: Write the failing limiter test**

Create `Tests/SonoraDSPTests/SoftLimiterTests.swift`:

```swift
import Testing
import Foundation
@testable import SonoraDSP

@Suite("SoftLimiter")
struct SoftLimiterTests {

    @Test("quiet signals pass through untouched")
    func belowThresholdIsTransparent() {
        var limiter = SoftLimiter()

        #expect(limiter.process(0.25) == 0.25)
        #expect(limiter.process(-0.4) == -0.4)
        #expect(limiter.isEngaged == false)
    }

    @Test("the output never exceeds the ceiling, however loud the input")
    func neverExceedsCeiling() {
        var limiter = SoftLimiter()

        // tanh saturates to exactly 1 in Float for large inputs, so the output
        // reaches the ceiling but never passes it.
        for input in [1.0, 2.0, 10.0, 100.0, 1_000.0] as [Float] {
            #expect(limiter.process(input) <= SoftLimiter.ceiling)
            #expect(limiter.process(-input) >= -SoftLimiter.ceiling)
        }
    }

    @Test("the curve is continuous at the threshold")
    func continuousAtThreshold() {
        var limiter = SoftLimiter()

        let below = limiter.process(SoftLimiter.threshold - 0.000_1)
        let above = limiter.process(SoftLimiter.threshold + 0.000_1)
        #expect(abs(above - below) < 0.001)
    }

    @Test("the curve is monotonic, louder input gives louder output")
    func monotonic() {
        var limiter = SoftLimiter()
        var previous: Float = 0

        for step in 0...200 {
            let input = Float(step) * 0.02
            let output = limiter.process(input)
            #expect(output >= previous)
            previous = output
        }
    }

    @Test("the engaged flag reports that limiting happened")
    func engagedFlag() {
        var limiter = SoftLimiter()

        _ = limiter.process(0.1)
        #expect(limiter.isEngaged == false)

        _ = limiter.process(0.9)
        #expect(limiter.isEngaged == true)

        limiter.clearEngagedFlag()
        #expect(limiter.isEngaged == false)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter SoftLimiterTests`
Expected: FAIL, compiler error `cannot find 'SoftLimiter' in scope`.

- [ ] **Step 3: Write the limiter**

Create `Sources/SonoraDSP/SoftLimiter.swift`:

```swift
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
        // This is the last stage before the samples reach the device, so a NaN
        // arriving from a broken stage upstream would go straight out. Infinity
        // needs no special case: the shaping below saturates it to the ceiling.
        guard !input.isNaN else {
            isEngaged = true
            return 0
        }

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
```

- [ ] **Step 4: Run the limiter tests**

Run: `swift test --filter SoftLimiterTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Write the failing chain test**

Create `Tests/SonoraDSPTests/DSPChainTests.swift`:

```swift
import Testing
import Foundation
@testable import SonoraDSP

@Suite("DSPChain")
struct DSPChainTests {

    let sampleRate = 48_000.0

    private func sineBuffer(frequency: Double, frameCount: Int, amplitude: Float = 0.1) -> [Float] {
        var buffer = [Float](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
            let sample = amplitude * Float(sin(phase))
            buffer[frame * 2] = sample
            buffer[frame * 2 + 1] = sample
        }
        return buffer
    }

    private func peak(of buffer: [Float], fromFrame startFrame: Int) -> Float {
        var peak: Float = 0
        for index in (startFrame * 2)..<buffer.count {
            peak = max(peak, abs(buffer[index]))
        }
        return peak
    }

    @Test("a flat chain at unity preamp is transparent")
    func transparentWhenFlat() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 2)
        var buffer = sineBuffer(frequency: 1_000, frameCount: 48_000)
        let inputPeak = peak(of: buffer, fromFrame: 24_000)

        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 48_000)
        }

        #expect(abs(peak(of: buffer, fromFrame: 24_000) - inputPeak) < 0.001)
    }

    @Test("preamp applies its gain in decibels")
    func preampGain() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 2)
        chain.preampDecibels = 6
        var buffer = sineBuffer(frequency: 1_000, frameCount: 48_000, amplitude: 0.1)

        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 48_000)
        }

        let measured = 20 * log10(peak(of: buffer, fromFrame: 24_000) / 0.1)
        #expect(abs(measured - 6) < 0.1)
    }

    @Test("bypass returns the input untouched even with extreme settings")
    func bypass() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 2)
        chain.preampDecibels = 12
        var bands = EqualizerBand.graphicDefaults
        for index in bands.indices { bands[index].gainDecibels = 12 }
        chain.update(bands: bands)
        chain.isBypassed = true

        var buffer = sineBuffer(frequency: 1_000, frameCount: 1_024)
        let original = buffer

        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 1_024)
        }

        #expect(buffer == original)
    }

    @Test("the output never exceeds the limiter ceiling")
    func neverClips() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 2)
        chain.preampDecibels = 12
        var bands = EqualizerBand.graphicDefaults
        for index in bands.indices { bands[index].gainDecibels = 12 }
        chain.update(bands: bands)

        var buffer = sineBuffer(frequency: 1_000, frameCount: 48_000, amplitude: 1.0)
        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 48_000)
        }

        #expect(buffer.allSatisfy { abs($0) <= SoftLimiter.ceiling })
        #expect(chain.limiterIsEngaged == true)
    }

    @Test("a preamp change ramps instead of jumping")
    func preampRamps() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 2)
        var buffer = [Float](repeating: 0.1, count: 64 * 2)
        chain.preampDecibels = 12

        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 64)
        }

        // 64 frames is far shorter than the 30 ms ramp, so the gain has barely moved.
        #expect(buffer[0] < 0.11)
        #expect(buffer[126] > buffer[0])
    }

    @Test("applyResolved installs bypass, preamp and coefficients together")
    func applyResolved() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 2)

        var bands = EqualizerBand.graphicDefaults
        bands[4].gainDecibels = 4  // 500 Hz
        let computed = EqualizerChain.coefficients(for: bands, sampleRate: sampleRate)

        computed.withUnsafeBufferPointer { pointer in
            chain.applyResolved(
                isBypassed: false,
                preampGain: 0.5,
                coefficients: pointer.baseAddress!,
                count: computed.count
            )
        }

        #expect(chain.isBypassed == false)
        #expect(abs(chain.preampDecibels - (-6.020_6)) < 0.01)
        #expect(abs(chain.magnitudeDecibels(atFrequency: 500) - 4) < 0.3)
    }

    @Test("preampDecibels round trips through the ramp target")
    func preampDecibelsRoundTrip() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 2)

        for value in [-12.0, -3.0, 0.0, 6.0, 12.0] {
            chain.preampDecibels = value
            #expect(abs(chain.preampDecibels - value) < 0.001)
        }
    }

    @Test("processing a mono buffer works")
    func monoChannelCount() {
        let chain = DSPChain(sampleRate: sampleRate, channelCount: 1)
        var buffer = [Float](repeating: 0.2, count: 512)

        buffer.withUnsafeMutableBufferPointer { pointer in
            chain.process(pointer.baseAddress!, frameCount: 512)
        }

        #expect(buffer.allSatisfy { $0.isFinite })
    }
}
```

- [ ] **Step 6: Run it to verify it fails**

Run: `swift test --filter DSPChainTests`
Expected: FAIL, compiler error `cannot find 'DSPChain' in scope`.

- [ ] **Step 7: Write the chain**

Create `Sources/SonoraDSP/DSPChain.swift`:

```swift
import Atomics
import Foundation

/// The complete signal path: preamp, equalizer, limiter.
///
/// One instance is owned by the render loop and processes every buffer that
/// comes out of the process tap. `process` allocates nothing and takes no locks.
///
/// Not thread safe. The engine calls the setters from the interface thread only
/// through the parameter bridge, which guarantees they never run concurrently
/// with `process`.
public final class DSPChain: @unchecked Sendable {

    /// Digital gain applied before the equalizer, in decibels. This is Sonora's
    /// own gain and is independent of the system output volume.
    ///
    /// Backed by the ramp's target rather than a separate stored property, so
    /// that a real-time `applyResolved` and an interface-side assignment can
    /// never disagree about the current value.
    ///
    /// The getter floors the linear gain at 1e-6 because `log10(0)` is negative
    /// infinity. A true mute therefore reads back as -120 dB rather than as a
    /// value no interface can render.
    public var preampDecibels: Double {
        get { 20 * log10(Double(max(preampRamp.target, 1e-6))) }
        set { preampRamp.target = Float(pow(10, newValue / 20)) }
    }

    /// When true, `process` returns the buffer untouched.
    public var isBypassed = false

    private let equalizer: EqualizerChain
    private let channelCount: Int
    private var preampRamp: SmoothedValue
    private var limiters: [SoftLimiter]
    private let limiterEngaged = ManagedAtomic<Bool>(false)

    public init(sampleRate: Double, channelCount: Int) {
        self.channelCount = max(channelCount, 1)
        self.equalizer = EqualizerChain(sampleRate: sampleRate, channelCount: channelCount)
        self.preampRamp = SmoothedValue(value: 1, sampleRate: sampleRate)
        self.limiters = Array(repeating: SoftLimiter(), count: max(channelCount, 1))
    }

    /// Replaces the equalizer bands, recomputing coefficients.
    /// Interface thread only.
    public func update(bands: [EqualizerBand]) {
        equalizer.update(bands: bands)
    }

    /// Installs a complete parameter set that was resolved elsewhere.
    ///
    /// Real-time safe: assigns a bool, retargets a ramp, and copies finished
    /// coefficients. No coefficient math, no allocation, no locks.
    public func applyResolved(
        isBypassed: Bool,
        preampGain: Float,
        coefficients: UnsafePointer<BiquadCoefficients>,
        count: Int
    ) {
        self.isBypassed = isBypassed
        preampRamp.target = preampGain
        equalizer.applyCoefficients(coefficients, count: count)
    }

    /// Whether the limiter shaped anything in the most recently processed
    /// buffer.
    ///
    /// The audio thread writes this once per buffer and the interface thread
    /// reads it to light the overload indicator, so it is genuinely cross
    /// thread. A plain `Bool` would be a data race, and a reader could catch a
    /// buffer part way through and see some channels already re-processed while
    /// others still hold the value from the start of the same buffer. One
    /// atomic, written once per buffer, gives a coherent snapshot instead.
    public var limiterIsEngaged: Bool {
        limiterEngaged.load(ordering: .acquiring)
    }

    /// The equalizer curve at one frequency, in decibels. Excludes the preamp.
    public func magnitudeDecibels(atFrequency frequency: Double) -> Float {
        equalizer.magnitudeDecibels(atFrequency: frequency)
    }

    /// Runs the chain over an interleaved buffer in place.
    public func process(_ buffer: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard !isBypassed else {
            // Nothing is being shaped while bypassed, so the indicator must not
            // stay lit from whatever the last processed buffer happened to do.
            limiterEngaged.store(false, ordering: .releasing)
            return
        }

        // Preamp, one ramped gain value per frame shared across channels.
        for frame in 0..<frameCount {
            let gain = preampRamp.nextValue()
            for channel in 0..<channelCount {
                buffer[frame * channelCount + channel] *= gain
            }
        }

        equalizer.process(buffer, frameCount: frameCount)

        // One unsafe buffer pass for the whole limiter stage. Subscripting
        // `limiters` directly would go through Array's uniqueness check on
        // every access, which is exactly the reference counting the audio
        // thread must not do.
        var engaged = false
        limiters.withUnsafeMutableBufferPointer { limiterPointer in
            for index in limiterPointer.indices {
                limiterPointer[index].clearEngagedFlag()
            }

            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    let offset = frame * channelCount + channel
                    buffer[offset] = limiterPointer[channel].process(buffer[offset])
                }
            }

            for index in limiterPointer.indices where limiterPointer[index].isEngaged {
                engaged = true
            }
        }

        limiterEngaged.store(engaged, ordering: .releasing)
    }

    /// Clears filter and ramp state. Call after a format change.
    public func reset() {
        equalizer.reset()
        preampRamp.snap(to: preampRamp.target)
        for index in limiters.indices {
            limiters[index].clearEngagedFlag()
        }
        limiterEngaged.store(false, ordering: .releasing)
    }
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --filter DSPChainTests`
Expected: PASS, 8 tests.

- [ ] **Step 9: Commit**

```bash
git add Sources/SonoraDSP/SoftLimiter.swift Sources/SonoraDSP/DSPChain.swift Tests/SonoraDSPTests/SoftLimiterTests.swift Tests/SonoraDSPTests/DSPChainTests.swift
git commit -m "feat: add soft limiter and complete preamp to limiter DSP chain"
```

---

### Task 6: Presets

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SonoraProfiles/Preset.swift`
- Create: `Sources/SonoraProfiles/BuiltInPresets.swift`
- Test: `Tests/SonoraProfilesTests/PresetTests.swift`

**Interfaces:**
- Consumes: `EqualizerBand` from Task 4.
- Produces: `struct Preset: Codable, Equatable, Identifiable, Sendable` with `let id: String`, `var name: String`, `var preampDecibels: Double`, `var bands: [EqualizerBand]`, `let isBuiltIn: Bool`; `enum BuiltInPresets` with `static let all: [Preset]` and `static let flat: Preset`; `Preset.init(id:name:preampDecibels:gains:)` convenience taking ten gain values. Used by Task 7 (settings) and Task 14 (menu).

- [ ] **Step 1: Declare the target**

`SonoraProfiles` has no target yet, because SwiftPM refuses to resolve a package
with an empty target. Add it now, in the same task that gives it source files.

Modify `Package.swift`, adding to `products`:

```swift
        .library(name: "SonoraProfiles", targets: ["SonoraProfiles"]),
```

and to `targets`:

```swift
        .target(name: "SonoraProfiles", dependencies: ["SonoraDSP"]),
        .testTarget(name: "SonoraProfilesTests", dependencies: ["SonoraProfiles"]),
```

- [ ] **Step 2: Write the failing test**

Create `Tests/SonoraProfilesTests/PresetTests.swift`:

```swift
import Testing
import Foundation
@testable import SonoraProfiles
import SonoraDSP

@Suite("Preset")
struct PresetTests {

    @Test("the flat preset has ten bands, all at zero")
    func flatPreset() {
        let flat = BuiltInPresets.flat

        #expect(flat.bands.count == 10)
        #expect(flat.bands.allSatisfy { $0.gainDecibels == 0 })
        #expect(flat.preampDecibels == 0)
        #expect(flat.isBuiltIn == true)
    }

    @Test("every built-in preset is well formed")
    func builtInsAreWellFormed() {
        #expect(BuiltInPresets.all.count >= 6)

        for preset in BuiltInPresets.all {
            #expect(preset.bands.count == 10)
            #expect(preset.isBuiltIn == true)
            #expect(preset.name.isEmpty == false)
            #expect(preset.bands.allSatisfy { EqualizerBand.gainRange.contains($0.gainDecibels) })
            #expect(EqualizerBand.gainRange.contains(preset.preampDecibels))
        }
    }

    @Test("built-in preset identifiers are unique")
    func uniqueIdentifiers() {
        let identifiers = BuiltInPresets.all.map(\.id)
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test("built-in preset band frequencies follow the graphic layout")
    func builtInFrequencies() {
        for preset in BuiltInPresets.all {
            #expect(preset.bands.map(\.frequency) == EqualizerBand.graphicFrequencies)
        }
    }

    @Test("a preset survives a JSON round trip")
    func codableRoundTrip() throws {
        let original = Preset(
            id: "custom-1",
            name: "My Curve",
            preampDecibels: -2,
            gains: [3, 2, 1, 0, 0, 0, -1, -2, 1, 4],
            isBuiltIn: false
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)

        #expect(decoded == original)
    }

    @Test("the gain convenience initialiser builds graphic bands")
    func gainInitialiser() {
        let preset = Preset(
            id: "test", name: "Test", preampDecibels: 0,
            gains: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], isBuiltIn: false
        )

        #expect(preset.bands.count == 10)
        #expect(preset.bands[0].frequency == 32)
        #expect(preset.bands[0].gainDecibels == 1)
        #expect(preset.bands[9].frequency == 16_000)
        #expect(preset.bands[9].gainDecibels == 10)
        #expect(preset.bands.allSatisfy { $0.kind == .peaking })
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `swift test --filter PresetTests`
Expected: FAIL, compiler error `cannot find 'BuiltInPresets' in scope`.

- [ ] **Step 4: Write the preset model**

Create `Sources/SonoraProfiles/Preset.swift`:

```swift
import SonoraDSP

/// A named equalizer setting: a preamp value plus a full set of bands.
public struct Preset: Codable, Equatable, Identifiable, Sendable {

    public let id: String
    public var name: String
    public var preampDecibels: Double
    public var bands: [EqualizerBand]

    /// Built-in presets ship with the app and cannot be edited or deleted.
    public let isBuiltIn: Bool

    public init(
        id: String,
        name: String,
        preampDecibels: Double,
        bands: [EqualizerBand],
        isBuiltIn: Bool
    ) {
        self.id = id
        self.name = name
        self.preampDecibels = preampDecibels
        self.bands = bands
        self.isBuiltIn = isBuiltIn
    }

    /// Builds a preset from ten gain values laid over the graphic band layout.
    public init(
        id: String,
        name: String,
        preampDecibels: Double,
        gains: [Double],
        isBuiltIn: Bool
    ) {
        precondition(
            gains.count == EqualizerBand.graphicFrequencies.count,
            "A graphic preset needs exactly \(EqualizerBand.graphicFrequencies.count) gain values"
        )

        self.init(
            id: id,
            name: name,
            preampDecibels: preampDecibels,
            bands: zip(EqualizerBand.graphicFrequencies, gains).map { frequency, gain in
                EqualizerBand(kind: .peaking, frequency: frequency, q: 1.41, gainDecibels: gain)
            },
            isBuiltIn: isBuiltIn
        )
    }
}
```

- [ ] **Step 5: Write the built-in presets**

Create `Sources/SonoraProfiles/BuiltInPresets.swift`:

```swift
/// The presets that ship with the app.
///
/// Gains are ordered along the graphic band layout:
/// 32, 64, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz.
///
/// Presets that boost carry a negative preamp so the total does not slam into
/// the limiter on loud material.
public enum BuiltInPresets {

    public static let flat = Preset(
        id: "builtin.flat",
        name: "Flat",
        preampDecibels: 0,
        gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        isBuiltIn: true
    )

    public static let bassBoost = Preset(
        id: "builtin.bass-boost",
        name: "Bass Boost",
        preampDecibels: -3,
        gains: [8, 7, 5, 2, 0, 0, 0, 0, 0, 0],
        isBuiltIn: true
    )

    public static let trebleBoost = Preset(
        id: "builtin.treble-boost",
        name: "Treble Boost",
        preampDecibels: -2,
        gains: [0, 0, 0, 0, 0, 1, 3, 5, 6, 6],
        isBuiltIn: true
    )

    public static let vocal = Preset(
        id: "builtin.vocal",
        name: "Vocal",
        preampDecibels: -1,
        gains: [-3, -2, 0, 2, 4, 4, 3, 1, 0, -1],
        isBuiltIn: true
    )

    public static let loudness = Preset(
        id: "builtin.loudness",
        name: "Loudness",
        preampDecibels: -4,
        gains: [7, 5, 2, 0, -1, -1, 0, 2, 5, 6],
        isBuiltIn: true
    )

    public static let podcast = Preset(
        id: "builtin.podcast",
        name: "Podcast",
        preampDecibels: 0,
        gains: [-6, -4, -1, 2, 3, 3, 2, 1, -1, -3],
        isBuiltIn: true
    )

    /// Compensates for the thin low end of built-in laptop speakers without
    /// asking them for bass they physically cannot produce.
    public static let laptopSpeaker = Preset(
        id: "builtin.laptop-speaker",
        name: "Laptop Speaker",
        preampDecibels: -2,
        gains: [0, 2, 5, 3, -1, -2, 0, 3, 4, 2],
        isBuiltIn: true
    )

    public static let all: [Preset] = [
        flat, bassBoost, trebleBoost, vocal, loudness, podcast, laptopSpeaker
    ]
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter PresetTests`
Expected: PASS, 6 tests.

- [ ] **Step 7: Verify the package resolves from a clean checkout**

Run: `git stash -u && swift build 2>&1 | tail -3; git stash pop`
Expected: the build succeeds against committed files only. If it fails with
"Source files for target X should be located under...", a target is declared
without sources. Never add a placeholder file to silence this.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/SonoraProfiles Tests/SonoraProfilesTests
git commit -m "feat: add preset model and built-in presets"
```

---

### Task 7: Settings and the settings store

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SonoraPersistence/Settings.swift`
- Create: `Sources/SonoraPersistence/SettingsStore.swift`
- Test: `Tests/SonoraPersistenceTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: `Preset`, `BuiltInPresets`, `EqualizerBand`.
- Produces:
  - `struct Settings: Codable, Equatable, Sendable` with `var schemaVersion: Int`, `var isBypassed: Bool`, `var preampDecibels: Double`, `var bands: [EqualizerBand]`, `var activePresetID: String?`, `var userPresets: [Preset]`, `static let currentSchemaVersion = 1`, `static let defaults: Settings`.
  - `final class SettingsStore` with `init(directory: URL)`, `let fileURL: URL`, `func load() -> Settings`, `func save(_ settings: Settings) throws`, `private(set) var lastLoadFailure: LoadFailure?`, `enum LoadFailure: Equatable { case missing, unreadable, corrupt(backupURL: URL), futureVersion(Int) }`, `static func defaultDirectory() -> URL`.
- Used by Task 14.

- [ ] **Step 1: Declare the target**

Modify `Package.swift`, adding to `products`:

```swift
        .library(name: "SonoraPersistence", targets: ["SonoraPersistence"]),
```

and to `targets`:

```swift
        .target(name: "SonoraPersistence", dependencies: ["SonoraProfiles", "SonoraDSP"]),
        .testTarget(name: "SonoraPersistenceTests", dependencies: ["SonoraPersistence"]),
```

- [ ] **Step 2: Write the failing test**

Create `Tests/SonoraPersistenceTests/SettingsStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import SonoraPersistence
import SonoraProfiles
import SonoraDSP

@Suite("SettingsStore")
struct SettingsStoreTests {

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonora-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("defaults are flat, unbypassed, and use the graphic layout")
    func defaults() {
        let settings = Settings.defaults

        #expect(settings.schemaVersion == Settings.currentSchemaVersion)
        #expect(settings.isBypassed == false)
        #expect(settings.preampDecibels == 0)
        #expect(settings.bands == EqualizerBand.graphicDefaults)
        #expect(settings.activePresetID == BuiltInPresets.flat.id)
        #expect(settings.userPresets.isEmpty)
    }

    @Test("loading from an empty directory returns defaults")
    func loadMissingFile() throws {
        let store = SettingsStore(directory: try makeTemporaryDirectory())

        #expect(store.load() == Settings.defaults)
        #expect(store.lastLoadFailure == .missing)
    }

    @Test("settings survive a save and load round trip")
    func roundTrip() throws {
        let store = SettingsStore(directory: try makeTemporaryDirectory())

        var settings = Settings.defaults
        settings.preampDecibels = -3
        settings.isBypassed = true
        settings.bands[2].gainDecibels = 7
        settings.activePresetID = "custom-1"
        settings.userPresets = [
            Preset(
                id: "custom-1", name: "Mine", preampDecibels: -3,
                gains: [1, 1, 1, 0, 0, 0, 0, 0, 0, 0], isBuiltIn: false
            )
        ]

        try store.save(settings)

        #expect(store.load() == settings)
        #expect(store.lastLoadFailure == nil)
    }

    @Test("a corrupt file falls back to defaults and is backed up")
    func corruptFile() throws {
        let directory = try makeTemporaryDirectory()
        let store = SettingsStore(directory: directory)
        try Data("this is not json".utf8).write(to: store.fileURL)

        #expect(store.load() == Settings.defaults)

        guard case .corrupt(let backupURL) = store.lastLoadFailure else {
            Issue.record("expected a corrupt failure, got \(String(describing: store.lastLoadFailure))")
            return
        }
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        #expect(backupURL.pathExtension == "corrupt")
    }

    @Test("a file from a newer schema falls back to defaults")
    func futureVersion() throws {
        let directory = try makeTemporaryDirectory()
        let store = SettingsStore(directory: directory)
        let payload = #"{"schemaVersion": 99, "isBypassed": false, "preampDecibels": 0, "bands": [], "userPresets": []}"#
        try Data(payload.utf8).write(to: store.fileURL)

        #expect(store.load() == Settings.defaults)
        #expect(store.lastLoadFailure == .futureVersion(99))
    }

    @Test("saving creates the directory if it does not exist")
    func createsDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sonora-tests-\(UUID().uuidString)")
        let store = SettingsStore(directory: directory)

        try store.save(Settings.defaults)

        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("the default directory sits under Application Support")
    func defaultDirectory() {
        let path = SettingsStore.defaultDirectory().path

        #expect(path.contains("Application Support"))
        #expect(path.hasSuffix("/Sonora"))
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `swift test --filter SettingsStoreTests`
Expected: FAIL, compiler error `cannot find 'Settings' in scope`.

- [ ] **Step 4: Write the settings model**

Create `Sources/SonoraPersistence/Settings.swift`:

```swift
import SonoraDSP
import SonoraProfiles

/// Everything Sonora remembers between launches.
///
/// The schema is versioned. `SettingsStore` refuses to read a file written by a
/// newer version rather than guessing at fields it does not understand.
public struct Settings: Codable, Equatable, Sendable {

    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var isBypassed: Bool
    public var preampDecibels: Double
    public var bands: [EqualizerBand]
    public var activePresetID: String?
    public var userPresets: [Preset]

    public init(
        schemaVersion: Int = Settings.currentSchemaVersion,
        isBypassed: Bool = false,
        preampDecibels: Double = 0,
        bands: [EqualizerBand] = EqualizerBand.graphicDefaults,
        activePresetID: String? = BuiltInPresets.flat.id,
        userPresets: [Preset] = []
    ) {
        self.schemaVersion = schemaVersion
        self.isBypassed = isBypassed
        self.preampDecibels = preampDecibels
        self.bands = bands
        self.activePresetID = activePresetID
        self.userPresets = userPresets
    }

    public static let defaults = Settings()
}
```

- [ ] **Step 5: Write the store**

Create `Sources/SonoraPersistence/SettingsStore.swift`:

```swift
import Foundation
import SonoraProfiles

/// Reads and writes `Settings` as JSON on disk.
///
/// Loading never throws. A missing, unreadable, corrupt or too-new file returns
/// defaults and records why in `lastLoadFailure`, so the interface can tell the
/// user what happened instead of silently starting over.
public final class SettingsStore {

    public enum LoadFailure: Equatable, Sendable {
        /// No settings file yet. Expected on first launch.
        case missing
        /// The file exists but could not be read from disk.
        case unreadable
        /// The file could not be decoded. `backupURL` is where it was moved,
        /// or nil when it could not be moved at all, in which case the same
        /// file will fail again on the next launch.
        case corrupt(backupURL: URL?)
        /// The file was written by a newer version of Sonora.
        case futureVersion(Int)
        /// The file came from an older schema and no longer decodes. Reported
        /// separately from `corrupt` so an out of date file is never mistaken
        /// for garbage and quarantined.
        case staleVersion(Int)
    }

    public let fileURL: URL
    public private(set) var lastLoadFailure: LoadFailure?

    /// User presets the last load dropped because they claimed to be built in
    /// or reused a built-in identifier.
    ///
    /// Empty after a clean load. Kept separate from `lastLoadFailure` because
    /// the load itself succeeded: something was cleaned up, nothing was lost to
    /// an error. Without this the correction is invisible, and a preset that
    /// some future bug mislabels would simply disappear on the next launch with
    /// nothing to debug from.
    public private(set) var lastDroppedPresets: [Preset] = []

    private let directory: URL
    private let fileManager = FileManager.default

    public init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("settings.json")
    }

    /// `~/Library/Application Support/Sonora`.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Sonora")
    }

    public func load() -> Settings {
        lastDroppedPresets = []

        guard fileManager.fileExists(atPath: fileURL.path) else {
            lastLoadFailure = .missing
            return .defaults
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            lastLoadFailure = .unreadable
            return .defaults
        }

        // Read the version before the full decode, so a version problem is
        // never reported as corruption.
        let storedVersion = (try? JSONDecoder().decode(SchemaEnvelope.self, from: data))?
            .schemaVersion

        if let storedVersion, storedVersion > Settings.currentSchemaVersion {
            lastLoadFailure = .futureVersion(storedVersion)
            return .defaults
        }

        do {
            let settings = try JSONDecoder().decode(Settings.self, from: data)
            lastLoadFailure = nil
            return reconciled(settings)
        } catch {
            if let storedVersion, storedVersion < Settings.currentSchemaVersion {
                lastLoadFailure = .staleVersion(storedVersion)
                return .defaults
            }
            lastLoadFailure = .corrupt(backupURL: backUpCorruptFile())
            return .defaults
        }
    }

    /// Strips claims a settings file is not allowed to make.
    ///
    /// `Preset` is `Codable`, so a hand edited or corrupted file can present a
    /// user preset that claims to be built in, or one that reuses a built-in
    /// identifier. The interface refuses to edit or delete built-in presets, so
    /// such an entry becomes a ghost the user cannot remove, and a duplicated
    /// identifier makes every lookup ambiguous. This is the disk boundary, so
    /// this is where those claims are dropped.
    private func reconciled(_ settings: Settings) -> Settings {
        let builtInIdentifiers = Set(BuiltInPresets.all.map(\.id))
        var result = settings
        result.userPresets = settings.userPresets.filter {
            !$0.isBuiltIn && !builtInIdentifiers.contains($0.id)
        }
        lastDroppedPresets = settings.userPresets.filter { candidate in
            !result.userPresets.contains { $0.id == candidate.id }
        }
        return result
    }

    public func save(_ settings: Settings) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        var stored = settings
        stored.schemaVersion = Settings.currentSchemaVersion

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stored).write(to: fileURL, options: .atomic)
    }

    /// Moves the undecodable file aside so the next launch starts clean while
    /// the user keeps whatever was in it.
    ///
    /// Returns nil when the move fails, for example on a read-only volume or a
    /// full disk. Reporting that honestly matters: the alternative is naming a
    /// backup file that was never written, while the original stays in place
    /// and fails again on every launch with nothing to show for it.
    private func backUpCorruptFile() -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = directory.appendingPathComponent("settings-\(stamp).json.corrupt")

        do {
            try fileManager.moveItem(at: fileURL, to: backupURL)
            return backupURL
        } catch {
            return nil
        }
    }

    private struct SchemaEnvelope: Decodable {
        let schemaVersion: Int
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter SettingsStoreTests`
Expected: PASS, 7 tests.

- [ ] **Step 7: Run the whole suite**

Run: `swift test`
Expected: PASS, all suites, roughly 55 tests.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/SonoraPersistence Tests/SonoraPersistenceTests
git commit -m "feat: add versioned settings store with corrupt file recovery"
```

---

### Task 8: Continuous integration

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: the package from Tasks 1 to 7.
- Produces: a CI workflow that runs `swift test` on every push and pull request.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  test:
    name: Swift package tests
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4

      # Pinned to the version the project is developed against. macos-15 was
      # tried first and carries Swift 6.1, which cannot read this manifest.
      - name: Select Xcode
        run: sudo xcode-select -switch /Applications/Xcode_26.3.app

      - name: Show toolchain
        run: swift --version

      - name: Build
        run: swift build --build-tests

      - name: Test
        run: swift test --parallel

      # EqualizerChain does unchecked pointer arithmetic over a flat filter
      # buffer. An off-by-one there is silent memory corruption in release
      # builds and cannot be caught behaviourally, so the suite also runs under
      # AddressSanitizer.
      - name: Test under AddressSanitizer
        run: swift test --sanitize=address
```

- [ ] **Step 2: Verify the workflow file parses**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); print('valid')"`
Expected: `valid`

- [ ] **Step 3: Commit and push**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: run swift package tests on push and pull request"
git push
```

- [ ] **Step 4: Confirm the run passes**

Run: `gh run watch --exit-status`
Expected: every job finishes green, including the AddressSanitizer one. If the
runner image no longer carries Xcode 26.3, pick the newest 26.x it does offer
(`ls /Applications | grep Xcode`) and push the fix. Never lower
`swift-tools-version` to make the build pass.

---

### Task 9: App target scaffolding and signing

**Files:**
- Create: `App/project.yml`
- Create: `App/Sonora/Info.plist`
- Create: `App/Sonora/Sonora.entitlements`
- Create: `App/Sonora/SonoraApp.swift`
- Create: `App/Sonora/AppDelegate.swift`
- Create: `App/README.md`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: the `SonoraCore` package.
- Produces: a buildable, signed, launchable menu bar app with an `NSStatusItem` that shows a placeholder menu. `AppDelegate` exposes `statusItem: NSStatusItem` for Task 14.

**Prerequisite, needs a human:** Xcode must have a signing identity. There are currently none on this machine (`security find-identity -v -p codesigning` reports `0 valid identities found`). Open Xcode, go to Settings, Accounts, add an Apple ID, then select the personal team. A free Apple ID is enough for development; notarized distribution later needs a paid Apple Developer Program membership. Without an identity the app builds but process taps will never prompt for permission, which blocks Task 11 onward.

- [ ] **Step 1: Install XcodeGen**

Run: `brew install xcodegen && xcodegen --version`
Expected: version 2.46.0 or newer.

- [ ] **Step 2: Write the project definition**

Create `App/project.yml`:

```yaml
name: Sonora
options:
  bundleIdPrefix: com.sonora
  deploymentTarget:
    macOS: "14.4"
  createIntermediateGroups: true

packages:
  SonoraCore:
    path: ..

targets:
  Sonora:
    type: application
    platform: macOS
    sources:
      - path: Sonora
    dependencies:
      - package: SonoraCore
        product: SonoraDSP
      - package: SonoraCore
        product: SonoraProfiles
      - package: SonoraCore
        product: SonoraPersistence
    info:
      path: Sonora/Info.plist
    entitlements:
      path: Sonora/Sonora.entitlements
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.sonora.Sonora
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        SWIFT_VERSION: "6.0"
        SWIFT_STRICT_CONCURRENCY: complete
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_STYLE: Automatic
        INFOPLIST_FILE: Sonora/Info.plist
        GENERATE_INFOPLIST_FILE: NO
```

- [ ] **Step 3: Write the Info.plist**

Create `App/Sonora/Info.plist`. `NSAudioCaptureUsageDescription` is the key that drives the permission prompt; it does not appear in Xcode's key dropdown. `LSUIElement` makes this a menu bar app with no Dock icon.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Sonora</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.4</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Sonora needs system audio access to apply the equalizer to what your Mac is playing. Audio is processed live and never recorded or sent anywhere.</string>
    <key>NSHumanReadableCopyright</key>
    <string>MIT licensed. Copyright (c) 2026 Deniz Barış Yıldırım.</string>
</dict>
</plist>
```

- [ ] **Step 4: Write the entitlements**

Create `App/Sonora/Sonora.entitlements`. The sandbox stays off: process tap behaviour under the sandbox is unreliable and there is no Mac App Store target.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 5: Write the app entry point**

Create `App/Sonora/SonoraApp.swift`:

```swift
import AppKit

@main
enum SonoraMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
```

- [ ] **Step 6: Write the app delegate**

Create `App/Sonora/AppDelegate.swift`:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "slider.horizontal.3",
            accessibilityDescription: "Sonora"
        )

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Sonora is running",
            action: nil,
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Sonora",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        statusItem.menu = menu
    }
}
```

- [ ] **Step 7: Ignore the generated project**

Append to `.gitignore`:

```
App/Sonora.xcodeproj/
*.xcworkspace/
```

- [ ] **Step 8: Write the build instructions**

Create `App/README.md`:

```markdown
# Sonora app target

The Xcode project is generated, not committed. `project.yml` is the source of truth.

## Build

```bash
brew install xcodegen
cd App
xcodegen generate
xcodebuild -project Sonora.xcodeproj -scheme Sonora -configuration Debug build
```

## Run

Open `Sonora.xcodeproj` in Xcode and press Run. Running from Xcode with a real
team selected is required: process taps need a signed binary, and the permission
prompt never appears for an unsigned build.

## Reset the audio permission

```bash
tccutil reset SystemAudioCaptureRequests com.sonora.Sonora
```
```

- [ ] **Step 9: Generate and build**

Run: `cd App && xcodegen generate && xcodebuild -project Sonora.xcodeproj -scheme Sonora -configuration Debug build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 10: Run it and verify the status item appears**

Open `App/Sonora.xcodeproj` in Xcode, select your team under Signing and Capabilities, press Run.
Expected: a slider icon appears in the menu bar, clicking it shows "Sonora is running" and "Quit Sonora". No Dock icon.

- [ ] **Step 11: Commit**

```bash
git add App .gitignore
git commit -m "feat: add menu bar app target generated by XcodeGen"
```

---

### Task 10: Process tap wrapper

**Files:**
- Create: `App/Sonora/AudioEngine/AudioObjectID+Properties.swift`
- Create: `App/Sonora/AudioEngine/AudioEngineError.swift`
- Create: `App/Sonora/AudioEngine/ProcessTap.swift`
- Modify: `App/Sonora/AppDelegate.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `extension AudioObjectID` with `static func readDefaultOutputDevice() throws -> AudioObjectID`, `func readString(_ selector: AudioObjectPropertySelector) throws -> String`, `func readStreamDescription(_ selector: AudioObjectPropertySelector) throws -> AudioStreamBasicDescription`, `static func processObject(forPID pid: pid_t) throws -> AudioObjectID`.
  - `enum AudioEngineError: LocalizedError` with cases `tapCreationFailed(OSStatus)`, `aggregateCreationFailed(OSStatus)`, `propertyReadFailed(AudioObjectPropertySelector, OSStatus)`, `noOutputDevice`, `ioProcCreationFailed(OSStatus)`, `deviceStartFailed(OSStatus)`, `processObjectNotFound(pid_t)`.
  - `final class ProcessTap` with `let uuid: UUID`, `private(set) var objectID: AudioObjectID`, `func activate() throws`, `func invalidate()`, `func streamDescription() throws -> AudioStreamBasicDescription`.
- Used by Tasks 11, 12, 13, 14.

- [ ] **Step 1: Write the property helpers**

Create `App/Sonora/AudioEngine/AudioObjectID+Properties.swift`:

```swift
import CoreAudio
import Foundation

extension AudioObjectID {

    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    /// The device the system is currently playing through.
    static func readDefaultOutputDevice() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID.system, &address, 0, nil, &size, &deviceID
        )
        guard status == noErr else {
            throw AudioEngineError.propertyReadFailed(
                kAudioHardwarePropertyDefaultOutputDevice, status
            )
        }
        guard deviceID.isValid else { throw AudioEngineError.noOutputDevice }
        return deviceID
    }

    /// Reads a `CFString` property, for example a device UID.
    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw AudioEngineError.propertyReadFailed(selector, status)
        }
        return value as String
    }

    /// Reads an `AudioStreamBasicDescription` property.
    func readStreamDescription(
        _ selector: AudioObjectPropertySelector
    ) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let status = AudioObjectGetPropertyData(
            self, &address, 0, nil, &size, &description
        )
        guard status == noErr else {
            throw AudioEngineError.propertyReadFailed(selector, status)
        }
        return description
    }

    /// Reads a `UInt32` property, used for buffer sizes and latencies.
    func readUInt32(_ selector: AudioObjectPropertySelector) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw AudioEngineError.propertyReadFailed(selector, status)
        }
        return value
    }

    /// Translates a process identifier into the Core Audio object that
    /// represents that process. Needed to exclude Sonora's own output from the
    /// global tap, otherwise the engine taps what it just played and feeds back.
    static func processObject(forPID pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var inputPID = pid
        var objectID = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID.system,
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &inputPID,
            &size,
            &objectID
        )
        guard status == noErr, objectID.isValid else {
            throw AudioEngineError.processObjectNotFound(pid)
        }
        return objectID
    }
}
```

- [ ] **Step 2: Write the error type**

Create `App/Sonora/AudioEngine/AudioEngineError.swift`:

```swift
import CoreAudio
import Foundation

enum AudioEngineError: LocalizedError, Equatable {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case propertyReadFailed(AudioObjectPropertySelector, OSStatus)
    case noOutputDevice
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case processObjectNotFound(pid_t)

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status):
            return "Could not create the system audio tap (\(status)). "
                 + "Check that Sonora has System Audio Recording permission."
        case .aggregateCreationFailed(let status):
            return "Could not create the audio device (\(status))."
        case .propertyReadFailed(let selector, let status):
            return "Could not read audio property \(selector.fourCharacterCode) (\(status))."
        case .noOutputDevice:
            return "No audio output device is available."
        case .ioProcCreationFailed(let status):
            return "Could not install the audio render callback (\(status))."
        case .deviceStartFailed(let status):
            return "Could not start the audio device (\(status))."
        case .processObjectNotFound(let pid):
            return "Could not find the audio process object for pid \(pid)."
        }
    }
}

extension AudioObjectPropertySelector {
    /// Core Audio selectors are four character codes. Printing them as text
    /// makes log output readable.
    var fourCharacterCode: String {
        let value = UInt32(self)
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "\(value)"
    }
}
```

- [ ] **Step 3: Write the tap wrapper**

Create `App/Sonora/AudioEngine/ProcessTap.swift`:

```swift
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// A global Core Audio process tap: everything the system plays, except Sonora
/// itself, muted at the source so that only our processed output is heard.
///
/// Three rules from hard experience, do not change them without reading the
/// design document:
///
/// 1. `init(stereoGlobalTapButExcludeProcesses:)` already sets the exclusive
///    flag. Assigning `isExclusive` afterwards flips the meaning from
///    "everything except these" to "only these" and the tap captures silence.
/// 2. Sonora's own process object must be in the exclude list. Without it the
///    tap captures our own output and the signal feeds back on itself.
/// 3. `muteBehavior = .mutedWhenTapped` is what removes the original audio from
///    the output. The mute lives with the tap object, so destroying the tap, or
///    crashing, restores normal audio.
final class ProcessTap {

    let uuid = UUID()
    private(set) var objectID = AudioObjectID.unknown

    private let logger = Logger(subsystem: "com.sonora.Sonora", category: "ProcessTap")

    var isActive: Bool { objectID.isValid }

    /// Creates the tap. Surfaces the system audio permission prompt on first run.
    func activate() throws {
        guard !isActive else { return }

        let ownProcess = try AudioObjectID.processObject(forPID: getpid())

        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: [NSNumber(value: ownProcess)]
        )
        description.uuid = uuid
        description.name = "Sonora System Tap"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var id = AudioObjectID.unknown
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr, id.isValid else {
            throw AudioEngineError.tapCreationFailed(status)
        }

        objectID = id
        logger.info("Process tap active, object id \(id, privacy: .public)")
    }

    /// Destroys the tap and unmutes the system. Safe to call more than once.
    func invalidate() {
        guard isActive else { return }
        AudioHardwareDestroyProcessTap(objectID)
        logger.info("Process tap destroyed")
        objectID = .unknown
    }

    /// The audio format the tap delivers. Read after `activate`.
    func streamDescription() throws -> AudioStreamBasicDescription {
        try objectID.readStreamDescription(kAudioTapPropertyFormat)
    }

    deinit {
        invalidate()
    }
}
```

- [ ] **Step 4: Call it from the app delegate**

Replace the body of `applicationDidFinishLaunching` in `App/Sonora/AppDelegate.swift`:

```swift
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
```

- [ ] **Step 5: Build and run**

Run: `cd App && xcodegen generate && xcodebuild -project Sonora.xcodeproj -scheme Sonora -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

Then run from Xcode.
Expected: a permission dialog appears asking to allow Sonora to record system audio, quoting the `NSAudioCaptureUsageDescription` text. After allowing, the menu reads `Tap active, 48000 Hz, 2 ch`.

**If no dialog appears:** the build is not signed with a real team. Fix that before continuing, the rest of the plan depends on it. Reset with `tccutil reset SystemAudioCaptureRequests com.sonora.Sonora` to test again.

**Expected side effect at this step:** system audio goes silent while the app runs, because the tap mutes it and nothing is playing it back yet. Task 12 restores it. Quitting the app brings audio back.

- [ ] **Step 6: Verify that quitting restores audio**

Start music, run the app, confirm silence, quit the app from the menu, confirm the music is audible again.

- [ ] **Step 7: Commit**

```bash
git add App/Sonora/AudioEngine App/Sonora/AppDelegate.swift
git commit -m "feat: add global process tap with own process excluded"
```

---

### Task 11: Aggregate device

**Files:**
- Create: `App/Sonora/AudioEngine/AggregateDevice.swift`

**Interfaces:**
- Consumes: `ProcessTap`, `AudioObjectID` helpers, `AudioEngineError`.
- Produces: `final class AggregateDevice` with `init(tap: ProcessTap)`, `private(set) var objectID: AudioObjectID`, `private(set) var outputDeviceID: AudioObjectID`, `func create() throws`, `func destroy()`, `func bufferFrameSize() throws -> UInt32`, `func outputLatencyFrames() throws -> UInt32`. Used by Tasks 12, 13, 14.

- [ ] **Step 1: Write the aggregate device**

Create `App/Sonora/AudioEngine/AggregateDevice.swift`:

```swift
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// A private aggregate device that pairs the real output device with the
/// process tap, so that one `IOProc` receives tapped audio as input and writes
/// processed audio to the speakers as output.
///
/// The layout matters and is easy to get wrong. The real output device is the
/// main sub-device. The tap rides along as a sub-tap. Making the tap the main
/// sub-device, or leaving the sub-device list empty, produces an aggregate that
/// reports success and then delivers zero samples forever.
final class AggregateDevice {

    private(set) var objectID = AudioObjectID.unknown
    private(set) var outputDeviceID = AudioObjectID.unknown

    private let tap: ProcessTap
    private let logger = Logger(subsystem: "com.sonora.Sonora", category: "AggregateDevice")

    var isCreated: Bool { objectID.isValid }

    init(tap: ProcessTap) {
        self.tap = tap
    }

    /// Builds the aggregate around whatever the current default output device is.
    func create() throws {
        guard !isCreated else { return }

        let outputDevice = try AudioObjectID.readDefaultOutputDevice()
        let outputUID = try outputDevice.readString(kAudioDevicePropertyDeviceUID)

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sonora Output",
            kAudioAggregateDeviceUIDKey: "com.sonora.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tap.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var id = AudioObjectID.unknown
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id.isValid else {
            throw AudioEngineError.aggregateCreationFailed(status)
        }

        objectID = id
        outputDeviceID = outputDevice
        logger.info("Aggregate device \(id, privacy: .public) built on \(outputUID, privacy: .public)")
    }

    func destroy() {
        guard isCreated else { return }
        AudioHardwareDestroyAggregateDevice(objectID)
        logger.info("Aggregate device destroyed")
        objectID = .unknown
        outputDeviceID = .unknown
    }

    /// How many frames the device asks for per callback. The main contributor to
    /// added latency.
    func bufferFrameSize() throws -> UInt32 {
        try objectID.readUInt32(kAudioDevicePropertyBufferFrameSize)
    }

    /// The output device's own reported latency, in frames.
    func outputLatencyFrames() throws -> UInt32 {
        let latency = (try? outputDeviceID.readUInt32(kAudioDevicePropertyLatency)) ?? 0
        let safetyOffset = (try? outputDeviceID.readUInt32(kAudioDevicePropertySafetyOffset)) ?? 0
        return latency + safetyOffset
    }

    deinit {
        destroy()
    }
}
```

- [ ] **Step 2: Build**

Run: `cd App && xcodegen generate && xcodebuild -project Sonora.xcodeproj -scheme Sonora -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/Sonora/AudioEngine/AggregateDevice.swift
git commit -m "feat: add private aggregate device pairing tap with output"
```

---

### Task 12: Render loop passthrough and the latency gate

**Files:**
- Create: `App/Sonora/AudioEngine/RenderLoop.swift`
- Modify: `App/Sonora/AppDelegate.swift`
- Create: `docs/phase-0-measurements.md`

**Interfaces:**
- Consumes: `ProcessTap`, `AggregateDevice`, `AudioEngineError`.
- Produces: `final class RenderLoop` with `init(aggregate: AggregateDevice)`, `var processBlock: ((UnsafeMutablePointer<Float>, Int, Int) -> Void)?`, `func start() throws`, `func stop()`, `private(set) var isRunning: Bool`. The process block receives an interleaved buffer, a frame count, and a channel count. Used by Tasks 13 and 14.

**This task is the Phase 0 gate.** If the measured latency makes video unwatchable, stop and revisit the architecture before writing any interface code.

- [ ] **Step 1: Write the render loop**

Create `App/Sonora/AudioEngine/RenderLoop.swift`:

```swift
import AudioToolbox
import CoreAudio
import Foundation
import OSLog

/// Installs an `IOProc` on the aggregate device and moves audio from the tap's
/// input buffers to the device's output buffers.
///
/// The `IOProc` block runs on a real-time thread. Inside it there is no
/// allocation, no locking, no logging and no Swift runtime work. `processBlock`
/// is captured once at `start` and must obey the same rules.
final class RenderLoop {

    /// Called for every buffer, on the real-time thread.
    /// Parameters: interleaved samples, frame count, channel count.
    var processBlock: ((UnsafeMutablePointer<Float>, Int, Int) -> Void)?

    private(set) var isRunning = false

    private let aggregate: AggregateDevice
    private var ioProcID: AudioDeviceIOProcID?
    private let logger = Logger(subsystem: "com.sonora.Sonora", category: "RenderLoop")

    init(aggregate: AggregateDevice) {
        self.aggregate = aggregate
    }

    func start() throws {
        guard !isRunning, aggregate.isCreated else { return }

        let block = processBlock

        var procID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregate.objectID,
            nil
        ) { _, inputData, _, outputData, _ in
            let inputBuffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData)
            )
            let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)

            guard let input = inputBuffers.first,
                  let output = outputBuffers.first,
                  let source = input.mData,
                  let destination = output.mData else {
                return
            }

            let byteCount = min(input.mDataByteSize, output.mDataByteSize)
            memcpy(destination, source, Int(byteCount))

            let channelCount = Int(output.mNumberChannels)
            guard channelCount > 0 else { return }
            let frameCount = Int(byteCount) / MemoryLayout<Float>.size / channelCount

            block?(
                destination.assumingMemoryBound(to: Float.self),
                frameCount,
                channelCount
            )
        }

        guard createStatus == noErr, let procID else {
            throw AudioEngineError.ioProcCreationFailed(createStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregate.objectID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregate.objectID, procID)
            ioProcID = nil
            throw AudioEngineError.deviceStartFailed(startStatus)
        }

        isRunning = true
        logger.info("Render loop started")
    }

    func stop() {
        guard let procID, aggregate.isCreated else {
            isRunning = false
            return
        }

        AudioDeviceStop(aggregate.objectID, procID)
        AudioDeviceDestroyIOProcID(aggregate.objectID, procID)
        ioProcID = nil
        isRunning = false
        logger.info("Render loop stopped")
    }

    deinit {
        stop()
    }
}
```

- [ ] **Step 2: Wire passthrough into the app delegate**

Replace `App/Sonora/AppDelegate.swift` with:

```swift
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
```

- [ ] **Step 3: Build and run**

Run: `cd App && xcodegen generate && xcodebuild -project Sonora.xcodeproj -scheme Sonora -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

Then run from Xcode with music playing.
Expected: music keeps playing at normal volume and the menu shows a line like `Passthrough, 48000 Hz, buffer 512, device 424, added ~19.5 ms`.

**If audio is silent:** the aggregate layout is wrong. Check that `kAudioAggregateDeviceMainSubDeviceKey` holds the real device UID and that `kAudioAggregateDeviceSubDeviceListKey` is not empty.

- [ ] **Step 4: Run the Phase 0 verification checklist**

Perform each check and record the result:

1. Music plays through, no dropouts over two minutes.
2. Play a talking-head video on YouTube. Judge lip sync. Acceptable or not.
3. `kill -9` the app while music plays. Audio must return to normal within a second.
4. Unplug and replug headphones. Note what happens; breakage here is expected and is fixed in Task 14.
5. Switch output to a Bluetooth device in Control Center. Note what happens.
6. Open Activity Monitor and record Sonora's CPU use while audio plays.

- [ ] **Step 5: Record the measurements**

Create `docs/phase-0-measurements.md` and fill in the real numbers from the run:

```markdown
# Phase 0 measurements

Machine: <model>, macOS <version>
Output device: <device>
Date: <date>

| Metric | Value |
|---|---|
| Sample rate | |
| Buffer frame size | |
| Device latency + safety offset (frames) | |
| Total added latency (ms) | |
| CPU use while playing (%) | |

## Verification checklist

| Check | Result |
|---|---|
| Two minutes of music, no dropouts | |
| Video lip sync acceptable | |
| `kill -9` restores audio | |
| Headphone unplug behaviour | |
| Bluetooth switch behaviour | |

## Gate decision

<Continue with the tap architecture, or escalate to the DriverKit fallback. State why.>
```

- [ ] **Step 6: Commit**

```bash
git add App/Sonora/AudioEngine/RenderLoop.swift App/Sonora/AppDelegate.swift docs/phase-0-measurements.md
git commit -m "feat: add render loop passthrough and record phase 0 measurements"
git push
```

- [ ] **Step 7: Stop and report**

Report the latency figure and the checklist results before starting Task 13. If lip sync is unacceptable, the tap architecture does not hold and the plan changes.

---

### Task 13: Lock-free parameter bridge

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SonoraDSP/EngineParameters.swift`
- Create: `Sources/SonoraDSP/ParameterBridge.swift`
- Test: `Tests/SonoraDSPTests/EngineParametersTests.swift`
- Test: `Tests/SonoraDSPTests/ParameterBridgeTests.swift`

**Interfaces:**
- Consumes: `EqualizerBand`, `DSPChain`.
- Produces:
  - `struct EngineParameters: Equatable, Sendable` with `var isBypassed: Bool`, `var preampDecibels: Double`, `var bands: [EqualizerBand]`, `static let defaults`.
  - `final class ParameterBridge` with `init(initial: EngineParameters, sampleRate: Double)`, `func publish(_ parameters: EngineParameters)` (interface thread), `func setSampleRate(_ sampleRate: Double)` (interface thread), `func applyPendingChanges(to chain: DSPChain)` (real-time thread, allocation free and lock free), `var current: EngineParameters { get }`.
- Used by Task 14.

**Design note:** the interface thread resolves a parameter set into finished
coefficients and plain floats, writes them into one of three preallocated slots,
then publishes that slot by storing its index with releasing order. The audio
thread loads the index with acquiring order and reads that slot. The writer never
touches the slot it just published, and three slots mean a reader cannot be
lapped by a second publish, because publishes are paced by user gestures while a
read takes well under a microsecond.

The audio side therefore does one atomic load when nothing changed, and a copy of
plain floats when something did. No coefficient math, no allocation, no lock.

- [ ] **Step 1: Confirm swift-atomics is already wired in**

`SonoraDSP` gained this dependency earlier, when `DSPChain` needed an atomic for
its overload indicator. Check `Package.swift` matches the manifest below and
move on; do not add the dependency twice.

Expected `Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SonoraCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SonoraDSP", targets: ["SonoraDSP"]),
        .library(name: "SonoraProfiles", targets: ["SonoraProfiles"]),
        .library(name: "SonoraPersistence", targets: ["SonoraPersistence"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.3.1"),
    ],
    targets: [
        .target(
            name: "SonoraDSP",
            dependencies: [.product(name: "Atomics", package: "swift-atomics")]
        ),
        .target(name: "SonoraProfiles", dependencies: ["SonoraDSP"]),
        .target(name: "SonoraPersistence", dependencies: ["SonoraProfiles"]),
        .testTarget(name: "SonoraDSPTests", dependencies: ["SonoraDSP"]),
        .testTarget(name: "SonoraProfilesTests", dependencies: ["SonoraProfiles"]),
        .testTarget(name: "SonoraPersistenceTests", dependencies: ["SonoraPersistence"]),
    ]
)
```

- [ ] **Step 2: Write the failing test**

Create `Tests/SonoraDSPTests/EngineParametersTests.swift`:

```swift
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
```

- [ ] **Step 3: Run it to verify it fails**

Run: `swift test --filter EngineParametersTests`
Expected: FAIL, compiler error `cannot find 'EngineParameters' in scope`.

- [ ] **Step 4: Write the parameter type**

Create `Sources/SonoraDSP/EngineParameters.swift`:

```swift
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter EngineParametersTests`
Expected: PASS, 3 tests.

- [ ] **Step 6: Write the bridge**

The bridge lives in `SonoraDSP`, not in the app target. It has no Core Audio
dependency, which keeps the app free of a direct atomics dependency and makes
the handoff logic unit testable.

Create `Sources/SonoraDSP/ParameterBridge.swift`:

```swift
import Atomics
import Foundation

/// Carries parameter changes from the interface thread to the real-time audio
/// thread with no lock and no allocation on the audio side.
///
/// The expensive part of a parameter change is turning bands into biquad
/// coefficients. That happens here, on the interface thread. What crosses to the
/// audio thread is a bool, a float, and a block of finished coefficients.
///
/// Handoff: three preallocated slots. `publish` fills a slot the audio thread is
/// not reading, then stores that slot's index with releasing order.
/// `applyPendingChanges` loads the index with acquiring order and reads that
/// slot. Because the writer never touches the slot it last published, and
/// publishes are paced by user gestures while a read takes well under a
/// microsecond, a reader cannot be lapped.
///
/// The lock in this class is taken by the interface thread only, to guard the
/// writer against itself. The audio path never touches it.
public final class ParameterBridge: @unchecked Sendable {

    /// Three slots, so the writer always has one that is neither being read nor
    /// the one it published last.
    private static let slotCount = 3

    /// The plain-data half of a resolved parameter set. Coefficients live in a
    /// parallel buffer, indexed by slot.
    private struct Slot {
        var isBypassed = false
        var preampGain: Float = 1
        var bandCount = 0
    }

    private var sampleRate: Double
    private let slots: UnsafeMutablePointer<Slot>
    private let coefficients: UnsafeMutablePointer<BiquadCoefficients>

    private let activeIndex = ManagedAtomic<Int>(0)
    private let generation = ManagedAtomic<Int>(0)
    private let appliedGeneration = ManagedAtomic<Int>(-1)

    /// Interface thread only. Never taken by the audio thread.
    private let writerLock = NSLock()
    private var publishedParameters: EngineParameters
    private var nextWriteIndex = 1

    public init(initial: EngineParameters = .defaults, sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        self.publishedParameters = initial

        let capacity = Self.slotCount * EqualizerChain.maximumBandCount
        slots = UnsafeMutablePointer<Slot>.allocate(capacity: Self.slotCount)
        slots.initialize(repeating: Slot(), count: Self.slotCount)
        coefficients = UnsafeMutablePointer<BiquadCoefficients>.allocate(capacity: capacity)
        coefficients.initialize(repeating: .identity, count: capacity)

        resolve(initial, into: 0)
        activeIndex.store(0, ordering: .releasing)
        generation.store(0, ordering: .releasing)
    }

    deinit {
        slots.deinitialize(count: Self.slotCount)
        slots.deallocate()
        coefficients.deinitialize(count: Self.slotCount * EqualizerChain.maximumBandCount)
        coefficients.deallocate()
    }

    /// The most recently published values. Interface thread.
    public var current: EngineParameters {
        writerLock.lock()
        defer { writerLock.unlock() }
        return publishedParameters
    }

    /// Publishes a new parameter set, resolving its coefficients here.
    /// Interface thread.
    public func publish(_ parameters: EngineParameters) {
        writerLock.lock()
        publishedParameters = parameters
        publishLocked(parameters)
        writerLock.unlock()
    }

    /// Re-resolves the current parameters for a new sample rate and republishes.
    /// Call when the audio format changes, before the render loop starts.
    /// Interface thread.
    public func setSampleRate(_ sampleRate: Double) {
        writerLock.lock()
        self.sampleRate = sampleRate
        publishLocked(publishedParameters)
        writerLock.unlock()
    }

    /// Applies pending changes to the chain. Real-time thread.
    /// One atomic load when nothing changed; a float copy when something did.
    public func applyPendingChanges(to chain: DSPChain) {
        let published = generation.load(ordering: .acquiring)
        guard published != appliedGeneration.load(ordering: .relaxed) else { return }

        let index = activeIndex.load(ordering: .acquiring)
        let slot = slots[index]

        chain.applyResolved(
            isBypassed: slot.isBypassed,
            preampGain: slot.preampGain,
            coefficients: coefficients + index * EqualizerChain.maximumBandCount,
            count: slot.bandCount
        )

        appliedGeneration.store(published, ordering: .relaxed)
    }

    /// Writes the next slot and publishes it. Caller holds `writerLock`.
    private func publishLocked(_ parameters: EngineParameters) {
        let target = nextWriteIndex
        resolve(parameters, into: target)
        activeIndex.store(target, ordering: .releasing)
        generation.wrappingIncrement(ordering: .releasing)
        nextWriteIndex = (target + 1) % Self.slotCount
    }

    /// Turns bands into coefficients and fills one slot. Interface thread.
    private func resolve(_ parameters: EngineParameters, into index: Int) {
        let computed = EqualizerChain.coefficients(
            for: parameters.bands, sampleRate: sampleRate
        )
        let base = coefficients + index * EqualizerChain.maximumBandCount
        for offset in 0..<computed.count {
            base[offset] = computed[offset]
        }

        slots[index] = Slot(
            isBypassed: parameters.isBypassed,
            preampGain: Float(pow(10, parameters.preampDecibels / 20)),
            bandCount: computed.count
        )
    }
}
```

- [ ] **Step 7: Write the bridge tests**

Create `Tests/SonoraDSPTests/ParameterBridgeTests.swift`:

```swift
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
```

- [ ] **Step 8: Run the tests and the full suite**

Run: `swift test`
Expected: PASS, all suites, roughly 65 tests.

- [ ] **Step 9: Build the app to confirm the package change did not break it**

Run: `cd App && xcodegen generate && xcodebuild -project Sonora.xcodeproj -scheme Sonora -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 10: Commit**

```bash
git add Package.swift Package.resolved Sources/SonoraDSP/EngineParameters.swift Sources/SonoraDSP/ParameterBridge.swift Tests/SonoraDSPTests/EngineParametersTests.swift Tests/SonoraDSPTests/ParameterBridgeTests.swift
git commit -m "feat: add lock-free parameter bridge to the audio thread"
```

---

### Task 14: Engine controller, device watching, and a working equalizer

**Files:**
- Create: `App/Sonora/AudioEngine/DeviceWatcher.swift`
- Create: `App/Sonora/AudioEngine/AudioEngineController.swift`
- Create: `App/Sonora/StatusMenuController.swift`
- Modify: `App/Sonora/AppDelegate.swift`
- Modify: `docs/phase-0-measurements.md`

**Interfaces:**
- Consumes: `ProcessTap`, `AggregateDevice`, `RenderLoop`, `ParameterBridge`, `DSPChain`, `EngineParameters`, `Settings`, `SettingsStore`, `BuiltInPresets`.
- Produces:
  - `final class DeviceWatcher` with `init(onDefaultOutputChange: @escaping () -> Void)`, `func start()`, `func stop()`.
  - `final class AudioEngineController` with `init(settingsStore: SettingsStore)`, `func start()`, `func stop()`, `var parameters: EngineParameters { get }`, `func update(_ parameters: EngineParameters)`, `enum State { case stopped, running, bypassed(String) }`, `private(set) var state: State`, `var onStateChange: ((State) -> Void)?`.
  - `final class StatusMenuController` with `init(engine: AudioEngineController)`, `func install(in statusItem: NSStatusItem)`.

- [ ] **Step 1: Write the device watcher**

Create `App/Sonora/AudioEngine/DeviceWatcher.swift`:

```swift
import CoreAudio
import Foundation

/// Watches for the system output device changing, for example when headphones
/// are plugged in or a Bluetooth speaker connects.
///
/// The aggregate device is built around one specific output device. When that
/// device changes, the aggregate must be torn down and rebuilt, otherwise audio
/// stops with no error.
final class DeviceWatcher {

    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.sonora.DeviceWatcher")
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(onDefaultOutputChange: @escaping () -> Void) {
        self.onChange = onDefaultOutputChange
    }

    func start() {
        guard listenerBlock == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async { self.onChange() }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID.system, &address, queue, block
        )
        guard status == noErr else { return }
        listenerBlock = block
    }

    func stop() {
        guard let block = listenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID.system, &address, queue, block)
        listenerBlock = nil
    }

    deinit {
        stop()
    }
}
```

- [ ] **Step 2: Write the engine controller**

Create `App/Sonora/AudioEngine/AudioEngineController.swift`:

```swift
import CoreAudio
import Foundation
import OSLog
import SonoraDSP
import SonoraPersistence

/// Owns the whole audio path and every state transition in it.
///
/// The controller guarantees the rule from the design document: any failure ends
/// in bypass, which means the tap is destroyed and the system's own audio route
/// is back. It never leaves the user without sound.
final class AudioEngineController {

    enum State: Equatable {
        case stopped
        case running
        /// Not processing. The string explains why, for the menu.
        case bypassed(String)
    }

    private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    var onStateChange: ((State) -> Void)?

    private let settingsStore: SettingsStore
    private let bridge: ParameterBridge
    private let logger = Logger(subsystem: "com.sonora.Sonora", category: "Engine")

    private var tap = ProcessTap()
    private var aggregate: AggregateDevice?
    private var renderLoop: RenderLoop?
    private var chain: DSPChain?
    private var watcher: DeviceWatcher?

    private var settings: Settings

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        let loaded = settingsStore.load()
        self.settings = loaded
        self.bridge = ParameterBridge(
            initial: EngineParameters(
                isBypassed: loaded.isBypassed,
                preampDecibels: loaded.preampDecibels,
                bands: loaded.bands
            )
        )
    }

    var parameters: EngineParameters { bridge.current }

    /// Publishes new parameters and persists them.
    func update(_ parameters: EngineParameters) {
        bridge.publish(parameters)

        settings.isBypassed = parameters.isBypassed
        settings.preampDecibels = parameters.preampDecibels
        settings.bands = parameters.bands
        do {
            try settingsStore.save(settings)
        } catch {
            logger.error("Could not save settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Records which preset the user picked, alongside the bands it produced.
    func setActivePresetID(_ id: String?) {
        settings.activePresetID = id
        try? settingsStore.save(settings)
    }

    var activePresetID: String? { settings.activePresetID }

    func start() {
        guard state != .running else { return }

        let watcher = DeviceWatcher { [weak self] in
            self?.handleOutputDeviceChange()
        }
        watcher.start()
        self.watcher = watcher

        buildAudioPath()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        tearDownAudioPath()
        state = .stopped
    }

    /// Builds tap, aggregate and render loop. Any failure lands in bypass.
    private func buildAudioPath() {
        do {
            try tap.activate()

            let aggregate = AggregateDevice(tap: tap)
            try aggregate.create()
            self.aggregate = aggregate

            let format = try tap.streamDescription()
            let chain = DSPChain(
                sampleRate: format.mSampleRate,
                channelCount: Int(format.mChannelsPerFrame)
            )
            // Resolve coefficients for the real format before any audio flows.
            // This also republishes, so the first buffer picks the values up.
            bridge.setSampleRate(format.mSampleRate)
            self.chain = chain

            let bridge = self.bridge
            let renderLoop = RenderLoop(aggregate: aggregate)
            renderLoop.processBlock = { buffer, frameCount, _ in
                bridge.applyPendingChanges(to: chain)
                chain.process(buffer, frameCount: frameCount)
            }
            try renderLoop.start()
            self.renderLoop = renderLoop

            state = .running
            logger.info("Engine running at \(format.mSampleRate, privacy: .public) Hz")
        } catch {
            tearDownAudioPath()
            state = .bypassed(error.localizedDescription)
            logger.error("Engine bypassed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Destroys everything, which returns audio to the normal system route.
    private func tearDownAudioPath() {
        renderLoop?.stop()
        renderLoop = nil
        aggregate?.destroy()
        aggregate = nil
        chain = nil
        tap.invalidate()
    }

    /// Rebuilds the path around the new output device, preserving settings.
    private func handleOutputDeviceChange() {
        logger.info("Default output device changed, rebuilding")
        tearDownAudioPath()

        // A fresh tap object: the old one belonged to the torn down aggregate.
        tap = ProcessTap()
        buildAudioPath()
    }

    /// Tries to leave bypass and run again. Called from the menu.
    func retry() {
        tearDownAudioPath()
        tap = ProcessTap()
        buildAudioPath()
    }
}
```

- [ ] **Step 3: Write the status menu**

Create `App/Sonora/StatusMenuController.swift`:

```swift
import AppKit
import SonoraDSP
import SonoraProfiles

/// The minimal control surface for the engine.
///
/// This is a stepping stone, not the shipping interface. It exists so the engine
/// can be driven and verified before the panel is built in the next plan.
final class StatusMenuController: NSObject {

    private let engine: AudioEngineController
    private weak var statusItem: NSStatusItem?

    init(engine: AudioEngineController) {
        self.engine = engine
        super.init()
    }

    func install(in statusItem: NSStatusItem) {
        self.statusItem = statusItem
        engine.onStateChange = { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildMenu() }
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let statusItem else { return }

        let menu = NSMenu()

        switch engine.state {
        case .stopped:
            menu.addItem(withTitle: "Stopped", action: nil, keyEquivalent: "")
        case .running:
            menu.addItem(withTitle: "Running", action: nil, keyEquivalent: "")
        case .bypassed(let reason):
            menu.addItem(withTitle: "Bypassed", action: nil, keyEquivalent: "")
            let detail = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
            menu.addItem(
                withTitle: "Try Again",
                action: #selector(retry),
                keyEquivalent: ""
            ).target = self
        }

        menu.addItem(.separator())

        let bypassItem = NSMenuItem(
            title: "Bypass Equalizer",
            action: #selector(toggleBypass),
            keyEquivalent: ""
        )
        bypassItem.target = self
        bypassItem.state = engine.parameters.isBypassed ? .on : .off
        menu.addItem(bypassItem)

        menu.addItem(.separator())
        let presetsHeader = NSMenuItem(title: "Presets", action: nil, keyEquivalent: "")
        presetsHeader.isEnabled = false
        menu.addItem(presetsHeader)

        for preset in BuiltInPresets.all {
            let item = NSMenuItem(
                title: preset.name,
                action: #selector(selectPreset(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset
            item.state = engine.activePresetID == preset.id ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Sonora",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        statusItem.menu = menu
    }

    @objc private func retry() {
        engine.retry()
    }

    @objc private func toggleBypass() {
        var parameters = engine.parameters
        parameters.isBypassed.toggle()
        engine.update(parameters)
        rebuildMenu()
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? Preset else { return }

        var parameters = engine.parameters
        parameters.bands = preset.bands
        parameters.preampDecibels = preset.preampDecibels
        engine.update(parameters)
        engine.setActivePresetID(preset.id)
        rebuildMenu()
    }
}
```

- [ ] **Step 4: Wire it into the app delegate**

Replace `App/Sonora/AppDelegate.swift` with:

```swift
import AppKit
import SonoraPersistence

final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var statusItem: NSStatusItem!

    private let engine = AudioEngineController(
        settingsStore: SettingsStore(directory: SettingsStore.defaultDirectory())
    )
    private lazy var menuController = StatusMenuController(engine: engine)

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
        engine.stop()
    }
}
```

- [ ] **Step 5: Build**

Run: `cd App && xcodegen generate && xcodebuild -project Sonora.xcodeproj -scheme Sonora -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Run the full manual verification checklist**

Run the app from Xcode with music playing. Every item must pass:

1. The menu shows "Running".
2. Choosing "Bass Boost" audibly increases the low end within a second, with no click.
3. Switching between presets produces no clicks or dropouts.
4. "Bypass Equalizer" returns the sound to untouched, and unchecking it brings the curve back.
5. Quit and relaunch. The last preset and bypass state are still in effect.
6. Plug in headphones while music plays. Audio continues within a second or two and the equalizer is still applied.
7. Switch output to a Bluetooth device. Same result.
8. `kill -9` the app. Audio returns to normal immediately.
9. Loudness preset at full volume on loud music: no crackling or distortion.
10. Activity Monitor: Sonora's CPU use stays in the low single digits.

- [ ] **Step 7: Record the results**

Append a section to `docs/phase-0-measurements.md`:

```markdown
## Task 14 verification

| Check | Result |
|---|---|
| Menu shows Running | |
| Preset change audible, no click | |
| Preset switching clean | |
| Bypass toggles correctly | |
| Settings survive relaunch | |
| Headphone plug survives | |
| Bluetooth switch survives | |
| kill -9 restores audio | |
| No distortion on Loudness at full volume | |
| CPU use | |
```

- [ ] **Step 8: Commit and push**

```bash
git add App/Sonora docs/phase-0-measurements.md
git commit -m "feat: add engine controller, device watching and preset menu"
git push
```

---

## Definition of done

This plan is complete when:

1. `swift test` passes, covering the DSP chain, presets and the settings store.
2. CI is green on `main`.
3. The app applies a chosen equalizer preset to system audio in real time.
4. Every item in the Task 14 checklist passes.
5. `docs/phase-0-measurements.md` records the latency figure and a gate decision.

## Deliberately deferred

These are spec requirements that this plan does not cover, listed so they are not
lost:

- **Accessibility permission and volume key capture.** Design document section 7.2.
- **Stream format change while running.** Section 9 lists it. The device change
  path in Task 14 covers the common case, since a format change almost always
  accompanies a device change. A listener on `kAudioDevicePropertyStreamFormat`
  belongs in the next plan.
- **Onboarding and the permission explanation screen.** Section 9, first row.
  Until then a denied permission shows as a bypass reason in the status menu.
- **Notarized DMG, Homebrew cask, Sparkle updates.** Section 11.
- **The panel interface.** Section 7.1. The status menu in Task 14 is a stepping
  stone, not the shipping surface.

## What comes next

A second plan covers the shipping interface: the panel window, the ten band sliders and curve, the volume key capture through `CGEventTap`, the accessibility permission flow, the onboarding screen, and notarized DMG packaging. It is written after the Task 12 gate, because the latency measurement decides whether the tap architecture survives.
