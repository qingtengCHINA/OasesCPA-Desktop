#!/usr/bin/env bash
#
# snapshot.sh - render one page of the app offscreen to PNG files, for design review.
#
#   bash script/snapshot.sh <page> [zh-Hans|en|all] [light|dark|all]
#
# <page> is an AppSection raw value (dashboard, authFiles, system, environments, models, ...),
# or gallery (the shared components), sidebar or settings. Example:
#
#   bash script/snapshot.sh authFiles en dark
#
# How: runs the opt-in XCTest DesignSnapshotTests/testRequestedPage, which hosts the view in a
# window that is never shown, with the app's string tables standing in for the main bundle (so
# Text literals follow the chosen language). Nothing is launched, nothing is shown on screen,
# no network, no Keychain: HOME and CFFIXED_USER_HOME point to a fresh scratch directory and
# the stores start idle (not connected), so pages show their not-connected states.
#
# Output: $OASES_SNAPSHOT_DIR/design/<page>-<language>-<appearance>.png
#         (default ${TMPDIR:-/tmp}/oases-snapshots). Build cache: $OASES_SNAPSHOT_BUILD
#         (default ${TMPDIR:-/tmp}/oases-snapshot-build).

set -euo pipefail

usage() { sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] && [ $# -le 3 ] || usage
PAGE=$1
LANGUAGE=${2:-all}
APPEARANCE=${3:-all}
case "$LANGUAGE" in zh-Hans|en|all) ;; *) usage ;; esac
case "$APPEARANCE" in light|dark|all) ;; *) usage ;; esac

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=${TMPDIR:-/tmp}
OUT=${OASES_SNAPSHOT_DIR:-$TMP/oases-snapshots}
BUILD=${OASES_SNAPSHOT_BUILD:-$TMP/oases-snapshot-build}
SCRATCH_HOME=$(mktemp -d "${TMP%/}/oases-snapshot-home.XXXXXX")
mkdir -p "$OUT" "$BUILD"

cd "$ROOT"
set +e
HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" \
OASES_SNAPSHOT_DIR="$OUT" OASES_SNAPSHOT_PAGE="$PAGE" \
OASES_SNAPSHOT_LANGUAGE="$LANGUAGE" OASES_SNAPSHOT_APPEARANCE="$APPEARANCE" \
    swift test --scratch-path "$BUILD" --filter 'DesignSnapshotTests/testRequestedPage' > "$OUT/snapshot-$PAGE.log" 2>&1
status=$?
set -e
mv "$SCRATCH_HOME" "$HOME/.Trash/" 2>/dev/null || true

if [ $status -ne 0 ]; then
    grep -E "error:" "$OUT/snapshot-$PAGE.log" | head -20 >&2
    echo "snapshot failed; full log: $OUT/snapshot-$PAGE.log" >&2
    exit $status
fi
ls -1 "$OUT/design/$PAGE"-*.png
