#!/usr/bin/env bash
#
# sync_check_no_private_test.sh - tests of script/sync_check_no_private.sh.
#
# A synthetic "Server" repository and a copy of the sync script inside a synthetic target
# repository, both under $OASES_SCRATCH (left in place). Checks: the scanner is installed with
# mode 755 whatever the umask and the old file's mode, the source record names the commit and
# hash, a dirty Server tree changes nothing, and when the second step (the source record)
# fails, neither file is replaced and no staging file is left. Needs bash 3.2.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
OASES_SCRATCH=${OASES_SCRATCH:-${TMPDIR:-/tmp}/oases-b-scratch}
mkdir -p "$OASES_SCRATCH" || { echo "cannot create $OASES_SCRATCH" >&2; exit 1; }
WORK=$(mktemp -d "$OASES_SCRATCH/sync-test.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }
expect_status() { # <name> <expected> <actual>
  if [ "$3" -eq "$2" ]; then ok "$1"; else not_ok "$1 (expected exit $2, got $3)"; fi
}
expect_equal() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 (expected [$2], got [$3])"; fi
}
mode_of() { stat -f '%Lp' "$1"; }

NOREPLY=$(printf '%s@%s' sync-test users.noreply.github.com)
g() { git -C "$1" -c user.name=SyncTest -c "user.email=$NOREPLY" -c commit.gpgsign=false \
  -c core.hooksPath=/dev/null "${@:2}"; }

# The "Server" repository with a tracked scanner.
SERVER="$WORK/server"
mkdir -p "$SERVER/script"
git init -q "$SERVER"
printf '#!/usr/bin/env bash\necho scanner v2\n' > "$SERVER/script/check-no-private.sh"
g "$SERVER" add -A && g "$SERVER" commit -q -m scanner
COMMIT=$(git -C "$SERVER" rev-parse HEAD)
DIGEST=$(shasum -a 256 "$SERVER/script/check-no-private.sh" | awk '{print $1}')

# A target repository: the sync script, an older scanner (mode 644) and an older record.
new_target() { # <dir>
  mkdir -p "$1/script"
  cp "$REPO/script/sync_check_no_private.sh" "$1/script/sync_check_no_private.sh"
  printf '#!/usr/bin/env bash\necho scanner v1\n' > "$1/script/check-no-private.sh"
  chmod 644 "$1/script/check-no-private.sh"
  printf 'old-commit old-digest\n' > "$1/script/check-no-private.source"
}

# 1. A normal sync under umask 077: mode 755 and 644, content and record right.
T1="$WORK/target1"
new_target "$T1"
out=$( (umask 077; bash "$T1/script/sync_check_no_private.sh" "$SERVER") 2>&1 ); status=$?
expect_status "sync succeeds" 0 "$status"
if cmp -s "$SERVER/script/check-no-private.sh" "$T1/script/check-no-private.sh"; then ok "the scanner is copied byte for byte"; else not_ok "the scanner is copied byte for byte"; fi
expect_equal "the scanner has mode 755 although it was 644 and the umask is 077" 755 "$(mode_of "$T1/script/check-no-private.sh")"
expect_equal "the record has mode 644" 644 "$(mode_of "$T1/script/check-no-private.source")"
expect_equal "the record names the commit and the hash" "$COMMIT $DIGEST" "$(cat "$T1/script/check-no-private.source")"
case "$out" in *"vendored check-no-private.sh from $COMMIT"*) ok "it says what it vendored" ;; *) not_ok "it says what it vendored: $out" ;; esac
left=$(find "$T1/script" -name '.check-no-private.*' | wc -l | tr -d ' ')
expect_equal "no staging file is left" 0 "$left"

# 2. A dirty Server tree: refused, nothing changes.
T2="$WORK/target2"
new_target "$T2"
printf 'dirty\n' > "$SERVER/untracked.txt"
bash "$T2/script/sync_check_no_private.sh" "$SERVER" >/dev/null 2>&1; status=$?
mv "$SERVER/untracked.txt" "$WORK/untracked.txt"
expect_status "a dirty Server tree is refused" 1 "$status"
expect_equal "the scanner is unchanged" "echo scanner v1" "$(tail -n 1 "$T2/script/check-no-private.sh")"

# 3. The second step fails (a mv/cp/install that refuses the record's path): neither file is
#    replaced, no staging file is left.
T3="$WORK/target3"
new_target "$T3"
FAKE="$WORK/fake-bin"
mkdir -p "$FAKE"
for tool in mv cp install; do
  real=$(command -v "$tool")
  cat > "$FAKE/$tool" <<EOF
#!/bin/bash
last=""
for argument in "\$@"; do last="\$argument"; done
case "\$last" in
  */check-no-private.source) echo "$tool: refused (test)" >&2; exit 1 ;;
esac
exec "$real" "\$@"
EOF
  chmod 755 "$FAKE/$tool"
done
PATH="$FAKE:$PATH" bash "$T3/script/sync_check_no_private.sh" "$SERVER" >/dev/null 2>&1; status=$?
expect_status "a failed record write fails the sync" 1 "$status"
expect_equal "the scanner was not replaced" "echo scanner v1" "$(tail -n 1 "$T3/script/check-no-private.sh")"
expect_equal "the scanner keeps its mode" 644 "$(mode_of "$T3/script/check-no-private.sh")"
expect_equal "the record was not replaced" "old-commit old-digest" "$(cat "$T3/script/check-no-private.source")"
left=$(find "$T3/script" -name '.check-no-private.*' | wc -l | tr -d ' ')
expect_equal "no staging file is left after the failure" 0 "$left"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
