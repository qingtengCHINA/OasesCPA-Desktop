#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/package_release.sh"

[[ -f "$SCRIPT" ]] || { echo "missing package release script" >&2; exit 1; }

# Keep this contract test independent of Xcode, hdiutil and notarization.  The
# policy-only entry point must be present before any packaging side effect.
grep -F -- "ALLOW_UNTRUSTED_LOCAL_RELEASE" "$SCRIPT" >/dev/null
grep -F -- "--validate-policy" "$SCRIPT" >/dev/null
grep -F -- "LOCAL UNTRUSTED RELEASE ONLY" "$SCRIPT" >/dev/null

run_expect_failure() {
  local output status
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "expected failure: $*" >&2
    exit 1
  fi
  # Policy failures must not echo credential-shaped values.
  if [[ "$output" == *"test-notary-password"* || "$output" == *"Developer ID Application: Secret"* ]]; then
    echo "policy failure leaked a credential-shaped value" >&2
    exit 1
  fi
}

run_expect_success() {
  local output
  output="$("$@" 2>&1)"
  [[ "$output" == *"LOCAL UNTRUSTED RELEASE ONLY"* || "$output" == *"OFFICIAL RELEASE POLICY"* ]] || {
    echo "policy success did not identify its release class" >&2
    exit 1
  }
}

run_expect_failure env \
  -u ALLOW_UNTRUSTED_LOCAL_RELEASE \
  CODESIGN_IDENTITY= \
  NOTARIZE=0 \
  bash "$SCRIPT" --validate-policy

run_expect_failure env \
  ALLOW_UNTRUSTED_LOCAL_RELEASE=2 \
  CODESIGN_IDENTITY= \
  NOTARIZE=0 \
  bash "$SCRIPT" --validate-policy

run_expect_failure env \
  ALLOW_UNTRUSTED_LOCAL_RELEASE=1 \
  CODESIGN_IDENTITY= \
  NOTARIZE=1 \
  bash "$SCRIPT" --validate-policy

run_expect_failure env \
  ALLOW_UNTRUSTED_LOCAL_RELEASE=1 \
  CODESIGN_IDENTITY= \
  NOTARIZE=0 \
  NOTARY_PASSWORD=test-notary-password \
  bash "$SCRIPT" --validate-policy

run_expect_failure env \
  -u ALLOW_UNTRUSTED_LOCAL_RELEASE \
  CODESIGN_IDENTITY="Developer ID Application: Secret" \
  NOTARIZE=1 \
  NOTARY_PROFILE=contract-test-profile \
  bash "$SCRIPT" --validate-policy

run_expect_success env \
  ALLOW_UNTRUSTED_LOCAL_RELEASE=1 \
  CODESIGN_IDENTITY= \
  NOTARIZE=0 \
  bash "$SCRIPT" --validate-policy

# run_expect_refusal <expected message part> <command...>: fails, for the stated reason.
run_expect_refusal() {
  local needle="$1" output status
  shift
  set +e
  output="$("$@" 2>&1)"
  status=$?
  set -e
  if [[ "$status" -eq 0 || "$output" != *"$needle"* ]]; then
    echo "expected a refusal mentioning \"$needle\": $*" >&2
    exit 1
  fi
}

# A complete official configuration; each refusal below changes exactly one part of it.
OFFICIAL=(
  -u ALLOW_UNTRUSTED_LOCAL_RELEASE
  -u ALLOW_RELEASE_WITHOUT_UPDATER
  CODESIGN_IDENTITY="Developer ID Application: Contract Test (ABCDE12345)"
  OASES_TEAM_ID=ABCDE12345
  OASES_BUNDLE_ID=org.contract-test.cpa.macos
  OASES_UPDATE_REPOSITORY=ExampleOwner/ExampleRepo
  NOTARIZE=1
  NOTARY_PROFILE=contract-test-profile
)

# official_without <VAR>: OFFICIAL without its VAR= entry, in WITHOUT (pass "-u VAR" first).
official_without() {
  local item
  WITHOUT=()
  for item in "${OFFICIAL[@]}"; do
    case "$item" in
      "$1="*) ;;
      *) WITHOUT+=("$item") ;;
    esac
  done
}

run_expect_success env "${OFFICIAL[@]}" bash "$SCRIPT" --validate-policy
output="$(env "${OFFICIAL[@]}" bash "$SCRIPT" --validate-policy 2>&1)"
[[ "$output" == *"Updater: enabled, reads the releases of ExampleOwner/ExampleRepo"* ]] || {
  echo "official policy did not report the update repository" >&2
  exit 1
}

