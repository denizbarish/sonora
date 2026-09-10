# Volume key spike

Answers one question before anything is built on top of it: can a `CGEvent` tap
see the volume keys, and can it swallow them?

It mattered because media keys such as play and pause have long been
interceptable this way, while the volume keys are frequently consumed by the
system before any tap sees them, and the behaviour has changed across macOS
releases. Building a settings toggle and an onboarding flow on an assumption
here would have been expensive to undo.

## Result: yes to both

Measured 2026-09-10 on a MacBook Air (Mac14,2), Apple M2, macOS 26.5.2, using
the built-in keyboard.

| Question | Answer |
|---|---|
| Can the tap be created? | Yes, once the running process is trusted for Accessibility |
| Is volume up seen? | Yes |
| Is volume down seen? | Yes |
| Is mute seen? | Yes |
| Does returning nil swallow them? | Yes, the system volume did not change |
| Does the system's volume overlay still appear? | No |

So Sonora can take the volume keys over completely: it receives the press, and
the system neither changes the volume nor draws its own overlay. That is what
makes it possible to show Sonora's panel in place of the system HUD rather than
alongside it.

## Caveats worth carrying forward

- Only tested with the built-in keyboard on one machine. External keyboards send
  the same `NSSystemDefined` events in principle, but that is not measured.
- The tap needs the Accessibility permission. Without it `tapCreate` returns
  nil, which is the failure the production code has to handle rather than
  assume away.
- macOS disables a tap that takes too long in its callback, or when input is
  interrupted. The production tap has to re-enable itself on
  `tapDisabledByTimeout` and `tapDisabledByUserInput`.
- `CGEventType` has no case for system defined events, so the mask is built from
  the raw `NX_SYSDEFINED` value, 14.

## Running it

```bash
cd Tools/volume-key-spike
swiftc -o volume-key-spike main.swift
./volume-key-spike
```

Run it from a terminal that is trusted under System Settings, Privacy and
Security, Accessibility, then press the keys. It listens for 30 seconds and
swallows only the volume keys, so the machine stays usable.
