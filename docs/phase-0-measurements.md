# Phase 0 measurements

Machine: MacBook Air (Mac14,2), Apple M2, 8 cores
macOS: 26.5.2
Output device: built-in speakers, 2 channels, 48 kHz
Date: 2026-09-08

| Metric | Value |
|---|---|
| Sample rate | 48000 Hz |
| Buffer frame size | 512 |
| Device latency + safety offset (frames) | 0, see note |
| Total added latency (ms) | 10.7 |
| CPU use while playing (%) | not measured |

The device latency line reads zero because `kAudioDevicePropertyLatency` and
`kAudioDevicePropertySafetyOffset` could not be read from the aggregate's output
device, and the code falls back to zero rather than guessing. So 10.7 ms is what
Sonora itself adds, one 512 frame buffer at 48 kHz, and the true end to end
figure is that plus whatever the device contributes. Since the audible checks
below passed, the unread part is small enough not to matter here; it is worth
reading properly before the latency budget is quoted anywhere as a total.

## Verification checklist

| Check | Result |
|---|---|
| Two minutes of music, no dropouts | Pass |
| Video lip sync acceptable | Pass, judged on a music video with a face on screen |
| `kill -9` restores audio | Pass, audio continued uninterrupted and no Sonora aggregate device was left registered |
| Headphone unplug behaviour | Not tested, expected to break until Task 14 adds the device watcher |
| Bluetooth switch behaviour | Not tested, same |

## Gate decision

**Continue with the tap architecture.** The added latency is one buffer, 10.7 ms,
against a rough threshold of about 45 ms before audio lagging video becomes
noticeable. Lip sync was judged acceptable by ear on real video rather than
inferred from the number, and audio survived a hard kill with nothing left
behind in the audio system, which is the property the whole bypass design rests
on.

The DriverKit fallback stays in the roadmap as phase 5, for the cases the tap
cannot cover at all, rather than as a rescue for latency.

Two things this run deliberately did not answer, both belonging to Task 14:
output device changes, and CPU under sustained load.

## Task 14 verification

Run by hand on the machine described above, 2026-09-09.

| Check | Result |
|---|---|
| Menu shows Running | Pass |
| Preset change audible | Pass |
| Preset switching clean, no clicks | Pass |
| Bypass toggles correctly | Not tested separately |
| Settings survive relaunch | Pass, checked by hand 2026-09-14: the panel came back with the same settings |
| Headphone plug survives | Pass, audio continued and the equalizer stayed applied |
| Bluetooth switch survives | Not tested |
| `kill -9` restores audio | Pass, verified during the latency gate above |
| No distortion on Loudness at full volume | Not tested |
| CPU use | Not measured |

The headphone check was run after review found and fixed a real defect on that
path: the DSP chain was sized from the tap's channel count, always two, while
the render loop computed its frame count from the output buffer's. A mono
output, which is what a Bluetooth headset in HFP mode presents, made the chain
write past the end of the HAL's buffer on every callback, on the real-time
thread. The chain is now built for the output format and the render block
refuses a shape it was not built for.

Still open: Bluetooth specifically, sustained CPU, and Loudness at full volume.

## Release checklist, ad hoc build

Run by hand on the machine described above, 2026-09-11, against the packaged
ad hoc build installed to `/Applications`.

| Check | Result |
|---|---|
| Section 10 item 5: `tccutil reset SystemAudioCaptureRequests com.sonora.Sonora`, flow works from scratch | Pass, the panel read Running afterwards |

This is the measurement that decides distribution: ad hoc signing carries a code
identity the system will grant the audio permission to, so a release without a
paid Apple Developer membership can capture audio. It does not cover a clean
machine, only a cleared grant on this one.

Still open from section 10 before v0.1 is tagged: item 3, Bluetooth, and item 6,
preamp at maximum without clipping. Settings surviving a relaunch is also still
unverified.

## Sleep and wake

Added to the checklist because it was missing from it, and the gap cost a bug
that made the app unusable: waking the machine left Sonora spinning with the
menu bar icon unresponsive.

| Check | Result |
|---|---|
| Sleep the machine, wake it, open the panel from the icon | Not verified against the fix, see below |

Before the fix this failed every time, and two CPU diagnostics recorded it: 85
and 86 percent average CPU over a hundred seconds, with
`SystemVolume.refresh()` calling `removeListeners()` as the heaviest stack.
`AudioObjectRemovePropertyListenerBlock` reports success and removes nothing,
so the listeners piled up and one device notification ran `refresh()` once per
listener that had accumulated. See `Tools/listener-removal-spike`.

This row said Pass earlier on 2026-09-14 and that was wrong. The check was run
against the copy in `/Applications`, which was built on 2026-09-10 and carries
neither `AudioPropertyListener` nor `VolumeHUD`, so whatever it showed said
nothing about the fix. The mechanism is measured, in the spike above, and the
end to end check is waiting on a build that contains it.

Worth the minute it costs before any future check: confirm the binary under
test is the one being claimed.

```bash
nm -a /Applications/Sonora.app/Contents/MacOS/Sonora | grep -c AudioPropertyListener
```

## Settings round trip on disk

Measured 2026-09-14, separately from the check above, because the panel showing
the right values and the file being intact are two different claims.

Markers written into `settings.json` by hand, preamp 4.5 dB and 7.25 dB on the
32 Hz band, survived a launch and a clean quit unchanged, with the schema still
at 2. That covers the file. It does not cover loading: nothing writes unless
something changes, so an app that fell back to defaults would leave the same
file behind. The panel half is the hand check in the table.

## Volume keys and the overlay

Checked by hand 2026-09-14 against `0.1.1-keyfix` installed in
`/Applications`, after the event tap callback was moved out of the main actor's
isolation.

| Check | Result |
|---|---|
| The app survives having the tap running | Pass, same process alive 15 minutes with the `com.sonora.volume-key-tap` thread present and no new crash report |
| A volume key press is acted on | Pass |
| The overlay appears for it | Pass |

Before the fix the app died two seconds after every launch, without anyone
touching a volume key: the tap's mask is the whole `NX_SYSDEFINED` class, so
any event of that class entered the callback and the isolation check trapped
before decoding. See `Tools/event-tap-isolation-spike`.

Two things this cost, both worth remembering:

The overlay was reported missing when the copy in `/Applications` was three
builds old and had no overlay in it. Check what is installed before believing
what it does.

An ad hoc signed build gets a new code identity with every build, and TCC keys
Accessibility to that identity. The old row stays in System Settings looking
switched on while the system refuses the trust, so the app asks again and the
user sees a contradiction. `tccutil reset Accessibility com.sonora.Sonora`
clears it. A build signed with a developer identity would not have this
problem, which is a distribution question, not a bug.
