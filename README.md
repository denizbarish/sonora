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

## Requirements

- macOS 14.4 or later
- Apple silicon or Intel

Building from source additionally needs Xcode 26 or later and a signing identity. Process taps will not work in an unsigned build, because the permission record is keyed to the signing identity.

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
