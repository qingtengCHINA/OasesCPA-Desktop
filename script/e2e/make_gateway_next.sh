#!/usr/bin/env bash
#
# make_gateway_next.sh - build the "next version" of a gateway release package for the upgrade
# drill (acceptance only; never shipped).
#
# Usage: bash script/e2e/make_gateway_next.sh <dir>/oases-gateway_<X.Y.Z>.tar.gz [--out-dir <dir>]
#
# Unpacks a copy of the package (the input is never changed), raises the patch number of
# VERSION by one, renames the single top directory to oases-gateway_<X.Y.(Z+1)>/, and puts a
# few lines at the top of server.mjs that write $OASES_DATA_DIR/e2e-format.json ({"format":2})
# when the gateway starts: a stand-in for a one-way data change, so that a rollback can be seen
# to restore the data directory. Then it packs oases-gateway_<next>.tar.gz into --out-dir
# (default: a new directory under $OASES_SCRATCH) and prints, and only prints, three lines for
# the app's DEBUG end-to-end override (GatewayBundle.resolve):
#   OASES_E2E_GATEWAY_TARBALL=<absolute path>
#   OASES_E2E_GATEWAY_SHA256=<sha256>
#   OASES_E2E_GATEWAY_VERSION=<next version>
#
# Exit status: 0 built, 2 usage error or a package that does not look like a gateway release
# (file name, single top directory, VERSION, server.mjs and bootstrap.mjs), 1 other failure.
# Needs bash 3.2, tar, shasum, mktemp.

set -u

PROG=make_gateway_next
MARKER='// oases-e2e: make_gateway_next.sh'

die() { printf '%s: %s\n' "$PROG" "$2" >&2; exit "$1"; }

input=
out_dir=
while [ "$#" -gt 0 ]; do
  case $1 in
    --out-dir)
      [ "$#" -ge 2 ] || die 2 "--out-dir needs a directory"
      out_dir=$2
      shift 2
      ;;
    -*) die 2 "unknown option: $1" ;;
    *)
      [ -z "$input" ] || die 2 "usage: make_gateway_next.sh <oases-gateway_X.Y.Z.tar.gz> [--out-dir <dir>]"
      input=$1
      shift
      ;;
  esac
done
[ -n "$input" ] || die 2 "usage: make_gateway_next.sh <oases-gateway_X.Y.Z.tar.gz> [--out-dir <dir>]"
[ -f "$input" ] || die 2 "no such file: $input"

name=$(basename "$input")
case $name in
  oases-gateway_*.tar.gz) version=${name#oases-gateway_}; version=${version%.tar.gz} ;;
  *) die 2 "the file name must be oases-gateway_<X.Y.Z>.tar.gz" ;;
esac
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || die 2 "the version must be X.Y.Z (got $version)"
major=${version%%.*}
rest=${version#*.}
minor=${rest%%.*}
patch=${rest#*.}
next="$major.$minor.$((patch + 1))"

OASES_SCRATCH=${OASES_SCRATCH:-${TMPDIR:-/tmp}/oases-b-scratch}
mkdir -p "$OASES_SCRATCH" || die 1 "cannot create $OASES_SCRATCH"
work=$(mktemp -d "$OASES_SCRATCH/gateway-next.XXXXXX") || die 1 "mktemp failed"
if [ -z "$out_dir" ]; then
  out_dir=$work/out
  mkdir -p "$out_dir" || die 1 "cannot create $out_dir"
fi
[ -d "$out_dir" ] || die 2 "no such directory: $out_dir"
out_dir=$(cd "$out_dir" && pwd -P) || die 1 "cannot resolve $out_dir"

tops=$(tar -tzf "$input" | sed -e 's|^\./||' -e 's|/.*$||' | sort -u) || die 2 "not a tar.gz: $input"
[ "$tops" = "oases-gateway_$version" ] || die 2 "the package must have one top directory oases-gateway_$version/"
if tar -tzf "$input" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  die 2 "the package has absolute or .. paths"
fi

mkdir -p "$work/unpacked" || die 1 "cannot create the work directory"
tar -xzf "$input" -C "$work/unpacked" || die 1 "cannot unpack $input"
src=$work/unpacked/oases-gateway_$version
[ -f "$src/server.mjs" ] && [ -f "$src/bootstrap.mjs" ] || die 2 "the package has no server.mjs or bootstrap.mjs"
[ -f "$src/VERSION" ] || die 2 "the package has no VERSION"
[ "$(tr -d ' \t\r\n' <"$src/VERSION")" = "$version" ] || die 2 "VERSION does not match the file name"
if grep -qF "$MARKER" "$src/server.mjs"; then
  die 2 "server.mjs already carries the e2e marker"
fi

dest=$work/unpacked/oases-gateway_$next
mv "$src" "$dest" || die 1 "cannot rename the top directory"
printf '%s\n' "$next" >"$dest/VERSION" || die 1 "cannot write VERSION"

# The lines go first (after a shebang, if any). Static imports are hoisted, so in an ES module
# the write still runs before the rest of the module body.
{
  first=$(head -n 1 "$dest/server.mjs")
  case $first in '#!'*) printf '%s\n' "$first" ;; esac
  printf '%s\n' \
    "$MARKER (acceptance drill only): marks the data directory with a new format." \
    "import { writeFileSync as oasesE2eWriteFileSync } from 'node:fs';" \
    "import { join as oasesE2eJoin } from 'node:path';" \
    "if (process.env.OASES_DATA_DIR) oasesE2eWriteFileSync(oasesE2eJoin(process.env.OASES_DATA_DIR, 'e2e-format.json'), '{\"format\":2}\\n', { mode: 0o600 });"
  case $first in
    '#!'*) tail -n +2 "$dest/server.mjs" ;;
    *) cat "$dest/server.mjs" ;;
  esac
} >"$dest/server.mjs.next" || die 1 "cannot write server.mjs"
mv -f "$dest/server.mjs.next" "$dest/server.mjs" || die 1 "cannot replace server.mjs"

tarball=$out_dir/oases-gateway_$next.tar.gz
[ ! -e "$tarball" ] || die 2 "$tarball already exists"
COPYFILE_DISABLE=1 tar -czf "$tarball.part" -C "$work/unpacked" "oases-gateway_$next" || die 1 "cannot pack"
mv "$tarball.part" "$tarball" || die 1 "cannot write $tarball"
sha=$(shasum -a 256 "$tarball" | awk '{ print $1 }') || die 1 "shasum failed"

printf 'OASES_E2E_GATEWAY_TARBALL=%s\n' "$tarball"
printf 'OASES_E2E_GATEWAY_SHA256=%s\n' "$sha"
printf 'OASES_E2E_GATEWAY_VERSION=%s\n' "$next"
