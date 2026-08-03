#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/project.yml"

CURRENT_VERSION="$(/usr/bin/awk -F '"' '/MARKETING_VERSION:/ { print $2; exit }' "$PROJECT_FILE")"
CURRENT_BUILD="$(/usr/bin/awk -F '"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$PROJECT_FILE")"

if [[ ! "$CURRENT_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "MARKETING_VERSION is not a semantic patch version: $CURRENT_VERSION" >&2
  exit 2
fi
VERSION_MAJOR="${BASH_REMATCH[1]}"
VERSION_MINOR="${BASH_REMATCH[2]}"
VERSION_PATCH="${BASH_REMATCH[3]}"
if [[ ! "$CURRENT_BUILD" =~ ^[0-9]+$ ]]; then
  echo "CURRENT_PROJECT_VERSION is not numeric: $CURRENT_BUILD" >&2
  exit 2
fi

NEXT_VERSION="${VERSION_MAJOR}.${VERSION_MINOR}.$((VERSION_PATCH + 1))"
NEXT_BUILD="$((CURRENT_BUILD + 1))"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required before changing project.yml." >&2
  exit 3
fi

/usr/bin/perl -0pi -e \
  "s/MARKETING_VERSION: \"\\Q${CURRENT_VERSION}\\E\"/MARKETING_VERSION: \"${NEXT_VERSION}\"/; s/CURRENT_PROJECT_VERSION: \"\\Q${CURRENT_BUILD}\\E\"/CURRENT_PROJECT_VERSION: \"${NEXT_BUILD}\"/" \
  "$PROJECT_FILE"

cd "$ROOT_DIR"
xcodegen generate
echo "Prepared Oases CPA $NEXT_VERSION ($NEXT_BUILD)."
