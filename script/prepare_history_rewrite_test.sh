#!/usr/bin/env bash
#
# prepare_history_rewrite_test.sh - test of script/prepare_history_rewrite.sh.
#
# Builds throwaway repositories under $OASES_SCRATCH (they are left in place): two commits by a
# private-style address and one by the GitHub noreply identity, with a synthetic private term
# in the content, plus one committed by GitHub's web-UI address. Checks that the script only writes the two git-ignored local files and prints
# commands: refs, HEAD, index and work tree stay byte for byte the same, nothing is installed
# or run (git-filter-repo and brew are trapped on PATH), the force push appears only in a
# comment, and neither the old address nor a term reaches standard output. The sample address
# and the expected mailmap line are assembled at run time. Needs bash 3.2.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd -P)
SCRIPT="$REPO/script/prepare_history_rewrite.sh"
OASES_SCRATCH=${OASES_SCRATCH:-${TMPDIR:-/tmp}/oases-b-scratch}
mkdir -p "$OASES_SCRATCH" || { echo "cannot create $OASES_SCRATCH" >&2; exit 1; }
WORK=$(mktemp -d "$OASES_SCRATCH/rewrite.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
unset OASES_PRIVATE_TERMS_FILE

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }
expect_status() { # <name> <expected> <actual>
  if [ "$3" -eq "$2" ]; then ok "$1"; else not_ok "$1 (expected exit $2, got $3)"; fi
}
expect_equal() { # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1"; fi
}
expect_not_contains() { # <name> <haystack> <needle>
  case $2 in *"$3"*) not_ok "$1" ;; *) ok "$1" ;; esac
}

# Synthetic samples, assembled at run time.
OLD_MAIL=$(printf '%s@%s' x qq.com)
NOREPLY=$(printf '%s@%s' qingtengCHINA users.noreply.github.com)
GITHUB_WEB=$(printf '%s@%s' noreply github.com)
EXPECTED_MAILMAP=$(printf 'QingTeng <%s> <%s>' "$NOREPLY" "$OLD_MAIL")
STEM="zq-$(printf '%s' stem).example"
URL_TERM="zq-$(printf '%s' private)-page-1234"
ABSENT_TERM="zq-$(printf '%s' never)-used"

# Traps: any attempt to install or run the rewrite leaves a mark.
TRAP_BIN="$WORK/bin"
TRAP_LOG="$WORK/trap.log"
mkdir -p "$TRAP_BIN"
for tool in git-filter-repo brew; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >> "%s"\nexit 0\n' "$tool" "$TRAP_LOG" >"$TRAP_BIN/$tool"
  chmod 755 "$TRAP_BIN/$tool"
done

commit_as() { # <dir> <email> <message>
  GIT_AUTHOR_NAME=Sample GIT_AUTHOR_EMAIL="$2" GIT_COMMITTER_NAME=Sample GIT_COMMITTER_EMAIL="$2" \
    git -C "$1" -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "$3"
}

new_repo() { # <dir> <with-ignore-rules: yes|no>
  mkdir -p "$1/script" && git init -q "$1" || return 1
  cp "$SCRIPT" "$1/script/prepare_history_rewrite.sh" || return 1
  if [ "$2" = yes ]; then
    printf '%s\n' 'script/private-terms.local' 'script/history-mailmap.local' \
      'script/history-replace-text.local' >"$1/.gitignore"
  else
    printf '%s\n' 'script/private-terms.local' >"$1/.gitignore"
  fi
  printf '%s\n' "$STEM" "$URL_TERM" "$ABSENT_TERM" >"$1/script/private-terms.local"
  printf 'bundle: %s.macos\n' "$STEM" >"$1/app.txt"
  git -C "$1" add -A && commit_as "$1" "$OLD_MAIL" "first" || return 1
  printf 'policy: https://example.org/%s\n' "$URL_TERM" >>"$1/app.txt"
  git -C "$1" add -A && commit_as "$1" "$OLD_MAIL" "second" || return 1
  printf 'bundle: com.example.cpa.macos\n' >"$1/app.txt"
  git -C "$1" add -A && commit_as "$1" "$NOREPLY" "third" || return 1
  # A merge made in GitHub's web UI: committed by GitHub's own address, which is not mapped.
  printf 'merged\n' >>"$1/app.txt"
  git -C "$1" add -A && GIT_AUTHOR_NAME=Sample GIT_AUTHOR_EMAIL="$NOREPLY" GIT_COMMITTER_NAME=GitHub \
    GIT_COMMITTER_EMAIL="$GITHUB_WEB" git -C "$1" -c commit.gpgsign=false -c core.hooksPath=/dev/null \
    commit -q -m "fourth"
}

snapshot() { # <dir>: everything the script must not change
  {
    git -C "$1" for-each-ref
    git -C "$1" rev-parse HEAD
    git -C "$1" ls-files --stage
    git -C "$1" status --porcelain
    git -C "$1" config --local --list
    ls -a "$1/.git"
  }
}

# 1. Printing mode in a repository with the ignore rules.
R="$WORK/repo"
new_repo "$R" yes || { echo "cannot build $R" >&2; exit 1; }
before=$(snapshot "$R")
out=$(cd "$R" && PATH="$TRAP_BIN:$PATH" bash script/prepare_history_rewrite.sh 2>"$WORK/stderr.txt")
status=$?
after=$(snapshot "$R")
expect_status "prepare exits 0" 0 "$status"
expect_equal "refs, HEAD, index, work tree and .git entries are unchanged" "$before" "$after"
if [ ! -s "$TRAP_LOG" ]; then ok "neither git-filter-repo nor brew was run"; else not_ok "a trapped tool was run"; fi

