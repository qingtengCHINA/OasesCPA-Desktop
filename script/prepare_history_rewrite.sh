#!/usr/bin/env bash
#
# prepare_history_rewrite.sh - prepare (never run) the history rewrite before the repository
# becomes public.
#
# Usage: bash script/prepare_history_rewrite.sh        (from anywhere inside the work tree)
#
# Writes two local files, both git-ignored and mode 0600, and prints the commands the owner runs
# by hand. It never rewrites, pushes, installs or runs git-filter-repo, and it changes no ref,
# no index entry and no tracked file.
#
#   script/history-mailmap.local       one line per author or committer address in any commit
#                                      that is not a GitHub noreply address:
#                                        QingTeng <qingtengCHINA@users.noreply.github.com> <old>
#                                      (no .mailmap is committed: it would publish the old
#                                      addresses)
#   script/history-replace-text.local  a git filter-repo --replace-text file: one rule per
#                                      private term (${OASES_PRIVATE_TERMS_FILE:-
#                                      script/private-terms.local}) that occurs anywhere in the
#                                      history (patches and messages), case-insensitive. A term
#                                      used as the bundle identifier stem (<term>.macos) becomes
#                                      the committed neutral stem com.example.cpa, every other
#                                      term REDACTED.
#
# Neither file content nor any term or address is printed; only counts.
# Exit status: 0 prepared, 2 configuration error (not in a work tree, no private terms, an
# output file that is not git-ignored or is tracked), 1 any other failure. Needs bash 3.2, git,
# awk, sed, grep, sort, mktemp.

set -u
export GIT_OPTIONAL_LOCKS=0
unset -f awk git grep mktemp sed sort tr 2>/dev/null

PROG=prepare_history_rewrite
NOREPLY_IDENTITY='QingTeng <qingtengCHINA@users.noreply.github.com>'
NEUTRAL_STEM='com.example.cpa'
PUBLIC_REMOTE='https://github.com/qingtengCHINA/OasesCPA-Desktop.git'
BASE_COMMIT='f0f2500'

die() { printf '%s: %s\n' "$PROG" "$2" >&2; exit "$1"; }
# Single-quotes a value for the printed commands.
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

[ "$#" -eq 0 ] || die 2 "usage: bash script/prepare_history_rewrite.sh"
TOP=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$TOP" ] || die 2 "not inside a git work tree"
cd "$TOP" || die 1 "cannot enter the work tree"

