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

run_expect_success env \
  -u ALLOW_UNTRUSTED_LOCAL_RELEASE \
  CODESIGN_IDENTITY="Developer ID Application: Contract Test (ABCDE12345)" \
  OASES_TEAM_ID=ABCDE12345 \
  NOTARIZE=1 \
  NOTARY_PROFILE=contract-test-profile \
  bash "$SCRIPT" --validate-policy

# Build identity comes from the environment: an official release needs OASES_TEAM_ID and
# the signing identity must belong to it; malformed identifiers are refused.
run_expect_failure env \
  -u ALLOW_UNTRUSTED_LOCAL_RELEASE \
  -u OASES_TEAM_ID \
  CODESIGN_IDENTITY="Developer ID Application: Contract Test (ABCDE12345)" \
  NOTARIZE=1 \
  NOTARY_PROFILE=contract-test-profile \
  bash "$SCRIPT" --validate-policy

run_expect_failure env \
  -u ALLOW_UNTRUSTED_LOCAL_RELEASE \
  CODESIGN_IDENTITY="Developer ID Application: Contract Test (ABCDE12345)" \
  OASES_TEAM_ID=ZYXWV98765 \
  NOTARIZE=1 \
  NOTARY_PROFILE=contract-test-profile \
  bash "$SCRIPT" --validate-policy

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
