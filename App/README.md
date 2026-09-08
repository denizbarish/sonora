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

Process taps need a real signing identity. The system keys the audio permission
record to it, so an ad hoc build never sees the permission prompt at all.

Export your identity, then generate and build:

```bash
export SONORA_CODE_SIGN_IDENTITY="Apple Development: you@example.com (YOURTEAMID)"
cd App
xcodegen generate
xcodebuild -project Sonora.xcodeproj -scheme Sonora -configuration Debug build
```

Find the exact string with:

```bash
security find-identity -v -p codesigning
```

If you have no identity yet, open `Sonora.xcodeproj` in Xcode, select the
Sonora target, open Signing & Capabilities and pick your team. A free Apple ID
gives you a Personal Team, which is enough. Xcode issues the certificate the
first time it signs.

With the variable unset the project still builds, ad hoc, which is fine for
compiling and for running the interface but cannot capture audio.

Check what you got:

```bash
codesign -dv --verbose=4 /path/to/Sonora.app
```

`flags=0x10000(runtime)` and an `Authority=Apple Development: ...` line mean it
is signed properly. `flags=0x2(adhoc)` means it is not, and Xcode will have
turned Hardened Runtime off along the way.

### Why signing is manual here

Automatic signing makes Xcode validate the account behind `DEVELOPMENT_TEAM`
through its own account machinery. When `xcodebuild` cannot see that account it
fails with "No Account for Team", then quietly falls back to ad hoc and drops
Hardened Runtime, producing a binary that looks fine and can never obtain the
audio permission. Naming the identity directly avoids the whole path.

## Reset the audio permission

```bash
tccutil reset SystemAudioCaptureRequests com.sonora.Sonora
```