MAILMAP_REL=script/history-mailmap.local
REPLACE_REL=script/history-replace-text.local
TERMS_FILE=${OASES_PRIVATE_TERMS_FILE:-script/private-terms.local}
case $TERMS_FILE in /*) TERMS_ABS=$TERMS_FILE ;; *) TERMS_ABS=$TOP/$TERMS_FILE ;; esac

for rel in "$MAILMAP_REL" "$REPLACE_REL"; do
  if git ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
    die 2 "$rel is tracked; it must never be committed"
  fi
  git check-ignore -q -- "$rel" || die 2 "$rel is not git-ignored; add it to .gitignore first"
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/prepare-history.XXXXXX") || die 1 "mktemp failed"
# The scratch copies hold the history text and the terms; they are removed on every exit.
cleanup() { [ -n "$TMP" ] && [ -d "$TMP" ] && rm -rf -- "$TMP"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
umask 077

if [ -f "$TERMS_ABS" ]; then
  LC_ALL=C awk '
    { sub(/\r$/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
    $0 == "" || substr($0, 1, 1) == "#" { next }
    { print }
  ' "$TERMS_ABS" >"$TMP/terms" || die 1 "cannot read the private terms file"
fi
[ -s "$TMP/terms" ] || die 2 "the private terms file is missing or holds no term ($TERMS_FILE)"

# --- addresses -------------------------------------------------------------------------------
git log --all --format='%ae%n%ce' >"$TMP/addresses" || die 1 "git log failed"
LC_ALL=C tr 'A-Z' 'a-z' <"$TMP/addresses" | LC_ALL=C awk '
  $0 == "" { next }
  # GitHub noreply addresses, and GitHub's own web-UI committer address (written in two parts).
  $0 ~ /@users\.noreply\.github\.com$/ || $0 == ("noreply" "@" "github.com") { next }
  { print }
' | LC_ALL=C sort -u >"$TMP/old-addresses"
LC_ALL=C awk -v id="$NOREPLY_IDENTITY" '{ printf "%s <%s>\n", id, $0 }' "$TMP/old-addresses" >"$TMP/mailmap" \
  || die 1 "cannot build the mailmap"
address_count=$(LC_ALL=C awk 'END { print NR }' "$TMP/mailmap")

# --- terms -----------------------------------------------------------------------------------
git log -p --all --no-color --no-ext-diff --format='%B' >"$TMP/history" || die 1 "git log -p failed"
: >"$TMP/replace"
term_count=0
skipped=0
while IFS= read -r term || [ -n "$term" ]; do
  case $term in *'==>'*) skipped=$((skipped + 1)); continue ;; esac
  LC_ALL=C grep -qiF -e "$term" "$TMP/history" || continue
  if LC_ALL=C grep -qiF -e "$term.macos" "$TMP/history"; then
    replacement=$NEUTRAL_STEM
  else
    replacement=REDACTED
  fi
  escaped=$(printf '%s' "$term" | LC_ALL=C sed -e 's/[]\.^$*+?(){}|[]/\\&/g')
  printf 'regex:(?i)%s==>%s\n' "$escaped" "$replacement" >>"$TMP/replace"
  term_count=$((term_count + 1))
done <"$TMP/terms"

# --- write (atomically, private) ---------------------------------------------------------------
for pair in "mailmap:$MAILMAP_REL" "replace:$REPLACE_REL"; do
  src=$TMP/${pair%%:*}
  dest=$TOP/${pair#*:}
  cp "$src" "$dest.part.$$" && chmod 600 "$dest.part.$$" && mv -f "$dest.part.$$" "$dest" \
    || die 1 "cannot write ${pair#*:}"
done

# --- the commands --------------------------------------------------------------------------------
branch=$(git symbolic-ref --short -q HEAD || true)
branch_option=
[ -n "$branch" ] && branch_option=" --branch $(shq "$branch")"
q_top=$(shq "$TOP")
q_mailmap=$(shq "$TOP/$MAILMAP_REL")
q_replace=$(shq "$TOP/$REPLACE_REL")
q_terms=$(shq "$TERMS_ABS")

cat <<EOF
# History rewrite for the public release: PREPARED, NOT RUN.
# Wrote $MAILMAP_REL ($address_count address(es) to map) and $REPLACE_REL
# ($term_count private term(s) found in the history). Both are git-ignored and mode 0600: never
# commit, print or share them.$( [ "$skipped" -gt 0 ] && printf '\n# %s term(s) contain "==>" and were left out: rewrite those by hand.' "$skipped" )
# The owner runs the steps below by hand, in this order, before the repository is public.

# 1. Install git-filter-repo (not installed on this Mac).
brew install git-filter-repo

# 2. A fresh bare copy of THIS repository: it holds every local branch, including the ones that
#    are not on GitHub yet. Nothing below touches this work tree.
WORK="\$(mktemp -d "\${TMPDIR:-/tmp}/oases-history-rewrite.XXXXXX")"
git clone --bare --no-local $q_top "\$WORK/rewrite.git"
cd "\$WORK/rewrite.git"

# 3. Rewrite every branch: author and committer addresses through the mailmap, the private terms
#    in files and in commit messages. No replace refs are kept.
git filter-repo --mailmap $q_mailmap --replace-text $q_replace --replace-message $q_replace --replace-refs delete-no-add

# 4. Rescan. Only noreply addresses may be left:
git log --all --format='%ae %ce' | sort -u
#    and the whole rewritten history must scan clean (exit 0, no output):
git clone --no-local$branch_option "\$WORK/rewrite.git" "\$WORK/verify"
(cd "\$WORK/verify" && OASES_PRIVATE_TERMS_FILE=$q_terms bash script/check-no-private.sh --history --require-private-terms)

# 5. Commit ids change. The new id of $BASE_COMMIT (CI scans $BASE_COMMIT..HEAD in
#    .github/workflows/private-scan.yml; change that base in the first commit after the rewrite):
awk '\$1 ~ /^$BASE_COMMIT/ { print \$2 }' "\$WORK/rewrite.git/filter-repo/commit-map"

# 6. Only the owner, only before the repository is public, and only after step 4 was clean:
# cd "\$WORK/rewrite.git" && git remote add origin $PUBLIC_REMOTE
# cd "\$WORK/rewrite.git" && git push --force --mirror origin
# Afterwards clone again from GitHub and work from that clone. This work tree keeps the old
# history: never push from it again.
EOF
