#!/bin/bash
# Downloads the official llama.cpp universal macOS XCFramework slice (arm64 + x86_64)
# into macos/Frameworks/llama.xcframework and verifies its SHA-256 checksum.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="b12633"
SHA256="d0b199082096fc63c875ef55c4675de09b3d42fa25a0b8d2dba736938c9c9bc6"
URL="https://github.com/ggml-org/llama.cpp/releases/download/$VERSION/llama-$VERSION-xcframework.zip"
DEST="Frameworks/llama.xcframework"
STAMP="$DEST/.version"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$VERSION" ] && [ -f "$DEST/macos-arm64_x86_64/llama.framework/Versions/A/llama" ]; then
  exit 0
fi

CACHE_DIR="${TMPDIR:-/tmp}/hidemyemail-llama-cache"
ZIP="$CACHE_DIR/llama-$VERSION-xcframework.zip"
mkdir -p "$CACHE_DIR"

if [ ! -f "$ZIP" ]; then
  if [ -f "/tmp/llama-xcfw-check/llama-$VERSION-xcframework.zip" ]; then
    cp "/tmp/llama-xcfw-check/llama-$VERSION-xcframework.zip" "$ZIP"
  else
    echo "Downloading llama.cpp $VERSION XCFramework..."
    curl -fL --progress-bar -o "$ZIP.part" "$URL"
    mv "$ZIP.part" "$ZIP"
  fi
fi

ACTUAL=$(shasum -a 256 "$ZIP" | awk '{print $1}')
if [ "$ACTUAL" != "$SHA256" ]; then
  echo "Checksum mismatch for $ZIP: expected $SHA256, got $ACTUAL" >&2
  /usr/bin/trash "$ZIP" 2>/dev/null || true
  exit 1
fi

STAGING=$(mktemp -d)
trap '/usr/bin/trash "$STAGING" 2>/dev/null || true' EXIT
unzip -q "$ZIP" "build-apple/llama.xcframework/macos-arm64_x86_64/llama.framework/*" -d "$STAGING"

if [ -d "$DEST" ]; then
  /usr/bin/trash "$DEST"
fi
mkdir -p "$DEST/macos-arm64_x86_64"
ditto "$STAGING/build-apple/llama.xcframework/macos-arm64_x86_64/llama.framework" "$DEST/macos-arm64_x86_64/llama.framework"

cat << 'PLIST' > "$DEST/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>llama.framework/Versions/A/llama</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64_x86_64</string>
			<key>LibraryPath</key>
			<string>llama.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST

echo "$VERSION" > "$STAMP"
echo "Installed $DEST ($VERSION)"
