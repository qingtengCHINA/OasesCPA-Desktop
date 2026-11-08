#!/usr/bin/env bash
#
# vendor_gateway.sh - put a gateway release package into the app's resources.
#
# Usage:
#   script/vendor_gateway.sh --tarball <oases-gateway_<ver>.tar.gz> --checksums <checksums.txt> [--dest <dir>]
#   script/vendor_gateway.sh --server <Server repository> [--dest <dir>]
#   script/vendor_gateway.sh --placeholder [--dest <dir>]
#
#   --tarball      a released package; its line in --checksums must equal its local SHA-256
#   --server       builds a package from the committed HEAD of the Server repository (the work
#                  tree must be clean and gateway/ must hold no ignored file); its version gets
#                  a "-dev" suffix, so script/package_release.sh refuses to ship it
#   --placeholder  a package that cannot run (top directory oases-gateway_0.0.0-dev/, VERSION
#                  0.0.0-dev, a server.mjs that prints "placeholder gateway" and exits 1)
#   --dest         default: Sources/OasesCPA/Resources/Gateway
#
# Every package is checked before --dest is touched: exactly one top directory
# oases-gateway_<ver>/ whose VERSION file says <ver>, unpacked into a scratch directory under
# $OASES_SCRATCH (default ${TMPDIR:-/tmp}/oases-b-scratch) and scanned with
# script/check-no-private.sh --dir … --require-private-terms. Any finding, or a missing terms
# file, ends the run with a non-zero status and --dest unchanged.
#
# On success the new package is copied into --dest, every other oases-gateway_*.tar.gz there is
# moved to the Trash (${OASES_TRASH_DIR:-$HOME/.Trash}; nothing is deleted), and the values for
# GatewayBundle.bundled are printed:
#   version=<ver>
#   fileName=oases-gateway_<ver>.tar.gz
#   sha256=<64 hex>
#   server_commit=<sha>        (--server only; record it in docs/acceptance/supply-chain-pins.md)
#
# Scratch directories under $OASES_SCRATCH are left in place. Needs bash 3.2, tar, shasum or
# sha256sum, git (for --server) and node (for --server, through the Server's build script).

set -euo pipefail
export LC_ALL=C

PROG=vendor_gateway
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER="$ROOT_DIR/script/check-no-private.sh"
SCRATCH="${OASES_SCRATCH:-${TMPDIR:-/tmp}/oases-b-scratch}"
TRASH_DIR="${OASES_TRASH_DIR:-$HOME/.Trash}"
PLACEHOLDER_VERSION="0.0.0-dev"

fail() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 1
}

usage() {
  sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

MODE=""
TARBALL=""
CHECKSUMS=""
SERVER=""
DEST="$ROOT_DIR/Sources/OasesCPA/Resources/Gateway"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tarball) [ "$#" -ge 2 ] || usage; [ -z "$MODE" ] || usage; MODE=tarball; TARBALL="$2"; shift 2 ;;
    --checksums) [ "$#" -ge 2 ] || usage; CHECKSUMS="$2"; shift 2 ;;
    --server) [ "$#" -ge 2 ] || usage; [ -z "$MODE" ] || usage; MODE=server; SERVER="$2"; shift 2 ;;
    --placeholder) [ -z "$MODE" ] || usage; MODE=placeholder; shift ;;
    --dest) [ "$#" -ge 2 ] || usage; DEST="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$MODE" ] || usage
if [ "$MODE" = tarball ]; then
  [ -n "$CHECKSUMS" ] || fail "--tarball needs --checksums"
elif [ -n "$CHECKSUMS" ]; then
  usage
fi

mkdir -p "$SCRATCH"
WORK="$(mktemp -d "$SCRATCH/vendor-gateway.XXXXXX")"

# pack_dir <parent> <top directory name> <output tarball>: a tarball without the builder's user
# name, extended attributes or AppleDouble files.
pack_dir() {
  local parent="$1" top="$2" out="$3"
  if tar --version 2>/dev/null | grep -qi 'bsdtar'; then
    (cd "$parent" && COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --uname root --gname root --no-xattrs -czf "$out" "$top")
  else
    (cd "$parent" && tar --owner=0 --group=0 --numeric-owner -czf "$out" "$top")
  fi
}

