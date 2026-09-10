# Sonora Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Sonora something another person can download, understand and use, and let those who want it put the volume keys under Sonora's control.

**Architecture:** Three separable pieces sharing one deliverable. An opt-in volume key tap behind the Accessibility permission, a first-run window that explains the audio permission before the system asks for it, and a signed disk image published from a tagged release. Nothing here touches the audio engine.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit, `CGEvent` taps, `AXIsProcessTrustedWithOptions`, `hdiutil`, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-07-sonora-design.md`, sections 7.2 and 11.

## Global Constraints

- Deployment target macOS 14.4, Swift 6.2, language mode 6, strict concurrency, Xcode 26.3.
- Every interface type touching AppKit or the engine is `@MainActor`. `@unchecked Sendable` must not appear anywhere under `App/`. If something does not compile, report the diagnostic rather than silencing it.
- Volume key capture is **off by default**. The app must install, launch and work fully without ever requesting the Accessibility permission. That permission is requested only when someone turns the feature on, and a refusal must leave the app fully functional.
- Nothing in the interface may read from `EqualizerChain` or `DSPChain`; those belong to the audio thread.
- **No notarisation in this plan.** There is no paid Apple Developer Program membership. The disk image carries an ad hoc signed app, and the documentation says plainly what that means for the person installing it.
- Signing for local builds stays as it is: `export SONORA_CODE_SIGN_IDENTITY="Apple Development: YOUR NAME (YOURTEAMID)"`, then `cd App && xcodegen generate && xcodebuild ...`. Never work around signing by disabling it or dropping Hardened Runtime.
- `App/project.yml` must keep having no `info:` or `entitlements:` keys. Those make XcodeGen regenerate those files and silently drop `NSAudioCaptureUsageDescription`.
- Tests use Swift Testing, not XCTest. Only the Swift package is testable; `App/` has no test target.
- All user-facing strings in English. The repository is public and international.
- Code, comments and commit messages in English. Conventional commit prefixes. No license headers.
- `swift test --sanitize=address` does not work on this machine or in CI: it builds and then hangs. Do not attempt it.

## File structure

| File | Responsibility |
|---|---|
| `Sources/SonoraPersistence/Settings.swift` | Gains one flag: whether volume key capture is on. |
| `App/Sonora/Input/AccessibilityPermission.swift` | Reports and requests the Accessibility permission. Nothing else. |
| `App/Sonora/Input/VolumeKeyTap.swift` | The `CGEvent` tap itself: start, stop, and a callback per key press. |
| `App/Sonora/Onboarding/WelcomeWindow.swift` | First-run window explaining the audio permission. |
| `App/Sonora/UI/PanelView.swift` | Gains the volume key toggle. |
| `App/Sonora/UI/PanelModel.swift` | Owns the toggle's state and the permission dance. |
| `Scripts/make-dmg.sh` | Builds, signs and packages a disk image. |
| `.github/workflows/release.yml` | Builds and attaches the disk image to a tagged release. |
| `README.md` | Honest install instructions. |

---

### Task 1: Can the volume keys be intercepted at all?

**This task is a gate, like the latency measurement was for the engine.** Everything after it assumes volume keys can be captured. They may not be: media keys such as play and pause have long been interceptable through a `CGEvent` tap on `NSSystemDefined` events, but the volume keys are frequently consumed by the system before any tap sees them, and behaviour has changed across macOS releases. Finding that out after building a settings toggle and an onboarding flow around it would be expensive.

**Files:**
- Create: `Tools/volume-key-spike/main.swift`
- Create: `Tools/volume-key-spike/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a throwaway command line tool and a written answer. No production code depends on it.

- [ ] **Step 1: Write the spike**

Create `Tools/volume-key-spike/main.swift`:

