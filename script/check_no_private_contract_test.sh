#!/usr/bin/env bash
#
# check_no_private_contract_test.sh - contract test for how this repo uses the shared scanner.
#
# The scanner's own rule tests live in the Server repo. This test checks only the macOS side:
# the vendored copy matches its source record, the modes and exit codes this repo relies on,
# this repo's allowlist, and the added-lines commit gate (oases_commit). Sample secrets are
# assembled at run time so that this file never holds a complete one.
#
# The scratch repositories stay under $OASES_SCRATCH (they are not removed). Needs bash 3.2.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
SCANNER="$REPO/script/check-no-private.sh"
OASES_SCRATCH=${OASES_SCRATCH:-${TMPDIR:-/tmp}/oases-b-scratch}
mkdir -p "$OASES_SCRATCH" || { echo "cannot create $OASES_SCRATCH" >&2; exit 1; }
WORK=$(mktemp -d "$OASES_SCRATCH/check.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
unset OASES_PRIVATE_TERMS_FILE

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }
expect_status() { # <name> <expected> <actual>
  if [ "$3" -eq "$2" ]; then ok "$1"; else not_ok "$1 (expected exit $2, got $3)"; fi
}
expect_contains() { # <name> <haystack> <needle>
  case $2 in *"$3"*) ok "$1" ;; *) not_ok "$1" ;; esac
}
expect_not_contains() { # <name> <haystack> <needle>
  case $2 in *"$3"*) not_ok "$1" ;; *) ok "$1" ;; esac
}

# Synthetic samples, assembled at run time.
SAMPLE_IP=$(printf '%s.%s.%s.%s' 8 8 4 4)
SAMPLE_KEY="sk-$(printf 'a%.0s' $(seq 40))"
SAMPLE_TERM="contract-$(printf '%s' private)-term-zq"
NOREPLY=$(printf '%s@%s' qingtengCHINA users.noreply.github.com)
FIXTURE_MAIL=$(printf '%s@%s' oases-e2e example.com)
FIXTURE_KEY="sk-$(printf '%s' cpa)-12345678901234567890"

TERMS="$WORK/terms.txt"
printf '%s\n' "$SAMPLE_TERM" >"$TERMS"

g() { git -C "$1" -c user.name=Contract -c "user.email=$NOREPLY" -c commit.gpgsign=false \
  -c core.hooksPath=/dev/null "${@:2}"; }

new_repo() { # <dir>
  mkdir -p "$1/script" && git init -q "$1" && printf 'hello\n' >"$1/README.md" &&
    g "$1" add -A && g "$1" commit -q -m init
}

scan_in() { # <dir> <args...>; prints the output, returns the scanner status
  (cd "$1" && OASES_PRIVATE_TERMS_FILE="$TERMS" bash "$SCANNER" "${@:2}" 2>&1)
}

# 1. The vendored copy matches its source record.
recorded=$(awk 'NR == 1 { print $2 }' "$REPO/script/check-no-private.source" 2>/dev/null)
actual=$(shasum -a 256 "$SCANNER" | awk '{ print $1 }')
if [ -n "$recorded" ] && [ "$recorded" = "$actual" ]; then
  ok "check-no-private.source records the SHA-256 of the vendored scanner"
else
  not_ok "check-no-private.source records the SHA-256 of the vendored scanner"
fi

# 2. --tree on a clean repository, then with a public IPv4 address.
R1="$WORK/tree"
new_repo "$R1" >/dev/null 2>&1 || not_ok "create a scratch repository"
out=$(scan_in "$R1" --tree); st=$?
expect_status "--tree on a clean repository exits 0" 0 "$st"
printf 'upstream = %s\n' "$SAMPLE_IP" >"$R1/hosts.conf"
out=$(scan_in "$R1" --tree); st=$?
expect_status "--tree with a public IPv4 exits 1" 1 "$st"
expect_contains "the finding is reported as public-ipv4" "$out" "hosts.conf:1: public-ipv4:"
expect_not_contains "the address is never printed in full" "$out" "$SAMPLE_IP"

# 3. --stdin with a key.
out=$(printf '%s\n' "$SAMPLE_KEY" | (cd "$R1" && bash "$SCANNER" --stdin 2>&1)); st=$?
expect_status "--stdin with a key exits 1" 1 "$st"
expect_contains "the key is reported at <stdin>:1" "$out" "<stdin>:1: secret-token:"
expect_not_contains "the key is never printed in full" "$out" "$SAMPLE_KEY"

