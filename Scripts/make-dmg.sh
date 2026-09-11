#!/bin/bash
# Builds Sonora and wraps it in a disk image.
#
# The app is ad hoc signed unless SONORA_CODE_SIGN_IDENTITY names a real
# identity. Ad hoc is enough for the audio permission, which macOS keys to the
# binary's hash rather than to a developer identity, but it is not enough for
# Gatekeeper: whoever downloads this has to right-click and choose Open once.
#
# Everything between the build and hdiutil is a gate. Each one fails the script
# rather than warning, because the alternative is a release that ships wrong
# and only gets noticed by whoever downloads it.
set -euo pipefail

VERSION="${1:?usage: make-dmg.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/dmg"
DMG="$ROOT/Sonora-$VERSION.dmg"

fail() {
  echo "gate failed: $*" >&2
  exit 1
}

rm -rf "$BUILD"
mkdir -p "$BUILD/staging"

cd "$ROOT/App"
xcodegen generate

# -destination 'generic/platform=macOS' asks for an architecture-neutral build.
# Without it xcodebuild resolves its own default concrete destination,
# { platform:macOS, arch:arm64 } on an Apple silicon machine, and narrows ARCHS
# to that single arch, so the image ships an Apple silicon only app even though
# the project asks for a universal one.
#
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO stops Xcode from adding
# com.apple.security.get-task-allow to the signature. Development signing
# injects it by default, and it removes Hardened Runtime's protection against
# code injection: any process running as the same user could then attach to
# Sonora, which holds the system audio capture permission. It also makes the
# app ineligible for notarisation. The override lives here rather than in
# project.yml because it is a packaging concern, not a build one.
#
# MARKETING_VERSION is overridden because project.yml pins it while the image
# is named after the tag. Without this a v0.2.0 tag produces Sonora-0.2.0.dmg
# containing an app that reports 0.1.0.
xcodebuild \
  -project Sonora.xcodeproj \
  -scheme Sonora \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD/derived" \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build

APP="$BUILD/derived/Build/Products/Release/Sonora.app"
[ -d "$APP" ] || fail "no app at $APP"

PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || fail "no Info.plist at $PLIST"

echo "== checking what we are about to ship =="

# The signature has to be intact. `codesign --verify --strict` walks the whole
# bundle and rejects anything the seal does not cover.
codesign --verify --strict "$APP" || fail "the signature does not verify"
echo "signature: verifies under --strict"

# Hardened Runtime shows up as the `runtime` flag on the code directory.
# project.yml sets ENABLE_HARDENED_RUNTIME, but a signing fallback can quietly
# drop it, so read it back off the thing we built. Only the CodeDirectory line
# counts: the later "Executable Segment flags=0x1" line is unrelated.
SIGN_FLAGS="$(codesign -d --verbose=4 "$APP" 2>&1 \
  | sed -n 's/^CodeDirectory .*\(flags=[^ ]*\).*/\1/p')"
echo "signature flags: ${SIGN_FLAGS:-none reported}"
case "$SIGN_FLAGS" in
  *runtime*) ;;
  *) fail "the signature does not report Hardened Runtime (flags: ${SIGN_FLAGS:-none reported})" ;;
esac

# get-task-allow must be absent. See the xcodebuild comment above for why.
ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null)"
if printf '%s' "$ENTITLEMENTS" | grep -q 'com.apple.security.get-task-allow'; then
  fail "the app carries com.apple.security.get-task-allow"
fi
echo "entitlements: no get-task-allow"

# Universal, because the README promises Intel Macs.
EXECUTABLE="$(plutil -extract CFBundleExecutable raw "$PLIST")"
[ -n "$EXECUTABLE" ] || fail "Info.plist has no CFBundleExecutable"
BINARY="$APP/Contents/MacOS/$EXECUTABLE"
[ -f "$BINARY" ] || fail "no executable at $BINARY"
FOUND_ARCHS="$(lipo -archs "$BINARY")"
echo "architectures: $FOUND_ARCHS"
for arch in arm64 x86_64; do
  case " $FOUND_ARCHS " in
    *" $arch "*) ;;
    *) fail "the binary is missing $arch (has: $FOUND_ARCHS)" ;;
  esac
done

# NSAudioCaptureUsageDescription is the key the whole audio permission depends
# on, and XcodeGen drops it whenever it is allowed to generate Info.plist (see
# the comment in App/project.yml). CI runs xcodegen generate on every release,
# so verify the key survived into the bundle we are shipping.
USAGE="$(plutil -extract NSAudioCaptureUsageDescription raw "$PLIST")" \
  || fail "Info.plist has no NSAudioCaptureUsageDescription"
[ -n "$USAGE" ] || fail "NSAudioCaptureUsageDescription is empty"
echo "NSAudioCaptureUsageDescription: present (${#USAGE} characters)"

# The app's own version has to match the name of the image around it.
BUNDLE_VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST")"
echo "CFBundleShortVersionString: $BUNDLE_VERSION"
[ "$BUNDLE_VERSION" = "$VERSION" ] \
  || fail "the app reports $BUNDLE_VERSION but the image is named $VERSION"

cp -R "$APP" "$BUILD/staging/"
ln -s /Applications "$BUILD/staging/Applications"

hdiutil create \
  -volname "Sonora" \
  -srcfolder "$BUILD/staging" \
  -ov -format UDZO \
  "$DMG"

# An image that builds is not an image that contains an app. Mount it and look.
# The mountpoint goes in the system temp dir rather than under .build, because
# macOS refuses to mount onto a path inside a non-boot volume and a checkout
# can live on an external disk.
MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/sonora-dmg-check.XXXXXX")"
hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT" >/dev/null
MOUNTED_APP=0
if [ -d "$MOUNT/Sonora.app" ]; then
  MOUNTED_APP=1
fi
# Detach before reacting to the result, so a failed check does not leave the
# image mounted behind it.
hdiutil detach "$MOUNT" >/dev/null
rmdir "$MOUNT" 2>/dev/null || true
[ "$MOUNTED_APP" -eq 1 ] || fail "the image does not contain Sonora.app"
echo "image contents: Sonora.app is inside"

echo "== wrote Sonora-$VERSION.dmg =="
shasum -a 256 "$DMG"