# Build identity comes from the environment: an official release needs OASES_TEAM_ID, the
# signing identity must belong to it, the bundle id must be explicit and not com.example,
# and the updater must be configured unless that is explicitly waived.
official_without OASES_TEAM_ID
run_expect_refusal "requires OASES_TEAM_ID" env -u OASES_TEAM_ID "${WITHOUT[@]}" bash "$SCRIPT" --validate-policy
run_expect_refusal "does not belong to OASES_TEAM_ID" env "${OFFICIAL[@]}" OASES_TEAM_ID=ZYXWV98765 bash "$SCRIPT" --validate-policy
official_without OASES_BUNDLE_ID
run_expect_refusal "explicit OASES_BUNDLE_ID" env -u OASES_BUNDLE_ID "${WITHOUT[@]}" bash "$SCRIPT" --validate-policy
run_expect_refusal "neutral com.example" env "${OFFICIAL[@]}" OASES_BUNDLE_ID=com.example.cpa.macos bash "$SCRIPT" --validate-policy
run_expect_refusal "neutral com.example" env "${OFFICIAL[@]}" OASES_BUNDLE_ID=com.example bash "$SCRIPT" --validate-policy
run_expect_refusal "no OASES_UPDATE_REPOSITORY" env "${OFFICIAL[@]}" OASES_UPDATE_REPOSITORY= bash "$SCRIPT" --validate-policy
run_expect_refusal '"owner/name"' env "${OFFICIAL[@]}" OASES_UPDATE_REPOSITORY=no-slash bash "$SCRIPT" --validate-policy
run_expect_refusal "ALLOW_RELEASE_WITHOUT_UPDATER must be 0 or 1" env "${OFFICIAL[@]}" ALLOW_RELEASE_WITHOUT_UPDATER=yes bash "$SCRIPT" --validate-policy
output="$(env "${OFFICIAL[@]}" OASES_UPDATE_REPOSITORY= ALLOW_RELEASE_WITHOUT_UPDATER=1 bash "$SCRIPT" --validate-policy 2>&1)"
[[ "$output" == *"Updater: disabled"* ]] || {
  echo "an official release without updater must say so" >&2
  exit 1
}

run_expect_failure env \
  ALLOW_UNTRUSTED_LOCAL_RELEASE=1 \
  CODESIGN_IDENTITY= \
  NOTARIZE=0 \
  OASES_TEAM_ID=abc \
  bash "$SCRIPT" --validate-policy

run_expect_failure env \
  ALLOW_UNTRUSTED_LOCAL_RELEASE=1 \
  CODESIGN_IDENTITY= \
  NOTARIZE=0 \
  OASES_BUNDLE_ID="not a bundle id" \
  bash "$SCRIPT" --validate-policy

grep -F -- 'OASES_BUNDLE_ID:-com.example.cpa.macos' "$SCRIPT" >/dev/null || {
  echo "the default bundle identifier must be the neutral com.example.cpa.macos" >&2
  exit 1
}

# ExportOptions.plist is rendered from the committed template, never overwritten.
SCRATCH_ROOT="${OASES_SCRATCH:-${TMPDIR:-/tmp}/oases-b-scratch}"
mkdir -p "$SCRATCH_ROOT"
EXPORT_DIR="$(mktemp -d "$SCRATCH_ROOT/export-options.XXXXXX")"
run_expect_failure env -u OASES_TEAM_ID bash "$SCRIPT" --render-export-options "$EXPORT_DIR/missing-team.plist"
[[ ! -e "$EXPORT_DIR/missing-team.plist" ]] || { echo "a refused render must not write a file" >&2; exit 1; }
env OASES_TEAM_ID=ABCDE12345 bash "$SCRIPT" --render-export-options "$EXPORT_DIR/ExportOptions.plist" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :teamID' "$EXPORT_DIR/ExportOptions.plist")" == "ABCDE12345" ]] || {
  echo "rendered ExportOptions does not carry OASES_TEAM_ID" >&2
  exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :method' "$EXPORT_DIR/ExportOptions.plist")" == "app-store-connect" ]] || {
  echo "rendered ExportOptions lost the template fields" >&2
  exit 1
}
run_expect_failure env OASES_TEAM_ID=ZYXWV98765 bash "$SCRIPT" --render-export-options "$EXPORT_DIR/ExportOptions.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :teamID' "$EXPORT_DIR/ExportOptions.plist")" == "ABCDE12345" ]] || {
  echo "an existing ExportOptions file was overwritten" >&2
  exit 1
}

echo "package release policy contract passed"
