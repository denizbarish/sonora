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
| Settings survive relaunch | Not tested |
| Headphone plug survives | Not tested |
| Bluetooth switch survives | Not tested |
| `kill -9` restores audio | Pass, verified during the latency gate above |
| No distortion on Loudness at full volume | Not tested |
| CPU use | Not measured |

The device change checks are the ones still open, and they are the reason the
device watcher exists: an aggregate device built around a device that has gone
away stops passing audio with no error at all. Until they are run, that path is
written but unproven.
