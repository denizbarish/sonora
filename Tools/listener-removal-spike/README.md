# Listener removal spike

Answers one question, after a bug that only appeared on waking from sleep: when
Core Audio says it removed a property listener, is the listener gone?

It mattered because `SystemVolume` re-registered its listeners on every device
change, which is safe only if removal works. It does not, and the failure is
silent, so the listeners piled up: one device notification then ran `refresh()`
once per listener that had accumulated, and each of those runs added more. After
waking from sleep, which emits a burst of device notifications, Sonora spun at
86 percent CPU with the main actor permanently full, and the menu bar icon
stopped responding. Two CPU diagnostics caught it in the act, both with
`SystemVolume.refresh()` calling `removeListeners()` as the heaviest stack.

## Result: the block based removal does nothing, the function pointer one works

Measured 2026-09-14 on a MacBook Air (Mac14,2), Apple M2, macOS 26.5.2, against
the built-in output.

| Registration | Removal reported | Fires while registered | Fires after removal |
|---|---|---|---|
| `…ListenerBlock`, block passed straight back | `noErr` | 4 | 4 |
| `…ListenerBlock`, block held in a class property | `noErr` | 4 | 4 |
| `…ListenerBlock`, block held in a tuple array | `noErr` | 4 | 4 |
| `…PropertyListener`, C function and context | `noErr` | 4 | **0** |

Where the block was kept between the two calls makes no difference, so this is
not a storage mistake that a different shape would fix. A Swift closure is
bridged into a new block at each crossing of the C boundary, and the HAL matches
registrations by block pointer, so the pointer handed to the remove call never
matches the one the add call stored. It reports success and removes nothing.

The function pointer API identifies a registration by the pair of the C function
and the context pointer. Both cross unchanged, so removal removes. That is what
`AudioPropertyListener` uses.

Each phase runs in its own process, which the spike arranges by re-executing
itself once per phase. Sharing one process does not work: a leaked block
listener cannot be removed, so a later phase counts the earlier phases'
leftovers as its own. Run that way the counts climb phase by phase, 4, 4, 12,
16, which is the accumulation this bug rests on, seen from the outside.

The control column is why the phases are shaped this way: the function pointer
listener is delivered on a background thread rather than the main run loop, and
an early version of this spike ran no run loop at all, so it could not tell "the
removal worked" from "it never fired". Each phase now counts callbacks while the
listener is still registered before it counts any after.

## Running it

```bash
cd Tools/listener-removal-spike
swiftc -O main.swift -o listener-removal-spike
./listener-removal-spike
```

It nudges the system volume by 0.05 to provoke the notifications and puts it
back afterwards. A device that does not expose `kAudioDevicePropertyVolumeScalar`
on its main element cannot answer the question, and the spike stops rather than
reporting a zero that means nothing.
