#!/bin/zsh
# Build and package PerAppVolume.app (release).
#
# Signing identity matters: the Screen Recording grant (TCC) is keyed to the
# code signature. An ad-hoc signature (codesign --sign -) changes its cdhash on
# every rebuild, so macOS treats each build as a different app and the grant is
# lost. Sign with the stable self-signed "PerAppVolume Dev" identity when
# present so the grant survives rebuilds and no real identity is exposed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release

APP="$ROOT/dist/PerAppVolume.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/PerAppVolume" "$APP/Contents/MacOS/"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"
# Package the pre-built icon (scripts/AppIcon.icns).
if [[ -f "$ROOT/scripts/AppIcon.icns" ]]; then
    cp "$ROOT/scripts/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# Remove AppleDouble leftovers that can interfere with signing.
find "$APP" -name "._*" -delete

# Pick a signing identity: the self-signed "PerAppVolume Dev" is preferred so
# the signed app does not expose a real developer identity.
IDENTITY=""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "PerAppVolume Dev"; then
    IDENTITY="PerAppVolume Dev"
fi

if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Built: $APP (signed as $IDENTITY)"
else
    codesign --force --sign - "$APP"
    echo "Built: $APP (ad-hoc signature; the Screen Recording grant will be lost on rebuild)"
fi