case "$MODE" in
  tarball)
    [ -f "$TARBALL" ] || fail "no such package: $TARBALL"
    [ -f "$CHECKSUMS" ] || fail "no such checksums file: $CHECKSUMS"
    PACKAGE="$TARBALL"
    NAME="$(basename "$TARBALL")"
    EXPECTED="$(awk -v name="$NAME" '{ file = $2; sub(/^\*/, "", file); sub(/^\.\//, "", file); if (file == name) print $1 }' "$CHECKSUMS")"
    [ -n "$EXPECTED" ] || fail "checksums file has no line for $NAME"
    [ "$(printf '%s\n' "$EXPECTED" | wc -l | tr -d ' ')" = 1 ] || fail "checksums file has more than one line for $NAME"
    ACTUAL="$(sha256_of "$PACKAGE")"
    [ "$EXPECTED" = "$ACTUAL" ] || fail "SHA-256 of $NAME does not match its checksums line"
    ;;
  server)
    [ -d "$SERVER/.git" ] || [ -f "$SERVER/.git" ] || fail "not a git repository: $SERVER"
    [ -z "$(git -C "$SERVER" status --porcelain)" ] || fail "the Server work tree has uncommitted changes; build only from a committed HEAD"
    [ -z "$(git -C "$SERVER" ls-files --others --ignored --exclude-standard -- gateway/)" ] || fail "gateway/ in the Server repository holds ignored files; remove them first"
    SERVER_COMMIT="$(git -C "$SERVER" rev-parse HEAD)"
    # The committed tree only (no .git, no ignored files), with the -dev version.
    mkdir -p "$WORK/server"
    git -C "$SERVER" archive --format=tar HEAD | tar -xf - -C "$WORK/server"
    BASE_VERSION="$(tr -d '\n' < "$WORK/server/gateway/VERSION")"
    case "$BASE_VERSION" in *-dev) DEV_VERSION="$BASE_VERSION" ;; *) DEV_VERSION="$BASE_VERSION-dev" ;; esac
    printf '%s\n' "$DEV_VERSION" > "$WORK/server/gateway/VERSION"
    mkdir -p "$WORK/build-out"
    bash "$WORK/server/script/build-release.sh" --out "$WORK/build-out" >&2 || fail "the Server build script failed"
    PACKAGE="$WORK/build-out/oases-gateway_$DEV_VERSION.tar.gz"
    [ -f "$PACKAGE" ] || fail "the Server build produced no oases-gateway_$DEV_VERSION.tar.gz"
    NAME="$(basename "$PACKAGE")"
    EXPECTED="$(awk -v name="$NAME" '$2 == name { print $1 }' "$WORK/build-out/checksums.txt")"
    [ "$EXPECTED" = "$(sha256_of "$PACKAGE")" ] || fail "the Server build's checksums line does not match its package"
    ;;
  placeholder)
    TOP="oases-gateway_$PLACEHOLDER_VERSION"
    mkdir -p "$WORK/placeholder/$TOP"
    printf '%s\n' "$PLACEHOLDER_VERSION" > "$WORK/placeholder/$TOP/VERSION"
    printf '%s\n' \
      '// Placeholder gateway: this build of the app carries no real gateway package.' \
      "process.stderr.write('placeholder gateway\\n');" \
      'process.exit(1);' > "$WORK/placeholder/$TOP/server.mjs"
    chmod 0644 "$WORK/placeholder/$TOP/VERSION" "$WORK/placeholder/$TOP/server.mjs"
    PACKAGE="$WORK/$TOP.tar.gz"
    pack_dir "$WORK/placeholder" "$TOP" "$PACKAGE"
    NAME="$(basename "$PACKAGE")"
    ;;
esac

# The package: one top directory oases-gateway_<ver>/ that matches the file name and VERSION.
case "$NAME" in
  oases-gateway_*.tar.gz) ;;
  *) fail "package name must be oases-gateway_<ver>.tar.gz: $NAME" ;;
esac
VERSION="${NAME#oases-gateway_}"
VERSION="${VERSION%.tar.gz}"
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' || fail "not a semantic version: $VERSION"
LISTING="$WORK/listing.txt"
tar -tzf "$PACKAGE" > "$LISTING" || fail "not a readable tar.gz: $NAME"
TOPS="$(sed -e 's|^\./||' -e 's|/.*$||' "$LISTING" | sort -u)"
[ "$TOPS" = "oases-gateway_$VERSION" ] || fail "the package must hold exactly one top directory, oases-gateway_$VERSION/"
if grep -Eq '(^|/)\.\.(/|$)|^/' "$LISTING"; then
  fail "the package holds an absolute or parent-relative path"
fi
UNPACKED="$WORK/unpacked"
mkdir -p "$UNPACKED"
tar -xzf "$PACKAGE" -C "$UNPACKED" || fail "cannot unpack $NAME"
[ -f "$UNPACKED/oases-gateway_$VERSION/VERSION" ] || fail "the package has no VERSION file"
[ "$(tr -d '\n' < "$UNPACKED/oases-gateway_$VERSION/VERSION")" = "$VERSION" ] || fail "VERSION does not match the package name"
[ -f "$UNPACKED/oases-gateway_$VERSION/server.mjs" ] || fail "the package has no server.mjs"

# The shared scanner, with the private terms required.
# (run from the repository, where the default terms file script/private-terms.local resolves)
if ! (cd "$ROOT_DIR" && bash "$SCANNER" --dir "$UNPACKED" --require-private-terms >&2); then
  fail "the private-text scan of the package failed; --dest is unchanged"
fi

SHA256="$(sha256_of "$PACKAGE")"
mkdir -p "$DEST"
cp "$PACKAGE" "$DEST/$NAME.part.$$"
mv "$DEST/$NAME.part.$$" "$DEST/$NAME"
for old in "$DEST"/oases-gateway_*.tar.gz; do
  [ -e "$old" ] || continue
  [ "$(basename "$old")" = "$NAME" ] && continue
  mkdir -p "$TRASH_DIR"
  mv "$old" "$TRASH_DIR/$(basename "$old").$(date -u '+%Y%m%dT%H%M%SZ').$$"
done

printf 'version=%s\n' "$VERSION"
printf 'fileName=%s\n' "$NAME"
printf 'sha256=%s\n' "$SHA256"
if [ "$MODE" = server ]; then
  printf 'server_commit=%s\n' "$SERVER_COMMIT"
fi