mailmap="$R/script/history-mailmap.local"
lines=$(wc -l <"$mailmap" 2>/dev/null | tr -d ' ')
expect_equal "the mailmap has exactly 1 line" 1 "${lines:-0}"
expect_equal "the mailmap line maps the old address to the noreply identity" "$EXPECTED_MAILMAP" "$(cat "$mailmap" 2>/dev/null)"
if [ -n "$(git -C "$R" check-ignore script/history-mailmap.local)" ]; then ok "the mailmap is git-ignored"; else not_ok "the mailmap is not ignored"; fi
if [ -n "$(git -C "$R" check-ignore script/history-replace-text.local)" ]; then ok "the replace-text file is git-ignored"; else not_ok "the replace-text file is not ignored"; fi
mode=$(stat -f '%Lp' "$mailmap" 2>/dev/null || stat -c '%a' "$mailmap")
expect_equal "the mailmap is private (0600)" 600 "$mode"

replace="$R/script/history-replace-text.local"
expect_equal "the stem is replaced by the neutral stem, case-insensitively" \
  "regex:(?i)zq-stem\\.example==>com.example.cpa" "$(grep -F 'zq-stem' "$replace" 2>/dev/null)"
expect_equal "another term in history is redacted" \
  "regex:(?i)zq-private-page-1234==>REDACTED" "$(grep -F 'page-1234' "$replace" 2>/dev/null)"
if grep -qF "$ABSENT_TERM" "$replace" 2>/dev/null; then not_ok "a term that is not in history is listed"; else ok "a term that is not in history is left out"; fi
mode=$(stat -f '%Lp' "$replace" 2>/dev/null || stat -c '%a' "$replace")
expect_equal "the replace-text file is private (0600)" 600 "$mode"

push_lines=$(printf '%s\n' "$out" | grep -F 'git push --force --mirror')
if [ -n "$push_lines" ]; then ok "stdout names git push --force --mirror"; else not_ok "stdout does not name the force push"; fi
if printf '%s\n' "$push_lines" | grep -qvE '^[[:space:]]*#'; then
  not_ok "the force push appears outside a # comment"
else
  ok "the force push appears only in # comment lines"
fi
for word in 'git filter-repo --mailmap' '--replace-text' 'check-no-private.sh --history --require-private-terms'; do
  case $out in *"$word"*) ok "stdout names: $word" ;; *) not_ok "stdout lacks: $word" ;; esac
done
# After the rewrite every commit id is new: the printed steps scan with --history (CI does the
# same) and never name a range or look up the new id of an old commit.
expect_not_contains "stdout names no commit range" "$out" "..HEAD"
expect_not_contains "stdout does not look up an old commit's new id" "$out" "commit-map"
case $out in
  *"CI (.github/workflows/private-scan.yml) runs the same --history scan"*) ok "stdout says CI uses the same --history scan" ;;
  *) not_ok "stdout does not say CI uses the same --history scan" ;;
esac
all_output="$out$(cat "$WORK/stderr.txt")"
expect_not_contains "the old address is not printed" "$all_output" "$OLD_MAIL"
expect_not_contains "the stem is not printed" "$all_output" "$STEM"
expect_not_contains "the other term is not printed" "$all_output" "$URL_TERM"

# 2. A second run gives the same files (no duplicates) and still changes nothing.
first_mailmap=$(cat "$mailmap")
first_replace=$(cat "$replace")
(cd "$R" && PATH="$TRAP_BIN:$PATH" bash script/prepare_history_rewrite.sh >/dev/null 2>&1)
expect_status "a second run exits 0" 0 "$?"
expect_equal "a second run writes the same mailmap" "$first_mailmap" "$(cat "$mailmap")"
expect_equal "a second run writes the same replace-text file" "$first_replace" "$(cat "$replace")"
expect_equal "a second run leaves the repository unchanged" "$before" "$(snapshot "$R")"

# 3. Without the ignore rules nothing is written: the old address must never become committable.
N="$WORK/no-ignore"
new_repo "$N" no || { echo "cannot build $N" >&2; exit 1; }
before=$(snapshot "$N")
(cd "$N" && PATH="$TRAP_BIN:$PATH" bash script/prepare_history_rewrite.sh >"$WORK/n.out" 2>&1)
expect_status "without the ignore rules the script exits 2" 2 "$?"
if [ ! -e "$N/script/history-mailmap.local" ] && [ ! -e "$N/script/history-replace-text.local" ]; then
  ok "without the ignore rules no file is written"
else
  not_ok "a file was written although it is not ignored"
fi
expect_equal "without the ignore rules the repository is unchanged" "$before" "$(snapshot "$N")"

# 4. Without a private terms file the script stops before writing anything.
T="$WORK/no-terms"
new_repo "$T" yes || { echo "cannot build $T" >&2; exit 1; }
mv "$T/script/private-terms.local" "$WORK/terms-moved.txt"
(cd "$T" && PATH="$TRAP_BIN:$PATH" bash script/prepare_history_rewrite.sh >/dev/null 2>&1)
expect_status "without a terms file the script exits 2" 2 "$?"
if [ ! -e "$T/script/history-mailmap.local" ]; then ok "without a terms file no mailmap is written"; else not_ok "a mailmap was written without terms"; fi

if [ -s "$TRAP_LOG" ]; then not_ok "a trapped tool was run in a later case"; else ok "no trapped tool ran in any case"; fi

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
