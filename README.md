# Sonora

A system-wide audio equalizer and per-app volume mixer for macOS. No driver install, no admin password, no kernel extension.

> **Status: early development.** Nothing is shippable yet. The design is settled and the engine spike is in progress. Follow along, the commit history is the build log.

## Why

macOS gives you exactly one audio control: the master volume slider. There is no equalizer, no per-app volume, no per-device sound profile. You cannot fix the thin bass on a MacBook speaker, you cannot turn Spotify down while leaving Zoom up, and you cannot correct your headphones' frequency response.

The commercial answers are paid and closed. The open source answer, eqMac, installs a HAL driver, which means an admin password and an install that breaks across OS updates.

Sonora takes the modern path instead: Core Audio process taps, introduced in macOS 14.2. Drag to Applications, grant one permission, done.

## How it works

```
App audio
  -> Core Audio process tap (global, muted when tapped)
  -> private aggregate device (real output device as main sub-device)
  -> IOProc: our DSP chain
  -> real output device
```

The DSP chain is hand-written and runs in the real-time render callback: a cascade of biquad filters for the equalizer, a preamp, and a soft limiter. No `AVAudioEngine`, because it cannot be retargeted to a tap-backed aggregate device.

Every failure path falls back to bypass, which destroys the tap and returns audio to the normal system route. You never end up with a silent Mac.

## Planned features

| Phase | What |
|---|---|
| 0 | Engine spike: tap, aggregate device, passthrough, latency measurement |
| 1 | 10-band graphic EQ, preamp above 100% with soft limiter, menu bar panel, volume-key capture, presets |
| 2 | Live spectrum analyzer, full parametric mode, balance, mono, output delay |
| 3 | Per-device profiles, AutoEq headphone correction library |
| 4 | Per-app volume and EQ mixer |
| 5 | AudioDriverKit fallback engine for cases the tap cannot cover |

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

## Design

The reasoning lives in the source. Every non-obvious decision, and there are
several, carries a doc comment explaining what it protects against: read
`EqualizerChain` for the threading contract between the setup thread and the
render callback, and `Biquad` for why filter state is flushed when it goes
subnormal or non-finite.

The original design document is written in Turkish, the author's working
language, and is kept under `docs/` for the record rather than as contributor
documentation.

## License

MIT. See [LICENSE](LICENSE).
