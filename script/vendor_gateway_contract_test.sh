#!/usr/bin/env bash
#
# Contract test of script/vendor_gateway.sh. Everything happens under $OASES_SCRATCH (default
# ${TMPDIR:-/tmp}/oases-b-scratch); nothing is deleted. The private terms file is a scratch file
# holding one term assembled at run time, so no real term is ever needed or printed.

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$SCRIPT_DIR/vendor_gateway.sh"
SCRATCH="${OASES_SCRATCH:-${TMPDIR:-/tmp}/oases-b-scratch}"
mkdir -p "$SCRATCH"
CASE_ROOT="$(mktemp -d "$SCRATCH/vendor-contract.XXXXXX")"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
failed() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*" >&2; }

TERM_SUFFIX="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
PLANTED="planted-term-$TERM_SUFFIX"
TERMS="$CASE_ROOT/terms.txt"
printf '%s\n' "$PLANTED" > "$TERMS"
export OASES_PRIVATE_TERMS_FILE="$TERMS"
export OASES_TRASH_DIR="$CASE_ROOT/trash"
export OASES_SCRATCH="$SCRATCH"

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# make_package <dir> <version> [<extra top directory>]: a fake package and its checksums.txt.
make_package() {
  local dir="$1" version="$2" extra="${3:-}" top="oases-gateway_$2"
  mkdir -p "$dir/src/$top"
  printf '%s\n' "$version" > "$dir/src/$top/VERSION"
  printf '%s\n' "console.log('fake gateway');" > "$dir/src/$top/server.mjs"
  printf '%s\n' "export const bootstrap = true;" > "$dir/src/$top/bootstrap.mjs"
  if [ -n "$extra" ]; then
    mkdir -p "$dir/src/$extra"
    printf 'x\n' > "$dir/src/$extra/file.txt"
    (cd "$dir/src" && COPYFILE_DISABLE=1 tar -czf "$dir/$top.tar.gz" "$top" "$extra")
  else
    (cd "$dir/src" && COPYFILE_DISABLE=1 tar -czf "$dir/$top.tar.gz" "$top")
  fi
  printf '%s  %s\n' "$(sha256_of "$dir/$top.tar.gz")" "$top.tar.gz" > "$dir/checksums.txt"
}

# listing <dir>: the names and hashes in <dir>, to prove that a refused run changed nothing.
listing() {
  (cd "$1" && find . -type f -exec shasum -a 256 {} + 2>/dev/null | sort)
}

run() {
  set +e
  OUTPUT="$("$@" 2>"$CASE_ROOT/stderr.txt")"
  STATUS=$?
  set -e
}

# 1. A package whose .mjs holds the planted term: refused, --dest unchanged.
CASE="$CASE_ROOT/planted"
make_package "$CASE" 9.9.1
printf '%s\n' "const where = '$PLANTED';" >> "$CASE/src/oases-gateway_9.9.1/server.mjs"
(cd "$CASE/src" && COPYFILE_DISABLE=1 tar -czf "$CASE/oases-gateway_9.9.1.tar.gz" oases-gateway_9.9.1)
printf '%s  %s\n' "$(sha256_of "$CASE/oases-gateway_9.9.1.tar.gz")" oases-gateway_9.9.1.tar.gz > "$CASE/checksums.txt"
mkdir -p "$CASE/dest"
printf 'old\n' > "$CASE/dest/oases-gateway_0.0.1.tar.gz"
BEFORE="$(listing "$CASE/dest")"
run bash "$VENDOR" --tarball "$CASE/oases-gateway_9.9.1.tar.gz" --checksums "$CASE/checksums.txt" --dest "$CASE/dest"
if [ "$STATUS" -ne 0 ] && [ "$(listing "$CASE/dest")" = "$BEFORE" ]; then pass; else failed "a planted term must be refused and --dest left unchanged"; fi
if grep -q "$PLANTED" "$CASE_ROOT/stderr.txt" || printf '%s' "$OUTPUT" | grep -q "$PLANTED"; then failed "the planted term was printed in full"; else pass; fi

# 2. A checksums line that does not match the package: refused.
CASE="$CASE_ROOT/mismatch"
make_package "$CASE" 9.9.2
printf '%s  %s\n' "$(printf '0%.0s' $(seq 1 64))" oases-gateway_9.9.2.tar.gz > "$CASE/checksums.txt"
mkdir -p "$CASE/dest"
run bash "$VENDOR" --tarball "$CASE/oases-gateway_9.9.2.tar.gz" --checksums "$CASE/checksums.txt" --dest "$CASE/dest"
if [ "$STATUS" -ne 0 ] && [ -z "$(ls -A "$CASE/dest")" ]; then pass; else failed "a checksum mismatch must be refused"; fi

# 3. Two top directories: refused.
CASE="$CASE_ROOT/two-tops"
make_package "$CASE" 9.9.3 stray-top
mkdir -p "$CASE/dest"
run bash "$VENDOR" --tarball "$CASE/oases-gateway_9.9.3.tar.gz" --checksums "$CASE/checksums.txt" --dest "$CASE/dest"
if [ "$STATUS" -ne 0 ] && [ -z "$(ls -A "$CASE/dest")" ]; then pass; else failed "two top directories must be refused"; fi

