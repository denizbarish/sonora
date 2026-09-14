# Event tap isolation spike

Answers one question, after the app started dying a couple of seconds after
every launch: may a `CGEvent` tap callback be written as a closure inside a
`@MainActor` method, when the tap is served from a thread of its own?

It mattered because that is exactly what `VolumeKeyTap` did. Swift treats a
closure formed in an actor-isolated context as isolated to that actor, and when
such a closure is converted to a C function pointer it carries a runtime
isolation check at entry. While the tap lived on the main run loop the check
passed, for the wrong reason. Moving the tap to its own thread, which it needs
so a busy main thread cannot stall every application's media keys, turned that
check into a trap on the first event.

And it was the first event of any kind: the mask is the whole `NX_SYSDEFINED`
class, so the callback runs for events nobody pressed a volume key for, and the
check fails before any decoding happens. The app died seconds after launch with
no key press at all.

## Result: no, it must be a function at file scope

Measured 2026-09-14 on a MacBook Air (Mac14,2), Apple M2, macOS 26.5.2, each
variant in its own process because the failure takes the process with it.

| Callback written as | Outcome |
|---|---|
| A closure inside a `@MainActor` method | Killed by signal 5, `SIGTRAP` |
| A function at file scope | Exit 0, and the callback ran |

The second row reports whether the callback actually ran, because a variant
that survived by never being called would prove nothing.

This is the same trap the app hit. From `Sonora-2026-09-14-172813.ips`, on the
thread named `com.sonora.volume-key-tap`:

```
_dispatch_assert_queue_fail
dispatch_assert_queue
_swift_task_checkIsolatedSwift
swift_task_isCurrentExecutorWithFlagsImpl
specialized closure #1 in VolumeKeyTap.start()
...
CFRunLoopRun
TapThread.main()
```

## Running it

```bash
cd Tools/event-tap-isolation-spike
swiftc -swift-version 6 -strict-concurrency=complete -O main.swift -o event-tap-isolation-spike
./event-tap-isolation-spike
```

The process running it needs the Accessibility permission, since it creates a
real tap; a terminal that has it will do, and the spike says so rather than
reporting a pass when the tap could not be created at all. The tap is
`listenOnly` and the synthetic event is volume up, so the system still handles
it and nothing is left switched off.