```swift
import AppKit
import CoreGraphics

// Does a CGEvent tap see the volume keys, and can it swallow them?
//
// Media keys arrive as NSSystemDefined events with subtype 8, carrying the key
// code in the event data rather than as an ordinary key code. The volume keys
// are the uncertain ones: the system often consumes them first. This asks the
// question directly rather than building a feature on an assumption.
//
// Run from a terminal that already holds the Accessibility permission.

// CGEventType has no case for system defined events, so the mask is built
// from the raw NX_SYSDEFINED value, 14. This is the standard idiom for tapping
// media keys.
let mask = CGEventMask(1 << 14)

guard let tap = CGEvent.tapCreate(
    tap: .cghidEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: mask,
    callback: { _, _, event, _ in
        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int32((nsEvent.data1 & 0xFFFF_0000) >> 16)
        let isPressed = ((nsEvent.data1 & 0x0000_FF00) >> 8) == 0x0A

        let name: String
        switch keyCode {
        case NX_KEYTYPE_SOUND_UP: name = "volume up"
        case NX_KEYTYPE_SOUND_DOWN: name = "volume down"
        case NX_KEYTYPE_MUTE: name = "mute"
        case NX_KEYTYPE_PLAY: name = "play"
        default: name = "other (\(keyCode))"
        }

        if isPressed {
            print("saw \(name)")
        }

        // Swallowing means returning nil. Try it for the volume keys only, so
        // the machine stays usable if this runs longer than expected.
        let isVolume = keyCode == NX_KEYTYPE_SOUND_UP
            || keyCode == NX_KEYTYPE_SOUND_DOWN
            || keyCode == NX_KEYTYPE_MUTE
        return isVolume ? nil : Unmanaged.passUnretained(event)
    },
    userInfo: nil
) else {
    print("tap could not be created: the process is probably not trusted for Accessibility")
    exit(1)
}

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

print("listening for 30 seconds, press the volume keys")
print("if the system volume changes anyway, the tap did not swallow them")

DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    CGEvent.tapEnable(tap: tap, enable: false)
    print("done")
    exit(0)
}

CFRunLoopRun()
```

- [ ] **Step 2: Build and run it**

Run:
```bash
cd Tools/volume-key-spike
swiftc -o volume-key-spike main.swift
./volume-key-spike
```

The terminal running it must already be trusted under System Settings, Privacy and Security, Accessibility. If the tap cannot be created, that is the first thing to check.

Press volume up, volume down and mute several times while it runs.

- [ ] **Step 3: Write down what actually happened**

Create `Tools/volume-key-spike/README.md` recording, honestly:

- Whether the tap could be created at all.
- Whether each volume key was seen.
- Whether returning nil actually swallowed them, or the system volume changed anyway.
- Whether the on-screen volume overlay still appeared.
- macOS version and keyboard, built-in or external, since behaviour differs.

- [ ] **Step 4: Commit and stop**

```bash
git add Tools/volume-key-spike
git commit -m "chore: measure whether a CGEvent tap can capture the volume keys"
```

**Report the result before starting Task 2.** If the keys cannot be captured, or cannot be swallowed, tasks 2 through 5 are pointless and the plan drops to onboarding and packaging. That is a legitimate outcome, not a failure.

---

### Task 2: Remember whether the feature is on

