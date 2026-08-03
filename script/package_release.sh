#!/usr/bin/env bash
set -euo pipefail

APP_NAME="OasesCPA"
DISPLAY_NAME="Oases CPA"
BUNDLE_ID="dev.oases.cpa.macos"
MIN_SYSTEM_VERSION="14.0"
APP_VERSION="${APP_VERSION:-0.1.0}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
NOTARIZE="${NOTARIZE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_APP_BUILD="$(/usr/bin/awk -F '"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$ROOT_DIR/project.yml")"
APP_BUILD="${APP_BUILD:-${DEFAULT_APP_BUILD:-1}}"
VOLUME_NAME="$DISPLAY_NAME $APP_BUILD"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_ROOT="$DIST_DIR/release"
RELEASE_DIR="$RELEASE_ROOT/${APP_VERSION}-${APP_BUILD}"
APP_BUNDLE="$RELEASE_DIR/$DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$DISPLAY_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
DMG_BACKGROUND_SOURCE="$ROOT_DIR/Resources/DMG/installer-background.svg"
ZIP_PATH="$RELEASE_DIR/OasesCPA.zip"
DMG_PATH="$RELEASE_DIR/OasesCPA.dmg"
CHECKSUM_PATH="$RELEASE_DIR/SHA256SUMS.txt"

die() {
  echo "Error: $*" >&2
  exit 2
}

if [[ ! "$APP_VERSION" =~ ^[0-9A-Za-z._-]+$ ]]; then
  die "APP_VERSION may contain only letters, numbers, '.', '_' and '-'."
fi
if [[ ! "$APP_BUILD" =~ ^[0-9A-Za-z._-]+$ ]]; then
  die "APP_BUILD may contain only letters, numbers, '.', '_' and '-'."
fi
if [[ "$NOTARIZE" != "0" && "$NOTARIZE" != "1" ]]; then
  die "NOTARIZE must be 0 or 1."
fi
if [[ "$NOTARIZE" == "1" && -z "$CODESIGN_IDENTITY" ]]; then
  die "NOTARIZE=1 requires a Developer ID Application CODESIGN_IDENTITY."
fi
if [[ ! -x /usr/bin/hdiutil || ! -x /usr/bin/codesign || ! -x /usr/bin/ditto || ! -x /usr/bin/sips || ! -x /usr/bin/osascript ]]; then
  die "This packaging script must run on macOS with hdiutil, codesign, ditto, sips and osascript."
fi
if [[ -e "$RELEASE_DIR" ]]; then
  die "Refusing to overwrite existing release directory: $RELEASE_DIR"
fi

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/oases-cpa-package.XXXXXX")"
TEMP_DMG="$TEMP_ROOT/$APP_NAME-rw.dmg"
MOUNT_POINT=""
cleanup() {
  if [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

cd "$ROOT_DIR"
XCODE_DERIVED="$TEMP_ROOT/xcode-derived"
/usr/bin/xcodebuild \
  -project "$ROOT_DIR/OasesCPA.xcodeproj" \
  -scheme "Oases CPA" \
  -configuration Release \
  -derivedDataPath "$XCODE_DERIVED" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$APP_VERSION" \
  CURRENT_PROJECT_VERSION="$APP_BUILD" \
  CODE_SIGNING_ALLOWED=NO \
  build

BUILT_APP="$XCODE_DERIVED/Build/Products/Release/$DISPLAY_NAME.app"
[[ -d "$BUILT_APP" ]] || die "Xcode build did not produce: $BUILT_APP"
mkdir -p "$RELEASE_DIR"
/usr/bin/ditto "$BUILT_APP" "$APP_BUNDLE"
[[ -x "$APP_BINARY" ]] || die "Built app executable is missing: $APP_BINARY"

if [[ -n "$CODESIGN_IDENTITY" ]]; then
  /usr/bin/codesign \
    --force \
    --options runtime \
    --timestamp \
    --sign "$CODESIGN_IDENTITY" \
    "$APP_BUNDLE"
  SIGNING_DESCRIPTION="signed with $CODESIGN_IDENTITY"
else
  /usr/bin/codesign --force --sign - "$APP_BUNDLE"
  SIGNING_DESCRIPTION="ad hoc signed (local validation only; not notarizable)"
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

make_dmg() {
 local background_png="$TEMP_ROOT/installer-background.png"
 local staging="$TEMP_ROOT/staging"
 local volume_path
  local finder_pid
  local finder_layout_finished=0

  rm -rf "$staging"
  mkdir -p "$staging/.background"
  /usr/bin/ditto "$APP_BUNDLE" "$staging/$DISPLAY_NAME.app"
  ln -s /Applications "$staging/Applications"

  if [[ ! -f "$DMG_BACKGROUND_SOURCE" ]]; then
    die "Missing DMG background asset: $DMG_BACKGROUND_SOURCE"
  fi
  /usr/bin/sips -s format png "$DMG_BACKGROUND_SOURCE" --out "$background_png" >/dev/null
  cp "$background_png" "$staging/.background/background.png"

  /usr/bin/hdiutil create \
    -size 160m \
    -fs HFS+ \
    -volname "$VOLUME_NAME" \
    -ov \
    "$TEMP_DMG" >/dev/null
  MOUNT_POINT="$(/usr/bin/hdiutil attach "$TEMP_DMG" -nobrowse -noautoopen | /usr/bin/awk '/Apple_HFS/ {print substr($0, index($0, "/Volumes/"))}' | tail -n 1)"
  [[ -n "$MOUNT_POINT" && -d "$MOUNT_POINT" ]] || die "Unable to mount temporary DMG."

  /usr/bin/ditto "$staging" "$MOUNT_POINT"
  /usr/bin/chflags hidden "$MOUNT_POINT/.background"
  # Finder layout is cosmetic. Do not let an unavailable Finder automation
  # session block the signed DMG that contains the actual install payload.
  /usr/bin/osascript >/dev/null 2>&1 <<APPLESCRIPT &
tell application "Finder"
 tell disk "$VOLUME_NAME"
    with timeout of 8 seconds
   open
   set current view of container window to icon view
   set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 100, 1320, 860}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 112
    set text size of theViewOptions to 14
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "$DISPLAY_NAME.app" of container window to {330, 370}
    set position of item "Applications" of container window to {930, 370}
   close
   open
   update without registering applications
   delay 1
    end timeout
 end tell
end tell
APPLESCRIPT
  finder_pid=$!
  for _ in {1..20}; do
    if ! kill -0 "$finder_pid" >/dev/null 2>&1; then
      wait "$finder_pid" || true
      finder_layout_finished=1
      break
    fi
    sleep 0.5
  done
  if [[ "$finder_layout_finished" -eq 0 ]]; then
    echo "Warning: Finder layout automation timed out; the DMG still contains the App, Applications link and install background." >&2
    kill -TERM "$finder_pid" >/dev/null 2>&1 || true
    wait "$finder_pid" || true
  fi
  if [[ ! -f "$MOUNT_POINT/.DS_Store" ]]; then
    die "Finder did not persist the DMG background and icon layout."
  fi
  /bin/sync
  /usr/bin/hdiutil detach "$MOUNT_POINT" >/dev/null
  MOUNT_POINT=""
  /usr/bin/hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$DMG_PATH" >/dev/null
}

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
make_dmg

if [[ "$NOTARIZE" == "1" ]]; then
  if [[ -n "$NOTARY_PROFILE" ]]; then
    /usr/bin/xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  elif [[ -n "$NOTARY_APPLE_ID" && -n "$NOTARY_TEAM_ID" && -n "$NOTARY_PASSWORD" ]]; then
    /usr/bin/xcrun notarytool submit "$ZIP_PATH" \
      --apple-id "$NOTARY_APPLE_ID" \
      --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" \
      --wait
  else
    die "Set NOTARY_PROFILE, or NOTARY_APPLE_ID/NOTARY_TEAM_ID/NOTARY_PASSWORD, for notarization."
  fi

  /usr/bin/xcrun stapler staple -v "$APP_BUNDLE"
  rm -f "$ZIP_PATH" "$DMG_PATH"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
  make_dmg
  /usr/bin/xcrun stapler staple -v "$DMG_PATH"
  /usr/bin/xcrun stapler validate -v "$APP_BUNDLE"
  /usr/bin/xcrun stapler validate -v "$DMG_PATH"
fi

(
  cd "$RELEASE_DIR"
  /usr/bin/shasum -a 256 "$(basename "$ZIP_PATH")" > "$CHECKSUM_PATH"
  /usr/bin/shasum -a 256 "$(basename "$DMG_PATH")" >> "$CHECKSUM_PATH"
)

echo "Release app: $APP_BUNDLE"
echo "ZIP: $ZIP_PATH"
echo "DMG: $DMG_PATH"
echo "SHA-256: $CHECKSUM_PATH"
echo "Version: $APP_VERSION ($APP_BUILD)"
echo "Signing: $SIGNING_DESCRIPTION"
if [[ "$NOTARIZE" == "1" ]]; then
  echo "Notarization: submitted and stapled"
fi
