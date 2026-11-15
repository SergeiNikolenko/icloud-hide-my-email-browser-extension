#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=false
VERIFY=false
for ARG in "$@"; do
  case "$ARG" in
    --install) INSTALL=true ;;
    --verify) VERIFY=true ;;
    *) echo "Usage: $0 [--install] [--verify]" >&2; exit 2 ;;
  esac
done

./macos/scripts/build-app.sh
APP="$PWD/macos/build/Hide My Email.app"
pkill -x HideMyEmail || true
if $INSTALL; then
  if [ -d "/Applications/Hide My Email.app" ]; then
    timeout 30 /usr/bin/trash "/Applications/Hide My Email.app"
  fi
  ditto --norsrc --noextattr --noqtn "$APP" "/Applications/Hide My Email.app"
  # Register only the installed copy, not the staging copy of its extension.
  pluginkit -r "$APP/Contents/PlugIns/HideMyEmailSafari.appex" || true
  APP="/Applications/Hide My Email.app"
fi
xattr -dr com.apple.FinderInfo "$APP"
codesign --verify --deep --strict "$APP"
pluginkit -a "$APP/Contents/PlugIns/HideMyEmailSafari.appex"
/usr/bin/open -g "$APP"
if $VERIFY; then
  sleep 2
  pgrep -x HideMyEmail >/dev/null
  echo "Hide My Email is running."
fi
