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
STAGING=$(mktemp -d)
trap 'timeout 30 /usr/bin/trash "$STAGING"' EXIT
APP="$STAGING/Hide My Email.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp -f "$BIN_DIR/HideMyEmail" "$APP/Contents/MacOS/HideMyEmail"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/HideMyEmail"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp -f Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/en.lproj Resources/ru.lproj "$APP/Contents/Resources/"

if [ ! -f Resources/AppIcon.icns ]; then
  WORK="$STAGING/icon"
  mkdir -p "$WORK"
  swift scripts/make-icon.swift "$WORK"
  iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
fi
cp -f Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The Safari web extension that hands Safari's icloud.com session to the app.
APPEX="$APP/Contents/PlugIns/HideMyEmailSafari.appex"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources"
EXT_BUILD="$STAGING/extension"
mkdir -p "$EXT_BUILD"
for ARCH in arm64 x86_64; do
  xcrun swiftc -O -parse-as-library -application-extension -target "$ARCH-apple-macos26.0" \
    -Xlinker -e -Xlinker _NSExtensionMain SafariExtension/SafariWebExtensionHandler.swift \
    -o "$EXT_BUILD/$ARCH"
done
lipo -create "$EXT_BUILD/arm64" "$EXT_BUILD/x86_64" -output "$APPEX/Contents/MacOS/HideMyEmailSafari"
cp -f SafariExtension/Info.plist "$APPEX/Contents/Info.plist"
for KEY in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Set $KEY $(/usr/libexec/PlistBuddy -c "Print $KEY" Resources/Info.plist)" \
    "$APPEX/Contents/Info.plist"
done
cp -f SafariExtension/Resources/* "$APPEX/Contents/Resources/"
for SIZE in 48 96 128; do
  sips -s format png -Z "$SIZE" Resources/AppIcon.icns --out "$APPEX/Contents/Resources/icon-$SIZE.png" >/dev/null
done

xattr -cr "$APP"
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ { print $2; exit }')}
SIGN=(codesign --force --timestamp=none --sign "${IDENTITY:--}")
# Sign Sparkle's helpers from the inside out, then the framework and the app.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
find "$FRAMEWORK/Versions/B" -depth \( -name '*.xpc' -o -name '*.app' \) -print0 | xargs -0 -n1 "${SIGN[@]}"
"${SIGN[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
"${SIGN[@]}" "$FRAMEWORK"
"${SIGN[@]}" --entitlements SafariExtension/Extension.entitlements "$APPEX"
"${SIGN[@]}" --entitlements Resources/HideMyEmail.entitlements "$APP"
codesign --verify --deep --strict "$APP"
if [ -d "build/Hide My Email.app" ]; then
  timeout 30 /usr/bin/trash "build/Hide My Email.app"
fi
mkdir -p build
ditto --norsrc --noextattr --noqtn "$APP" "build/Hide My Email.app"
# File-provider folders may add Finder metadata after the staging signature.
xattr -dr com.apple.FinderInfo "build/Hide My Email.app"
codesign --verify --deep --strict "build/Hide My Email.app"
echo "Built build/Hide My Email.app"
