#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="OasesCPA"
# Bundle identifier of this unsigned development build (override with OASES_BUNDLE_ID).
# The generated Info.plist leaves the update channel and author empty: no updater.
BUNDLE_ID="${OASES_BUNDLE_ID:-com.example.cpa.macos}"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/Oases CPA.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/Sources/OasesCPA/Resources/OasesCPA.icns"

if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "OASES_BUNDLE_ID must be a reverse-DNS bundle identifier." >&2
  exit 2
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
swift build --product "$APP_NAME"
BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"
BUILD_RESOURCES="$(swift build --show-bin-path)/OasesCPA_OasesCPA.bundle"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [[ -d "$BUILD_RESOURCES" ]]; then
  cp -R "$BUILD_RESOURCES" "$APP_RESOURCES/"
  for localization_dir in "$BUILD_RESOURCES"/*.lproj; do
    [[ -d "$localization_dir" ]] || continue
    cp -R "$localization_dir" "$APP_RESOURCES/"
  done
fi
if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$APP_RESOURCES/OasesCPA.icns"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>Oases CPA</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>OasesCPA</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Oases CPA</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>OasesAuthorName</key>
  <string></string>
  <key>OasesAuthorURL</key>
  <string></string>
  <key>OasesPrivacyPolicyURL</key>
  <string></string>
  <key>OasesUpdateRepository</key>
  <string></string>
  <key>OasesUpdateTeamIdentifier</key>
  <string></string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    echo "Oases CPA is running (pid $(pgrep -x "$APP_NAME" | head -n 1))"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
