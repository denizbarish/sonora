#!/bin/bash
# Builds Sonora and wraps it in a disk image.
#
# The app is ad hoc signed unless SONORA_CODE_SIGN_IDENTITY names a real
# identity. Ad hoc is enough for the audio permission, which macOS keys to the
# binary's hash rather than to a developer identity, but it is not enough for
# Gatekeeper: whoever downloads this has to right-click and choose Open once.
set -euo pipefail

VERSION="${1:?usage: make-dmg.sh <version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build/dmg"

rm -rf "$BUILD"
mkdir -p "$BUILD/staging"

cd "$ROOT/App"
xcodegen generate
xcodebuild \
  -project Sonora.xcodeproj \
  -scheme Sonora \
  -configuration Release \
  -derivedDataPath "$BUILD/derived" \
  build

APP="$BUILD/derived/Build/Products/Release/Sonora.app"
[ -d "$APP" ] || { echo "no app at $APP" >&2; exit 1; }

echo "== signature =="
codesign -dv --verbose=4 "$APP" 2>&1 | grep -E 'flags|Authority=' || true

cp -R "$APP" "$BUILD/staging/"
ln -s /Applications "$BUILD/staging/Applications"

hdiutil create \
  -volname "Sonora" \
  -srcfolder "$BUILD/staging" \
  -ov -format UDZO \
  "$ROOT/Sonora-$VERSION.dmg"

echo "== wrote Sonora-$VERSION.dmg =="
shasum -a 256 "$ROOT/Sonora-$VERSION.dmg"
