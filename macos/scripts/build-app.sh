#!/bin/bash
# Builds "Hide My Email.app" into macos/build and signs it with the first
# Apple Development identity, so the Accessibility permission survives rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN_DIR=$(swift build -c release --arch arm64 --show-bin-path)
APP="build/Hide My Email.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -f "$BIN_DIR/HideMyEmail" "$APP/Contents/MacOS/HideMyEmail"
cp -f Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/en.lproj Resources/ru.lproj "$APP/Contents/Resources/"

if [ ! -f Resources/AppIcon.icns ]; then
  WORK=$(mktemp -d)
  swift scripts/make-icon.swift "$WORK"
  iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
fi
cp -f Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

xattr -cr "$APP"
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ { print $2; exit }')}
codesign --force --timestamp=none --sign "${IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
