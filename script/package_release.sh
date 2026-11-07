#!/usr/bin/env bash
set -euo pipefail

# Build identity comes from the environment, never from this file:
#   OASES_BUNDLE_ID  bundle identifier of the release (default com.example.cpa.macos)
#   OASES_TEAM_ID    Apple team identifier; required for an official release and for
#                    --render-export-options, and it must match CODESIGN_IDENTITY's team.
VALIDATE_POLICY_ONLY=0
RENDER_EXPORT_OPTIONS=""
case "${1:-}" in
  "")
    ;;
  --validate-policy)
    VALIDATE_POLICY_ONLY=1
    shift
    ;;
  --render-export-options)
    if [[ "$#" -lt 2 || -z "${2:-}" ]]; then
      echo "Error: --render-export-options needs an output path." >&2
      exit 2
    fi
    RENDER_EXPORT_OPTIONS="$2"
    shift 2
    ;;
  *)
    echo "Error: unknown option: ${1}" >&2
    exit 2
    ;;
esac
if [[ "$#" -ne 0 ]]; then
  echo "Error: unexpected positional arguments." >&2
  exit 2
fi

APP_NAME="OasesCPA"
DISPLAY_NAME="Oases CPA"
BUNDLE_ID="${OASES_BUNDLE_ID:-com.example.cpa.macos}"
TEAM_ID="${OASES_TEAM_ID:-}"
MIN_SYSTEM_VERSION="14.0"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
NOTARIZE="${NOTARIZE:-0}"
ALLOW_UNTRUSTED_LOCAL_RELEASE="${ALLOW_UNTRUSTED_LOCAL_RELEASE:-0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-}"
NOTARY_TEAM_ID="${NOTARY_TEAM_ID:-}"
NOTARY_PASSWORD="${NOTARY_PASSWORD:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_APP_VERSION="$(/usr/bin/awk -F '"' '/MARKETING_VERSION:/ { print $2; exit }' "$ROOT_DIR/project.yml")"
DEFAULT_APP_BUILD="$(/usr/bin/awk -F '"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$ROOT_DIR/project.yml")"
APP_VERSION="${APP_VERSION:-${DEFAULT_APP_VERSION:-0.1.0}}"
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
if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  die "OASES_BUNDLE_ID must be a reverse-DNS bundle identifier."
fi
if [[ -n "$TEAM_ID" && ! "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  die "OASES_TEAM_ID must be ten upper-case letters or digits."
fi

# Writes an ExportOptions.plist for an App Store archive export from the committed
# template. The output (for example script/ExportOptions.plist) is git-ignored and an
# existing file is never overwritten.
if [[ -n "$RENDER_EXPORT_OPTIONS" ]]; then
  EXPORT_TEMPLATE="$ROOT_DIR/script/ExportOptions.plist.example"
  [[ -n "$TEAM_ID" ]] || die "--render-export-options requires OASES_TEAM_ID."
  [[ -f "$EXPORT_TEMPLATE" ]] || die "Missing template: script/ExportOptions.plist.example"
  if [[ -e "$RENDER_EXPORT_OPTIONS" || -L "$RENDER_EXPORT_OPTIONS" ]]; then
    die "Refusing to overwrite an existing ExportOptions file."
  fi
  [[ "$(/usr/bin/grep -c 'YOUR_TEAM_ID' "$EXPORT_TEMPLATE")" == "1" ]] || die "The ExportOptions template must hold one YOUR_TEAM_ID placeholder."
  (
    umask 077
    /usr/bin/sed "s/YOUR_TEAM_ID/$TEAM_ID/" "$EXPORT_TEMPLATE" > "$RENDER_EXPORT_OPTIONS"
  ) || die "Cannot write the ExportOptions file."
  if [[ -x /usr/bin/plutil ]]; then
    /usr/bin/plutil -lint -s "$RENDER_EXPORT_OPTIONS" || die "The rendered ExportOptions file is not a valid property list."
  fi
  echo "Rendered ExportOptions for the configured team."
  exit 0
fi

if [[ "$ALLOW_UNTRUSTED_LOCAL_RELEASE" != "0" && "$ALLOW_UNTRUSTED_LOCAL_RELEASE" != "1" ]]; then
  die "ALLOW_UNTRUSTED_LOCAL_RELEASE must be 0 or 1."
fi
if [[ "$NOTARIZE" != "0" && "$NOTARIZE" != "1" ]]; then
  die "NOTARIZE must be 0 or 1."
fi

RELEASE_MODE="official"
if [[ "$ALLOW_UNTRUSTED_LOCAL_RELEASE" == "1" ]]; then
  if [[ "$NOTARIZE" != "0" ]]; then
    die "ALLOW_UNTRUSTED_LOCAL_RELEASE=1 requires NOTARIZE=0."
  fi
  if [[ -n "$CODESIGN_IDENTITY" ]]; then
    die "ALLOW_UNTRUSTED_LOCAL_RELEASE=1 is only for an ad-hoc local release."
  fi
  if [[ -n "$NOTARY_PROFILE" || -n "$NOTARY_APPLE_ID" || -n "$NOTARY_TEAM_ID" || -n "$NOTARY_PASSWORD" ]]; then
    die "Local release mode cannot be combined with notarization configuration."
  fi
  RELEASE_MODE="local"
else
  if [[ "$NOTARIZE" != "1" ]]; then
    die "Official release requires NOTARIZE=1."
  fi
  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    die "Official release requires a Developer ID Application CODESIGN_IDENTITY."
  fi
  DEVELOPER_ID_PATTERN='^Developer[[:space:]]ID[[:space:]]Application:[[:space:]]+.+[[:space:]]\([A-Z0-9]{10}\)$'
  if [[ ! "$CODESIGN_IDENTITY" =~ $DEVELOPER_ID_PATTERN ]]; then
    die "CODESIGN_IDENTITY must be a Developer ID Application identity."
  fi
  if [[ -z "$TEAM_ID" ]]; then
    die "Official release requires OASES_TEAM_ID (the team the updater accepts)."
  fi
  if [[ "$CODESIGN_IDENTITY" != *"($TEAM_ID)" ]]; then
    die "CODESIGN_IDENTITY does not belong to OASES_TEAM_ID."
  fi
  if [[ -z "$NOTARY_PROFILE" && ( -z "$NOTARY_APPLE_ID" || -z "$NOTARY_TEAM_ID" || -z "$NOTARY_PASSWORD" ) ]]; then
    die "Official notarization requires NOTARY_PROFILE or Apple ID/team/password configuration."
  fi
fi

announce_release_mode() {
  if [[ "$RELEASE_MODE" == "local" ]]; then
    echo "!!! LOCAL UNTRUSTED RELEASE ONLY: this artifact is not publishable. !!!" >&2
  else
    echo "OFFICIAL RELEASE POLICY: Developer ID Application signing and notarization are required." >&2
  fi
}

if [[ "$VALIDATE_POLICY_ONLY" -eq 1 ]]; then
  announce_release_mode
  exit 0
fi
if [[ ! -x /usr/bin/hdiutil || ! -x /usr/bin/codesign || ! -x /usr/bin/ditto || ! -x /usr/bin/sips || ! -x /usr/bin/osascript ]]; then
  die "This packaging script must run on macOS with hdiutil, codesign, ditto, sips and osascript."
fi
if [[ -e "$RELEASE_DIR" ]]; then
  die "Refusing to overwrite existing release directory: $RELEASE_DIR"
fi

announce_release_mode
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
IDENTITY_SETTINGS=(PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID")
if [[ -n "$TEAM_ID" ]]; then
  IDENTITY_SETTINGS+=(OASES_UPDATE_TEAM_ID="$TEAM_ID")
fi
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
  "${IDENTITY_SETTINGS[@]}" \
  build

BUILT_APP="$XCODE_DERIVED/Build/Products/Release/$DISPLAY_NAME.app"
[[ -d "$BUILT_APP" ]] || die "Xcode build did not produce: $BUILT_APP"
mkdir -p "$RELEASE_DIR"
/usr/bin/ditto "$BUILT_APP" "$APP_BUNDLE"
[[ -x "$APP_BINARY" ]] || die "Built app executable is missing: $APP_BINARY"
BUILT_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null || true)"
[[ "$BUILT_BUNDLE_ID" == "$BUNDLE_ID" ]] || die "Built app bundle identifier does not match OASES_BUNDLE_ID."

if [[ "$RELEASE_MODE" == "official" ]]; then
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
