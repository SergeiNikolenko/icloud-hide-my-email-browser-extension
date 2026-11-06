#!/bin/bash
# Publishes the version set in Resources/Info.plist: builds and signs the app,
# attaches HideMyEmail.dmg to a macos-v<version> release, and points the Sparkle
# feed (appcast.xml on the update-feed release) at it. Push main first.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=SergeiNikolenko/icloud-hide-my-email-browser-extension
plist() { /usr/libexec/PlistBuddy -c "Print $1" Resources/Info.plist; }
VERSION=$(plist CFBundleShortVersionString)
BUILD=$(plist CFBundleVersion)
TAG="macos-v$VERSION"

git fetch --quiet origin main
if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
  echo "HEAD is not origin/main; push the release commit first." >&2
  exit 1
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "$TAG already exists; bump CFBundleShortVersionString and CFBundleVersion." >&2
  exit 1
fi

# Sparkle's signing tool, the same version as the framework in Package.swift.
SPARKLE=build/sparkle
if [ ! -x "$SPARKLE/bin/sign_update" ]; then
  mkdir -p "$SPARKLE"
  curl --fail --location --proto '=https' --output "$SPARKLE/Sparkle.tar.xz" \
    https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz
  echo "c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c  $SPARKLE/Sparkle.tar.xz" | shasum -a 256 -c -
  tar -xf "$SPARKLE/Sparkle.tar.xz" -C "$SPARKLE"
fi

scripts/build-app.sh
scripts/make-dmg.sh
DMG=build/HideMyEmail.dmg

# The EdDSA private key lives in the login keychain as "Hide My Email Sparkle".
SIGNATURE=$(security find-generic-password -s "Hide My Email Sparkle" -a ed25519 -w |
  "$SPARKLE/bin/sign_update" --ed-key-file - -p "$DMG")

cat > build/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Hide My Email</title>
    <item>
      <title>Hide My Email $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <link>https://github.com/$REPO/releases/tag/$TAG</link>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(plist LSMinimumSystemVersion)</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/HideMyEmail.dmg"
                 length="$(stat -f %z "$DMG")" type="application/octet-stream"
                 sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
EOF

gh release create "$TAG" "$DMG" --repo "$REPO" --target main \
  --title "Hide My Email for macOS $VERSION" --generate-notes
if ! gh release view update-feed --repo "$REPO" >/dev/null 2>&1; then
  gh release create update-feed --repo "$REPO" --prerelease --latest=false --title "Update feed" \
    --notes "Metadata for automatic updates. Download the app from a versioned release."
fi
gh release upload update-feed build/appcast.xml --repo "$REPO" --clobber
echo "Released $TAG"
