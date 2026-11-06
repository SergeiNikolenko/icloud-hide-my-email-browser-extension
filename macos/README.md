# Hide My Email for macOS

A menu bar app that brings iCloud Hide My Email to every browser and app on the
Mac (Zen, Firefox, Arc, Chrome, the Codex browser and anything else with text
fields). Safari is left alone because it has Hide My Email built in.

- **Suggestions in email fields.** When an email field gets focus in any app,
  a Liquid Glass panel appears under it with a fresh address for the site and
  the addresses you already use there. Click one to fill the field. Sign-in
  forms are left to Passwords, and the panel moves above the field when
  Passwords or the browser open their own AutoFill list under it.
- **Create and fill shortcut.** Press ⌃⌥E (configurable) to create an address
  labelled after the current site and type it into the focused field, or copy
  it when nothing editable has focus.
- **Menu bar.** Generate, label and reserve addresses, see the ones for the
  current site, search everything, copy or paste into the app you came from.
- **Addresses window.** Every address on the account, including ones made in
  Safari, on iCloud.com or on other devices. Sidebar filters (active, inactive,
  per site), sortable table, inspector with label and note editing, bulk
  deactivate, reactivate and delete, export to CSV or JSON. Each site shows its
  own icon, fetched from the site and cached locally.
- **Sign-in through your browser.** "Sign In to iCloud" opens icloud.com in
  Safari (or another browser from the menu); the app picks up the session as
  soon as you are signed in, so passkeys and two-factor authentication work as
  usual. Sessions already open in Safari, Zen or Firefox are found
  automatically. Arc, Chrome, Brave, Edge and Vivaldi work too after one
  Keychain prompt, and Safari needs Full Disk Access. The app keeps its own copy
  in the Keychain, refreshes it every 20 minutes and takes the session from the
  browser again when it expires. iCloud China accounts are supported.

## Install

Download `HideMyEmail.dmg` from the
[latest release](https://github.com/SergeiNikolenko/icloud-hide-my-email-browser-extension/releases/latest)
and drag the app to Applications. It runs on macOS 26 or later, on Apple
silicon and Intel.

The app is not notarized yet, so macOS blocks the first launch. Open it once,
then choose **Open Anyway** in System Settings → Privacy & Security. After that,
allow Accessibility when the app asks, and Full Disk Access if you sign in
through Safari.

## Build

Requires macOS 26 or later and Xcode 26 or later.

```sh
./scripts/build-app.sh          # builds and signs build/Hide My Email.app
./scripts/make-dmg.sh           # packages it into build/HideMyEmail.dmg
swift test                      # core tests
```

The app needs Accessibility access to read focused fields and to type
addresses. It never reads passwords: secure text fields are ignored.