**Files:**
- Modify: `Sources/SonoraPersistence/Settings.swift`
- Test: `Tests/SonoraPersistenceTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: the existing `Settings`.
- Produces: `public var capturesVolumeKeys: Bool` on `Settings`, defaulting to `false`.

**The trap this repeats.** `Settings` has a hand-written `init(from:)` precisely because adding a stored property to a synthesised `Codable` makes that key required, which makes every settings file already on disk fail to decode, get quarantined, and reset the user's equalizer. The last field added went through `decodeIfPresent` for that reason. Do the same. Do not raise `currentSchemaVersion`: it is already 2, `oldestDecodableSchemaVersion` is 1, and this change is backward compatible in exactly the same way the last one was.

- [ ] **Step 1: Write the failing test**

Add to `Tests/SonoraPersistenceTests/SettingsStoreTests.swift`:

```swift
    @Test("a file written before the volume key flag existed still loads")
    func schemaWithoutVolumeKeyFlag() throws {
        let directory = try makeTemporaryDirectory()
        let store = SettingsStore(directory: directory)

        // Hand written on purpose. Encoding a Settings here would use the same
        // code the decoder uses, so it could not fail on a schema change.
        let payload = """
        {
          "schemaVersion": 2,
          "isBypassed": false,
          "preampDecibels": -3,
          "bands": [],
          "userPresets": [],
          "recentPresetIDs": ["builtin.vocal"]
        }
        """
        try Data(payload.utf8).write(to: store.fileURL)

        let loaded = store.load()

        #expect(store.lastLoadFailure == nil)
        #expect(loaded.preampDecibels == -3)
        #expect(loaded.recentPresetIDs == ["builtin.vocal"])
        #expect(loaded.capturesVolumeKeys == false)
    }

    @Test("the volume key flag survives a round trip")
    func volumeKeyFlagRoundTrip() throws {
        let store = SettingsStore(directory: try makeTemporaryDirectory())

        var settings = Settings.defaults
        settings.capturesVolumeKeys = true
        try store.save(settings)

        #expect(store.load().capturesVolumeKeys == true)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter schemaWithoutVolumeKeyFlag`
Expected: FAIL, compiler error `value of type 'Settings' has no member 'capturesVolumeKeys'`.

- [ ] **Step 3: Add the property**

In `Sources/SonoraPersistence/Settings.swift`, add this stored property after `recentPresetIDs`:

```swift
    /// Whether Sonora puts the volume keys under its own control.
    ///
    /// Off by default, and deliberately so: turning it on requires the
    /// Accessibility permission, which is a much bigger thing to ask for than
    /// audio capture. Someone who never wants it never sees that prompt.
    public var capturesVolumeKeys: Bool
```

Give it a default of `false` as the last parameter of the memberwise initialiser, so every existing caller keeps working.

In `init(from:)`, decode it tolerantly, matching what `recentPresetIDs` does:

```swift
        // Added after the schema was already at 2. A file without the key is
        // not an error, it just predates the feature.
        capturesVolumeKeys = try container.decodeIfPresent(
            Bool.self, forKey: .capturesVolumeKeys
        ) ?? false
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter SettingsStoreTests`
Expected: PASS, 19 tests. It was 17.

- [ ] **Step 5: Prove the tolerant decode is doing the work**

Change `decodeIfPresent(...) ?? false` to a plain `decode(...)`, run `swift test --filter schemaWithoutVolumeKeyFlag`, and confirm it fails. Then restore it. Report the real failing output.

- [ ] **Step 6: Run the whole suite and commit**

Run: `swift test`
Expected: PASS, 94 tests. It was 92.

```bash
git add Sources/SonoraPersistence/Settings.swift Tests/SonoraPersistenceTests/SettingsStoreTests.swift
git commit -m "feat: remember whether volume key capture is enabled"
```

---

### Task 3: The Accessibility permission

**Files:**
- Create: `App/Sonora/Input/AccessibilityPermission.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `@MainActor enum AccessibilityPermission` with `static var isTrusted: Bool`, `static func request()`, and `static func openSettings()`.

**The distinction that matters.** `AXIsProcessTrustedWithOptions` shows the system prompt when passed `kAXTrustedCheckOptionPrompt: true`, and merely reports the state when passed false. Checking must never prompt: the app checks on every launch to decide whether to start the tap, and a prompt on every launch would be intolerable. Only the toggle prompts.

- [ ] **Step 1: Write it**

Create `App/Sonora/Input/AccessibilityPermission.swift`:

```swift
import ApplicationServices
import AppKit

/// The Accessibility permission, which a `CGEvent` tap needs.
///
/// This is a much larger thing to ask for than audio capture: it lets an app
/// observe and synthesise input everywhere. Sonora asks for it only when
/// someone turns volume key capture on, and works completely without it.
@MainActor
enum AccessibilityPermission {

    /// Whether the app is trusted. Never prompts, so it is safe to call on
    /// every launch and whenever the panel opens.
    /// The prompt option's key, spelled out rather than taken from the SDK.
    ///
    /// `AXUIElement.h` declares `kAXTrustedCheckOptionPrompt` without `const`,
    /// so Swift imports it as a mutable global and language mode 6 rejects
    /// reading it: "not concurrency-safe because it involves shared mutable
    /// state". Every way to keep the constant is a way to suppress that check.
    /// The literal is verified equal to the SDK's value by `CFEqual`.
    private static let promptOption = "AXTrustedCheckOptionPrompt" as CFString

    static var isTrusted: Bool {
        AXIsProcessTrustedWithOptions([promptOption: false] as CFDictionary)
    }

    /// Asks the system to show its permission prompt.
    ///
    /// The prompt appears once per app identity; afterwards the system stays
    /// silent and the only route is System Settings, which is why
    /// `openSettings()` exists alongside this.
    static func request() {
        _ = AXIsProcessTrustedWithOptions([promptOption: true] as CFDictionary)
    }

    /// Opens the Accessibility pane, for when the prompt will not appear again.
    static func openSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
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

- [ ] **Step 3: Commit**

```bash
git add App/Sonora/Input/AccessibilityPermission.swift
git commit -m "feat: report and request the accessibility permission"
```

---

### Task 4: The volume key tap

**Files:**
- Create: `App/Sonora/Input/VolumeKeyTap.swift`

**Interfaces:**
- Consumes: `AccessibilityPermission`.
- Produces: `@MainActor final class VolumeKeyTap` with `enum Key { case up, down, mute }`, `var onKey: ((Key) -> Void)?`, `func start() throws`, `func stop()`, `private(set) var isRunning: Bool`, and `enum TapError: LocalizedError { case notTrusted, tapCreationFailed }`.

**Write this against what Task 1 actually measured**, not against what the spike file assumes. If the spike found the keys arrive differently, or cannot be swallowed, follow the measurement and say so in your report.

The tap callback runs on a run loop, not the main thread's normal flow, and cannot capture main-actor state directly. Keep the callback tiny: decode the key and hop to the main actor.

- [ ] **Step 1: Write it**

Create `App/Sonora/Input/VolumeKeyTap.swift`:

```swift
import AppKit
import CoreGraphics

/// Puts the volume keys under Sonora's control.
///
/// Media keys arrive as `NSSystemDefined` events with subtype 8, carrying the
/// key in `data1` rather than as an ordinary key code. Returning nil from the
/// callback swallows the event, which is what stops the system's own volume
/// overlay from appearing alongside Sonora's panel.
///
/// The tap needs the Accessibility permission and fails cleanly without it.
@MainActor
final class VolumeKeyTap {

    enum Key {
        case up, down, mute
    }

    enum TapError: LocalizedError {
        case notTrusted
        case tapCreationFailed

        var errorDescription: String? {
            switch self {
            case .notTrusted:
                return "Sonora needs Accessibility permission to use the volume keys."
            case .tapCreationFailed:
                return "The volume keys could not be captured."
            }
        }
    }

    var onKey: ((Key) -> Void)?

    private(set) var isRunning = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func start() throws {
        guard !isRunning else { return }
        guard AccessibilityPermission.isTrusted else { throw TapError.notTrusted }

        let mask = CGEventMask(1 << CGEventType.systemDefined.rawValue)

        // The callback cannot capture main-actor state, so it carries an
        // unmanaged pointer to self and hops back to the main actor with the
        // decoded key. Nothing else happens on the tap's own thread.
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                // The system disables a tap that takes too long or when input
                // is interrupted. Re-enabling is the documented recovery.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let userInfo {
                        let tap = Unmanaged<VolumeKeyTap>.fromOpaque(userInfo)
                            .takeUnretainedValue()
                        Task { @MainActor in tap.reEnable() }
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard let nsEvent = NSEvent(cgEvent: event),
                      nsEvent.subtype.rawValue == 8,
                      let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let keyCode = Int32((nsEvent.data1 & 0xFFFF_0000) >> 16)
                let isPressed = ((nsEvent.data1 & 0x0000_FF00) >> 8) == 0x0A

                let key: Key?
                switch keyCode {
                case NX_KEYTYPE_SOUND_UP: key = .up
                case NX_KEYTYPE_SOUND_DOWN: key = .down
                case NX_KEYTYPE_MUTE: key = .mute
                default: key = nil
                }

                guard let key else { return Unmanaged.passUnretained(event) }

                if isPressed {
                    let owner = Unmanaged<VolumeKeyTap>.fromOpaque(userInfo)
                        .takeUnretainedValue()
                    Task { @MainActor in owner.onKey?(key) }
                }

                // Swallow it, so the system's own overlay stays out of the way.
                return nil
            },
            userInfo: context
        ) else {
            throw TapError.tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.source = source
        isRunning = true
    }

    func stop() {
        guard let tap, let source else {
            isRunning = false
            return
        }

        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        CFMachPortInvalidate(tap)

        self.tap = nil
        self.source = nil
        isRunning = false
    }

    private func reEnable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        // The run loop source and mach port die with the process. Tearing them
        // down here would need main-actor state a deinit cannot reach.
    }
}
```

- [ ] **Step 2: Build**

Run the standard build. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add App/Sonora/Input/VolumeKeyTap.swift
git commit -m "feat: capture the volume keys behind an event tap"
```

---

### Task 5: The toggle, and what happens when permission is refused

**Files:**
- Modify: `App/Sonora/UI/PanelModel.swift`
- Modify: `App/Sonora/UI/PanelView.swift`
- Modify: `App/Sonora/AudioEngine/AudioEngineController.swift`

**Interfaces:**
- Consumes: `VolumeKeyTap`, `AccessibilityPermission`, `SystemVolume`, `Settings.capturesVolumeKeys`.
- Produces: on `PanelModel`, `var capturesVolumeKeys: Bool { get set }` and `private(set) var volumeKeyProblem: String?`. On `AudioEngineController`, `var capturesVolumeKeys: Bool { get }` and `func setCapturesVolumeKeys(_ enabled: Bool)`, persisted through the existing debounced save.

**The behaviour that matters more than the feature.** Turning the toggle on when the app is not trusted must not silently fail, and must not leave the toggle looking on when nothing is captured. Request the permission, and if the app is still untrusted, put the toggle back off and say why, with a way to open System Settings. The system's own prompt appears only once per app identity, so the message has to stand on its own afterwards.

- [ ] **Step 1: Persist the flag through the engine controller**

In `AudioEngineController`, add alongside the existing preset accessors:

```swift
    var capturesVolumeKeys: Bool { settings.capturesVolumeKeys }

    /// Records the preference. The tap itself is owned by the interface, which
    /// is where the permission conversation belongs.
    func setCapturesVolumeKeys(_ enabled: Bool) {
        settings.capturesVolumeKeys = enabled
        scheduleSave()
    }
```

`scheduleSave()` is the debounced writer added when the settings file was being written on every slider frame. Use it; do not reintroduce a direct `save` call.

- [ ] **Step 2: Own the tap in the model**

In `PanelModel`, add these stored properties:

```swift
    /// Set when turning the feature on did not work, so the panel can explain
    /// rather than leaving a toggle that lies.
    private(set) var volumeKeyProblem: String?

    private let volumeKeys = VolumeKeyTap()
```

Add the toggle:

```swift
    var capturesVolumeKeys: Bool {
        didSet {
            guard capturesVolumeKeys != oldValue else { return }
            applyVolumeKeyPreference()
        }
    }
```

Initialise it in `init` from `engine.capturesVolumeKeys`, wire the tap's callback, and start the tap if the preference is already on and the app is trusted:

```swift
        self.capturesVolumeKeys = engine.capturesVolumeKeys

        volumeKeys.onKey = { [weak self] key in
            self?.handleVolumeKey(key)
        }
```

Then, at the end of `init`, after every stored property is set:

```swift
        if capturesVolumeKeys, AccessibilityPermission.isTrusted {
            try? volumeKeys.start()
        }
```

Add the two methods:

```swift
    /// Starts or stops the tap, asking for permission when it is needed.
    ///
    /// If the app is still untrusted after asking, the toggle goes back off.
    /// A toggle that stays on while nothing is captured is worse than one that
    /// refuses, because the user has no way to tell the difference.
    private func applyVolumeKeyPreference() {
        volumeKeyProblem = nil

        guard capturesVolumeKeys else {
            volumeKeys.stop()
            engine.setCapturesVolumeKeys(false)
            return
        }

        if !AccessibilityPermission.isTrusted {
            AccessibilityPermission.request()
        }

        do {
            try volumeKeys.start()
            engine.setCapturesVolumeKeys(true)
        } catch {
            capturesVolumeKeys = false
            engine.setCapturesVolumeKeys(false)
            volumeKeyProblem = error.localizedDescription
        }
    }

    /// One key press. Steps match the system's own, an eighth of full scale.
    private func handleVolumeKey(_ key: VolumeKeyTap.Key) {
        switch key {
        case .up:
            systemVolume = min(systemVolume + 0.0625, 1)
        case .down:
            systemVolume = max(systemVolume - 0.0625, 0)
        case .mute:
            volume.isMuted.toggle()
        }
    }

    /// Opens the Accessibility pane, for when the system will not prompt again.
    func openAccessibilitySettings() {
        AccessibilityPermission.openSettings()
    }
```

- [ ] **Step 3: Put it in the panel**

In `PanelView`, add this below the preset section and above the footer:

```swift
    private var volumeKeys: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Use the volume keys", isOn: $model.capturesVolumeKeys)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

            if let problem = model.volumeKeyProblem {
                HStack(spacing: 6) {
                    Text(problem)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Open Settings", action: model.openAccessibilitySettings)
                        .controlSize(.small)
                }
            }
        }
    }
