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

Process taps need a real signing identity: the system keys the audio permission
record to it, so an ad hoc build never gets the permission prompt at all, and
Xcode silently turns Hardened Runtime off when it falls back to ad hoc.

Set your team once, then generate and build:

```bash
export SONORA_DEVELOPMENT_TEAM=YOURTEAMID
cd App
xcodegen generate
xcodebuild -project Sonora.xcodeproj -scheme Sonora -configuration Debug build
```

To find your team id, open `Sonora.xcodeproj` in Xcode, select the Sonora
target, open Signing & Capabilities and pick your team. A free Apple ID gives
you a Personal Team, which is enough for development. Xcode issues the
certificate the first time it signs, after which:

```bash
security find-identity -v -p codesigning
```

lists it as `Apple Development: you@example.com (YOURTEAMID)`.

With the variable unset the project still builds, ad hoc, which is fine for
compiling but cannot capture audio.

## Reset the audio permission

```bash
tccutil reset SystemAudioCaptureRequests com.sonora.Sonora
```