# 4. A missing terms file: refused.
CASE="$CASE_ROOT/no-terms"
make_package "$CASE" 9.9.4
mkdir -p "$CASE/dest"
run env OASES_PRIVATE_TERMS_FILE="$CASE/absent-terms.txt" bash "$VENDOR" --tarball "$CASE/oases-gateway_9.9.4.tar.gz" --checksums "$CASE/checksums.txt" --dest "$CASE/dest"
if [ "$STATUS" -ne 0 ] && [ -z "$(ls -A "$CASE/dest")" ]; then pass; else failed "a missing terms file must be refused"; fi

# 5. A clean package: accepted; the old package goes to the Trash, the printed values match.
CASE="$CASE_ROOT/clean"
make_package "$CASE" 9.9.5
mkdir -p "$CASE/dest"
printf 'old\n' > "$CASE/dest/oases-gateway_0.0.1.tar.gz"
run bash "$VENDOR" --tarball "$CASE/oases-gateway_9.9.5.tar.gz" --checksums "$CASE/checksums.txt" --dest "$CASE/dest"
if [ "$STATUS" -eq 0 ] && [ -f "$CASE/dest/oases-gateway_9.9.5.tar.gz" ]; then pass; else failed "a clean package must be accepted (status $STATUS)"; fi
EXPECTED_SHA="$(sha256_of "$CASE/oases-gateway_9.9.5.tar.gz")"
if printf '%s\n' "$OUTPUT" | grep -qx "sha256=$EXPECTED_SHA" \
  && printf '%s\n' "$OUTPUT" | grep -qx "version=9.9.5" \
  && printf '%s\n' "$OUTPUT" | grep -qx "fileName=oases-gateway_9.9.5.tar.gz" \
  && [ "$(sha256_of "$CASE/dest/oases-gateway_9.9.5.tar.gz")" = "$EXPECTED_SHA" ]; then pass; else failed "printed values must match the vendored file"; fi
if [ ! -e "$CASE/dest/oases-gateway_0.0.1.tar.gz" ] && ls "$OASES_TRASH_DIR" | grep -q '^oases-gateway_0.0.1.tar.gz\.'; then pass; else failed "the old package must move to the Trash"; fi

# 6. --server with uncommitted changes, and with an ignored file under gateway/: refused.
make_server() {
  local dir="$1"
  mkdir -p "$dir/gateway" "$dir/script"
  printf '9.9.6\n' > "$dir/gateway/VERSION"
  printf '%s\n' "console.log('fake');" > "$dir/gateway/server.mjs"
  printf 'data/\n' > "$dir/.gitignore"
  printf '#!/bin/bash\nexit 1\n' > "$dir/script/build-release.sh"
  git -C "$dir" init -q
  git -C "$dir" add -A
  git -C "$dir" -c user.name=Contract -c user.email=contract-test.invalid commit -q -m init
}
CASE="$CASE_ROOT/server-dirty"
make_server "$CASE/server"
printf '// local edit\n' >> "$CASE/server/gateway/server.mjs"
mkdir -p "$CASE/dest"
run bash "$VENDOR" --server "$CASE/server" --dest "$CASE/dest"
if [ "$STATUS" -ne 0 ] && grep -q "uncommitted" "$CASE_ROOT/stderr.txt" && [ -z "$(ls -A "$CASE/dest")" ]; then pass; else failed "--server must refuse a dirty work tree"; fi
CASE="$CASE_ROOT/server-ignored"
make_server "$CASE/server"
mkdir -p "$CASE/server/gateway/data"
printf '{}\n' > "$CASE/server/gateway/data/permissions.json"
mkdir -p "$CASE/dest"
run bash "$VENDOR" --server "$CASE/server" --dest "$CASE/dest"
if [ "$STATUS" -ne 0 ] && grep -q "ignored" "$CASE_ROOT/stderr.txt" && [ -z "$(ls -A "$CASE/dest")" ]; then pass; else failed "--server must refuse ignored files under gateway/"; fi

# 7. --placeholder: VERSION 0.0.0-dev, and its server.mjs exits non-zero.
CASE="$CASE_ROOT/placeholder"
mkdir -p "$CASE/dest" "$CASE/unpacked"
run bash "$VENDOR" --placeholder --dest "$CASE/dest"
if [ "$STATUS" -eq 0 ] && [ -f "$CASE/dest/oases-gateway_0.0.0-dev.tar.gz" ]; then pass; else failed "--placeholder must produce oases-gateway_0.0.0-dev.tar.gz"; fi
tar -xzf "$CASE/dest/oases-gateway_0.0.0-dev.tar.gz" -C "$CASE/unpacked"
if [ "$(cat "$CASE/unpacked/oases-gateway_0.0.0-dev/VERSION")" = "0.0.0-dev" ]; then pass; else failed "placeholder VERSION must be 0.0.0-dev"; fi
if command -v node >/dev/null 2>&1; then
  set +e
  node "$CASE/unpacked/oases-gateway_0.0.0-dev/server.mjs" 2>"$CASE/node-stderr.txt"
  NODE_STATUS=$?
  set -e
  if [ "$NODE_STATUS" -ne 0 ] && grep -q "placeholder gateway" "$CASE/node-stderr.txt"; then pass; else failed "the placeholder server.mjs must print 'placeholder gateway' and exit non-zero"; fi
else
  failed "node is required for the placeholder check"
fi
if tar -tvzf "$CASE/dest/oases-gateway_0.0.0-dev.tar.gz" | grep -q "$(id -un)"; then failed "the placeholder package must not carry the builder's user name"; else pass; fi

printf 'vendor_gateway contract: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