```

Add `volumeKeys` to the body between the preset section and the footer, with a `Divider()` above it, matching the spacing of the sections around it.

- [ ] **Step 4: Build**

Run the standard build. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Run the package suite**

Run: `swift test`
Expected: PASS, 94 tests. You have not touched the package, so a different number means something went out of scope.

- [ ] **Step 6: Commit**

```bash
git add App/Sonora
git commit -m "feat: let the volume keys drive Sonora, off by default"
```

- [ ] **Step 7: Hand the runtime checks to a human**

These cannot be verified without a person at the machine:

1. The toggle starts off, and the app has never asked for Accessibility.
2. Turning it on shows the system prompt.
3. Refusing puts the toggle back off and shows the message with its button.
4. The button opens the Accessibility pane.
5. Granting it and turning the toggle on makes the volume keys change the volume.
6. The system's own volume overlay no longer appears while it is on.
7. Turning it off returns the keys to the system.
8. The preference survives a relaunch.

---

### Task 6: The first-run window

**Files:**
- Create: `App/Sonora/Onboarding/WelcomeWindow.swift`
- Modify: `App/Sonora/AppDelegate.swift`

**Interfaces:**
- Consumes: `AudioEngineController.state`.
- Produces: `@MainActor final class WelcomeWindow` with `init(onContinue: @escaping () -> Void)` and `func show()`.

**Why this exists.** The system's audio permission prompt appears the moment the engine starts, with no context beyond one sentence in `Info.plist`. Someone who just downloaded a menu bar app and is immediately asked to let it record system audio has every reason to refuse. This window goes first and explains, in the app's own words, what is about to be asked and why.

Show it only when the engine could not get the permission, which is exactly the case where explanation is worth something. Do not show it on every launch.

- [ ] **Step 1: Write the window**

Create `App/Sonora/Onboarding/WelcomeWindow.swift`:

```swift
import AppKit
import SwiftUI

