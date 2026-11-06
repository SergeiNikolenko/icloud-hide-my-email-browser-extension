#!/bin/bash
# Packages build/Hide My Email.app into build/HideMyEmail.dmg with an
# Applications link for drag-to-install. Run scripts/build-app.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Hide My Email.app"
DMG="build/HideMyEmail.dmg"
STAGE=$(mktemp -d)

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Hide My Email" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"

IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ { print $2; exit }')}
codesign --force --timestamp=none --sign "${IDENTITY:--}" "$DMG"
echo "Built $DMG"