# 4. --require-private-terms without a terms file.
out=$(cd "$R1" && OASES_PRIVATE_TERMS_FILE="$WORK/missing-terms" bash "$SCANNER" --tree \
  --require-private-terms 2>&1); st=$?
expect_status "--require-private-terms with a missing terms file exits 2" 2 "$st"

# 5. This repo's allowlist silences exactly the synthetic values it registers.
R2="$WORK/allow"
new_repo "$R2" >/dev/null 2>&1 || not_ok "create a scratch repository"
mkdir -p "$R2/Tests" "$R2/Sources/OasesCPA/Resources/Assets.xcassets/AppIcon.appiconset"
{
  printf 'let author = "%s"\n' "$NOREPLY"
  printf 'let mail = "%s"\n' "$FIXTURE_MAIL"
  printf 'let key = "%s"\n' "$FIXTURE_KEY"
} >"$R2/Tests/Fixture.swift"
printf '{ "images" : [ { "filename" : "icon_16x16@2x.png", "scale" : "2x" } ] }\n' \
  >"$R2/Sources/OasesCPA/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"
out=$(scan_in "$R2" --tree); st=$?
expect_status "the fixtures are reported without the allowlist" 1 "$st"
expect_contains "a fixture address is an email finding" "$out" "Tests/Fixture.swift:2: email:"
expect_contains "a fixture key is a secret-token finding" "$out" "Tests/Fixture.swift:3: secret-token:"
expect_not_contains "an asset file name (@2x.png) is not an email" "$out" "Contents.json"
cp "$REPO/script/private-allowlist.txt" "$R2/script/private-allowlist.txt"
out=$(scan_in "$R2" --tree); st=$?
expect_status "with this repo's allowlist the registered fixtures pass" 0 "$st"
printf 'let leaked = "%s"\n' "$SAMPLE_KEY" >>"$R2/Tests/Fixture.swift"
out=$(scan_in "$R2" --tree); st=$?
expect_status "an unregistered key on the same file still fails" 1 "$st"
expect_contains "the unregistered key is reported" "$out" "Tests/Fixture.swift:4: secret-token:"

# 6. The commit gate scans added lines only (rulings C1), and glob "*" rows apply to <stdin>.
added_lines() { # <dir>: the staged added lines, as oases_commit feeds them to the scanner
  g "$1" diff --cached -U0 --no-color --no-ext-diff | LC_ALL=C grep -E '^\+' |
    LC_ALL=C grep -vE '^\+\+\+ '
}
gate() { # <dir>: the oases_commit scan of the staged diff
  added_lines "$1" | (cd "$1" && OASES_PRIVATE_TERMS_FILE="$TERMS" bash "$SCANNER" --stdin \
    --require-private-terms 2>&1)
}
R3="$WORK/gate"
new_repo "$R3" >/dev/null 2>&1 || not_ok "create a scratch repository"
cp "$REPO/script/private-allowlist.txt" "$R3/script/private-allowlist.txt"
printf 'team = %s\nkeep = 1\n' "$SAMPLE_TERM" >"$R3/settings.conf"
g "$R3" add -A && g "$R3" commit -q -m "seed"
printf 'keep = 1\n' >"$R3/settings.conf"
g "$R3" add settings.conf
out=$(gate "$R3"); st=$?
expect_status "removing a private term passes the added-lines gate" 0 "$st"
out=$(g "$R3" diff --cached | (cd "$R3" && OASES_PRIVATE_TERMS_FILE="$TERMS" bash "$SCANNER" \
  --stdin 2>&1)); st=$?
expect_status "the full diff would have flagged the removed line" 1 "$st"
g "$R3" commit -q -m "drop the term"
printf 'keep = 1\nteam = %s\n' "$SAMPLE_TERM" >"$R3/settings.conf"
g "$R3" add settings.conf
out=$(gate "$R3"); st=$?
expect_status "adding a private term fails the added-lines gate" 1 "$st"
expect_contains "the added term is reported as private-term" "$out" "<stdin>:1: private-term:"
expect_not_contains "the term is never printed in full" "$out" "$SAMPLE_TERM"
printf 'keep = 1\nfixture = "%s"\n' "$FIXTURE_KEY" >"$R3/settings.conf"
g "$R3" add settings.conf
out=$(gate "$R3"); st=$?
expect_status "an allowlisted fixture passes the gate on <stdin>" 0 "$st"

printf '\n%d passed, %d failed (scratch: %s)\n' "$PASS" "$FAIL" "$WORK"
[ "$FAIL" -eq 0 ]
