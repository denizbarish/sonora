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

Open `Sonora.xcodeproj` in Xcode and press Run. Running from Xcode with a real
team selected is required: process taps need a signed binary, and the permission
prompt never appears for an unsigned build.

## Reset the audio permission

```bash
tccutil reset SystemAudioCaptureRequests com.sonora.Sonora
```
