#!/bin/bash
# Builds "Hide My Email.app" into macos/build and signs it with the first
# Apple Development identity, so the Accessibility permission survives rebuilds
# and updates.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64
BIN_DIR=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
# Assemble and sign outside the project: synced folders such as ~/Documents add
# Finder attributes that codesign rejects.
APP="$(mktemp -d)/Hide My Email.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp -f "$BIN_DIR/HideMyEmail" "$APP/Contents/MacOS/HideMyEmail"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/HideMyEmail"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
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
SIGN=(codesign --force --timestamp=none --sign "${IDENTITY:--}")
# Sign Sparkle's helpers from the inside out, then the framework and the app.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
find "$FRAMEWORK/Versions/B" -depth \( -name '*.xpc' -o -name '*.app' \) -print0 | xargs -0 -n1 "${SIGN[@]}"
"${SIGN[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
"${SIGN[@]}" "$FRAMEWORK"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
rm -rf "build/Hide My Email.app"
mkdir -p build
ditto "$APP" "build/Hide My Email.app"
echo "Built build/Hide My Email.app"