/// Explains the audio permission before, or after, the system asks for it.
///
/// The system's own prompt carries one sentence and no context. Someone who has
/// just downloaded a menu bar app and is immediately asked to let it record
/// system audio has good reason to say no. This says why first.
@MainActor
final class WelcomeWindow {

    private var window: NSWindow?
    private let onContinue: () -> Void

    init(onContinue: @escaping () -> Void) {
        self.onContinue = onContinue
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let view = WelcomeView(
            onContinue: { [weak self] in
                self?.close()
                self?.onContinue()
            },
            onOpenSettings: {
                guard let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
                ) else { return }
                NSWorkspace.shared.open(url)
            }
        )

        let hosting = NSHostingView(rootView: view)
        hosting.layout()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sonora"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func close() {
        window?.orderOut(nil)
    }
}

private struct WelcomeView: View {

    let onContinue: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sonora needs permission to hear your Mac")
                .font(.system(size: 15, weight: .semibold))

            Text(
                """
                macOS has no equalizer, so Sonora captures what your Mac is \
                playing, runs it through the equalizer, and plays it back. \
                That capture is what the permission is for.

                The audio never leaves your Mac. It is processed as it plays \
                and is never recorded, stored or sent anywhere. Sonora is open \
                source, so you can check that for yourself.
                """
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text("Grant it under Privacy & Security, then System Audio Recording.")
                .font(.system(size: 12))

            HStack {
                Button("Open Settings", action: onOpenSettings)
                Spacer()
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
```

- [ ] **Step 2: Show it when the engine cannot start**

In `AppDelegate`, add a stored property:

```swift
    private lazy var welcome = WelcomeWindow(onContinue: { [weak self] in
        self?.engine.retry()
    })
```

In `applicationDidFinishLaunching`, after `engine.start()`, add:

```swift
        // Only when the engine could not get the permission. On a machine that
        // already granted it, this window would be noise.
        if case .bypassed = engine.state {
            welcome.show()
        }
```

- [ ] **Step 3: Build**

Run the standard build. Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add App/Sonora/Onboarding App/Sonora/AppDelegate.swift
git commit -m "feat: explain the audio permission before the system asks"
```

- [ ] **Step 5: Hand the runtime check to a human**

Reset the permission and relaunch:

```bash
tccutil reset SystemAudioCaptureRequests com.sonora.Sonora
```

Expected: the window appears, its Open Settings button lands on the right pane, and Continue retries the engine. On a machine that already has the permission, the window must not appear at all.

---

### Task 7: A disk image, and honest instructions

**Files:**
- Create: `Scripts/make-dmg.sh`
- Create: `.github/workflows/release.yml`
- Modify: `README.md`

**Interfaces:**
- Consumes: the app target.
- Produces: a `Sonora-<version>.dmg`, and a release that carries it.

**Say what this is.** There is no paid Apple Developer Program membership, so the app inside is ad hoc signed rather than Developer ID signed and notarised. Gatekeeper will refuse to open it on first launch until the user right-clicks and chooses Open. The README must say that plainly rather than letting someone discover it as a scary dialog. It must also say that an ad hoc build's audio permission is tied to that exact build, so the permission is asked for again after every update.

- [ ] **Step 1: Write the packaging script**

Create `Scripts/make-dmg.sh`:

```bash
#!/bin/bash
# Builds Sonora and wraps it in a disk image.
#
# The app is ad hoc signed unless SONORA_CODE_SIGN_IDENTITY names a real
# identity. Ad hoc is enough for the audio permission, which macOS keys to the
# binary's hash rather than to a developer identity, but it is not enough for
# Gatekeeper: whoever downloads this has to right-click and choose Open once.
set -euo pipefail

VERSION="${1:?usage: make-dmg.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/dmg"

rm -rf "$BUILD"
mkdir -p "$BUILD/staging"

cd "$ROOT/App"
xcodegen generate
xcodebuild \
  -project Sonora.xcodeproj \
  -scheme Sonora \
  -configuration Release \
  -derivedDataPath "$BUILD/derived" \
  build

APP="$BUILD/derived/Build/Products/Release/Sonora.app"
[ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }

echo "== signature =="
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E 'flags|Authority=' || true

cp -R "$APP" "$BUILD/staging/"
ln -s /Applications "$BUILD/staging/Applications"

hdiutil create \
  -volname "Sonora" \
  -srcfolder "$BUILD/staging" \
  -ov -format UDZO \
  "$ROOT/Sonora-$VERSION.dmg"

echo "== wrote Sonora-$VERSION.dmg =="
shasum -a 256 "$ROOT/Sonora-$VERSION.dmg"
```

Make it executable with `chmod +x Scripts/make-dmg.sh`.

- [ ] **Step 2: Verify it produces something that runs**

Run:
```bash
export SONORA_CODE_SIGN_IDENTITY="Apple Development: YOUR NAME (YOURTEAMID)"
./Scripts/make-dmg.sh 0.1.0
```

Then mount the image, drag the app to Applications, and launch it from there. Report whether it runs and whether the audio permission prompt appears for a copy at a new path. Do not skip this: an app that works from the build directory and not from `/Applications` is a common and silent failure.

- [ ] **Step 3: Write the release workflow**

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags: ["v*"]

permissions:
  contents: write

jobs:
  dmg:
    name: Build the disk image
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4

      - name: Select Xcode
        run: sudo xcode-select -switch /Applications/Xcode_26.3.app

      - name: Test
        run: swift test --parallel

      # No signing identity on the runner, so the app inside is ad hoc signed.
      # That is enough for the audio permission, which macOS keys to the
      # binary's hash, and not enough for Gatekeeper, which the README covers.
      - name: Build the disk image
        run: ./Scripts/make-dmg.sh "${GITHUB_REF_NAME#v}"

      - name: Attach it to the release
        uses: softprops/action-gh-release@v2
        with:
          files: Sonora-*.dmg
          draft: true
          generate_release_notes: true
```

- [ ] **Step 4: Check the workflow parses**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml')); print('valid')"`
Expected: `valid`

- [ ] **Step 5: Rewrite the install section of the README**

Replace the `## Requirements` section of `README.md` with:

````markdown
## Install

Download the disk image from [Releases](https://github.com/denizbarish/sonora/releases), open it, and drag Sonora to Applications.

**The first launch needs a right-click.** Sonora is not notarised, because notarisation requires a paid Apple Developer Program membership. macOS will refuse to open it normally. Right-click the app, choose Open, and confirm. You only have to do this once per version.

Then Sonora asks for permission to record system audio. That is what lets it apply the equalizer to what your Mac is playing. The audio is processed as it plays and is never recorded, stored or sent anywhere.

Because the build is not signed with a developer identity, macOS ties that permission to the exact binary, so each new version asks again.

## Requirements

- macOS 14.4 or later
- Apple silicon or Intel

## Build from source

```bash
git clone https://github.com/denizbarish/sonora.git
cd sonora
swift test
cd App && xcodegen generate
```

Then open `App/Sonora.xcodeproj` in Xcode, choose your team under Signing & Capabilities, and run. `App/README.md` explains why signing matters here: an unsigned build never receives the audio permission, so it launches and captures nothing.
````

- [ ] **Step 6: Commit**

```bash
chmod +x Scripts/make-dmg.sh
git add Scripts .github/workflows/release.yml README.md
git commit -m "feat: package a disk image and say plainly what it is"
```

---

## Definition of done

1. `swift test` passes at 94 tests.
2. Task 1 recorded a real answer about the volume keys, and tasks 2 through 5 either follow it or were dropped because of it.
3. The toggle asks for Accessibility only when turned on, and refuses honestly when denied.
4. The welcome window appears only when the audio permission is missing.
5. `./Scripts/make-dmg.sh` produces an image whose app runs from `/Applications`.
6. The README tells someone the truth about the right-click and the per-version permission.

## Deliberately not in this plan

Two things the design document asks for that this plan does not build, recorded
so they are not lost:

- **A user-definable global shortcut to open the panel.** Section 7.2 asks for
  one alongside the volume keys. It needs a shortcut recorder control and its
  own persistence, which is a feature in its own right rather than a detail of
  this one.
- **A Homebrew cask.** Section 11 asks for one. A cask pointing at a disk image
  that Gatekeeper refuses on first launch is awkward to write honestly, and it
  is worth revisiting once there is a notarised build to point at.

## Carried over, still open

From the engine and panel reviews, deliberately not addressed here:

- A device that exposes volume only on its channel elements leaves the slider inert rather than disabled.
- The panel measures its size once and does not grow if its content does, which the new volume key row makes more likely to matter.
- A settings file with the wrong band count is truncated rather than normalised.
- The output picker hides every aggregate device, including a user's own Multi-Output Device, not just Sonora's.
- `EqualizerBand.gainRange` is declared and tested but never enforced against data read from disk.
- `swift_beginAccess` is on the render path in release builds.
