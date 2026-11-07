#!/usr/bin/env bash
#
# sync_check_no_private.sh - vendor the shared private-string scanner from the Server repo.
#
# Usage: bash script/sync_check_no_private.sh <server-repo-dir>
#
# Copies <server-repo-dir>/script/check-no-private.sh byte for byte to script/check-no-private.sh
# and records its origin in script/check-no-private.source as one line:
#   <server commit sha> <sha256 of the script>
# The Server work tree must be clean and the script must be tracked there. On any failure the
# script exits 1 and leaves both files untouched. Needs bash 3.2, git, cmp, shasum.

set -u

fail() {
  printf 'sync_check_no_private: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 1 ] || fail "usage: bash script/sync_check_no_private.sh <server-repo-dir>"

server_dir=$1
[ -d "$server_dir" ] || fail "not a directory: $server_dir"

repo_root=$(cd "$(dirname "$0")/.." && pwd -P) || fail "cannot resolve the repository root"
source_script="$server_dir/script/check-no-private.sh"
target_script="$repo_root/script/check-no-private.sh"
target_source="$repo_root/script/check-no-private.source"

git -C "$server_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail "not a git work tree: $server_dir"
status=$(git -C "$server_dir" status --porcelain) || fail "git status failed in $server_dir"
[ -z "$status" ] || fail "the Server work tree is not clean"
git -C "$server_dir" ls-files --error-unmatch script/check-no-private.sh >/dev/null 2>&1 \
  || fail "script/check-no-private.sh is not tracked in $server_dir"
[ -f "$source_script" ] || fail "missing $source_script"

commit=$(git -C "$server_dir" rev-parse HEAD) || fail "cannot read the Server HEAD"
case "$commit" in
  *[!0-9a-f]* | "") fail "unexpected Server HEAD" ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/sync-check-no-private.XXXXXX") || fail "mktemp failed"
tmp_script="$work/check-no-private.sh"
tmp_source="$work/check-no-private.source"

cp "$source_script" "$tmp_script" || fail "cannot copy the scanner"
cmp -s "$source_script" "$tmp_script" || fail "copy of the scanner differs from the source"
chmod 755 "$tmp_script" || fail "chmod failed"

digest=$(shasum -a 256 "$tmp_script" | awk '{print $1}')
case "$digest" in
  *[!0-9a-f]* | "") fail "cannot hash the scanner" ;;
esac
printf '%s %s\n' "$commit" "$digest" > "$tmp_source" || fail "cannot write the source record"
chmod 644 "$tmp_source" || fail "chmod failed"

cp "$tmp_script" "$target_script" || fail "cannot install the scanner"
cp "$tmp_source" "$target_source" || fail "cannot write $target_source"
cmp -s "$source_script" "$target_script" || fail "installed scanner differs from the source"
printf 'vendored check-no-private.sh from %s (%s)\n' "$commit" "$digest"
