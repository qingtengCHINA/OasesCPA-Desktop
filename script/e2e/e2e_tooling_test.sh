#!/usr/bin/env bash
#
# e2e_tooling_test.sh - tests of the acceptance drill tools: script/e2e/mock-upstream.mjs and
# script/e2e/make_gateway_next.sh.
#
# Uses synthetic packages and random free loopback ports only (never 8317/18316/18317/18320 or
# 19101/19102). Scratch files stay under $OASES_SCRATCH. Every mock upstream it starts is
# stopped (SIGTERM, SIGKILL after 5 s). Needs bash 3.2, node (OASES_E2E_NODE, default: node on
# PATH), curl, tar, shasum.

set -u

REPO=$(cd "$(dirname "$0")/../.." && pwd -P)
MOCK="$REPO/script/e2e/mock-upstream.mjs"
NEXT="$REPO/script/e2e/make_gateway_next.sh"
NODE=${OASES_E2E_NODE:-node}
OASES_SCRATCH=${OASES_SCRATCH:-${TMPDIR:-/tmp}/oases-b-scratch}
export OASES_SCRATCH
mkdir -p "$OASES_SCRATCH" || { echo "cannot create $OASES_SCRATCH" >&2; exit 1; }
WORK=$(mktemp -d "$OASES_SCRATCH/e2e-tooling.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }
WORK=$(cd "$WORK" && pwd -P)
command -v "$NODE" >/dev/null 2>&1 || { echo "node not found (set OASES_E2E_NODE)" >&2; exit 1; }

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
expect_contains() { # <name> <haystack> <needle>
  case $2 in *"$3"*) ok "$1" ;; *) not_ok "$1" ;; esac
}
expect_not_contains() { # <name> <haystack> <needle>
  case $2 in *"$3"*) not_ok "$1" ;; *) ok "$1" ;; esac
}
json() { # <file or -> <js expression on v>
  "$NODE" -e 'const fs=require("fs");const v=JSON.parse(fs.readFileSync(process.argv[1]==="-"?0:process.argv[1],"utf8"));const r=(new Function("v","return ("+process.argv[2]+")"))(v);process.stdout.write(typeof r==="string"?r:JSON.stringify(r));' "$1" "$2"
}

# ------------------------------------------------------------------ make_gateway_next.sh

make_package() { # <dir> <version> [<top dir name>] [<VERSION content>]
  local dir=$1 version=$2 top=${3:-oases-gateway_$2} content=${4:-$2}
  mkdir -p "$dir/src/$top" || return 1
  printf '%s\n' "$content" >"$dir/src/$top/VERSION"
  printf "import fs from 'node:fs';\nconsole.log('gateway ' + fs.readFileSync(new URL('./VERSION', import.meta.url), 'utf8').trim());\n" >"$dir/src/$top/server.mjs"
  printf "console.log('bootstrap');\n" >"$dir/src/$top/bootstrap.mjs"
  COPYFILE_DISABLE=1 tar -czf "$dir/oases-gateway_$version.tar.gz" -C "$dir/src" "$top"
}

P="$WORK/pkg"
make_package "$P" 1.2.3 || { echo "cannot build the sample package" >&2; exit 1; }
input_sha=$(shasum -a 256 "$P/oases-gateway_1.2.3.tar.gz" | awk '{ print $1 }')
out=$(bash "$NEXT" "$P/oases-gateway_1.2.3.tar.gz" --out-dir "$P" 2>"$WORK/next.err")
expect_status "make_gateway_next exits 0" 0 $?
tarball=$(printf '%s\n' "$out" | sed -n 's/^OASES_E2E_GATEWAY_TARBALL=//p')
sha=$(printf '%s\n' "$out" | sed -n 's/^OASES_E2E_GATEWAY_SHA256=//p')
version=$(printf '%s\n' "$out" | sed -n 's/^OASES_E2E_GATEWAY_VERSION=//p')
expect_equal "it prints exactly three lines" 3 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
expect_equal "the patch number goes up by one" 1.2.4 "$version"
expect_equal "the package is named for the new version" "$P/oases-gateway_1.2.4.tar.gz" "$tarball"
expect_equal "the printed SHA-256 is the package's" "$(shasum -a 256 "$tarball" | awk '{ print $1 }')" "$sha"
expect_equal "the input package is unchanged" "$input_sha" "$(shasum -a 256 "$P/oases-gateway_1.2.3.tar.gz" | awk '{ print $1 }')"
expect_equal "one top directory named for the new version" oases-gateway_1.2.4 \
  "$(tar -tzf "$tarball" | sed -e 's|^\./||' -e 's|/.*$||' | sort -u)"
X="$WORK/extracted"
mkdir -p "$X" && tar -xzf "$tarball" -C "$X"
expect_equal "VERSION holds the new version" 1.2.4 "$(cat "$X/oases-gateway_1.2.4/VERSION")"
expect_contains "server.mjs starts with the e2e marker" "$(head -n 1 "$X/oases-gateway_1.2.4/server.mjs")" "oases-e2e: make_gateway_next.sh"
expect_contains "the original server.mjs follows" "$(cat "$X/oases-gateway_1.2.4/server.mjs")" "console.log('gateway '"
expect_equal "bootstrap.mjs is unchanged" "console.log('bootstrap');" "$(cat "$X/oases-gateway_1.2.4/bootstrap.mjs")"
DATA="$WORK/data"
mkdir -p "$DATA"
started=$(OASES_DATA_DIR="$DATA" "$NODE" "$X/oases-gateway_1.2.4/server.mjs" 2>&1)
expect_equal "the patched server still runs and reads the new VERSION" "gateway 1.2.4" "$started"
expect_equal "the patched server writes e2e-format.json into OASES_DATA_DIR" '{"format":2}' "$(cat "$DATA/e2e-format.json" 2>/dev/null)"
mode=$(stat -f '%Lp' "$DATA/e2e-format.json" 2>/dev/null || stat -c '%a' "$DATA/e2e-format.json")
expect_equal "e2e-format.json is private (0600)" 600 "$mode"
( unset OASES_DATA_DIR; "$NODE" "$X/oases-gateway_1.2.4/server.mjs" >/dev/null 2>&1 )
expect_status "without OASES_DATA_DIR the server starts without writing" 0 $?

bash "$NEXT" "$P/oases-gateway_1.2.3.tar.gz" --out-dir "$P" >/dev/null 2>&1
expect_status "an existing output package is not overwritten" 2 $?
bash "$NEXT" "$tarball" >/dev/null 2>&1
expect_status "a package that already carries the marker is refused" 2 $?

B1="$WORK/bad-name"; mkdir -p "$B1"; make_package "$B1" 1.0.0 && mv "$B1/oases-gateway_1.0.0.tar.gz" "$B1/gateway.tar.gz"
bash "$NEXT" "$B1/gateway.tar.gz" >/dev/null 2>&1
expect_status "a wrong file name is refused" 2 $?
B2="$WORK/bad-top"; make_package "$B2" 1.0.0 other-dir
bash "$NEXT" "$B2/oases-gateway_1.0.0.tar.gz" >/dev/null 2>&1
expect_status "another top directory is refused" 2 $?
B3="$WORK/bad-version"; make_package "$B3" 1.0.0 oases-gateway_1.0.0 9.9.9
bash "$NEXT" "$B3/oases-gateway_1.0.0.tar.gz" >/dev/null 2>&1
expect_status "a VERSION that differs from the file name is refused" 2 $?
B4="$WORK/pre"; make_package "$B4" 1.0.0-dev
bash "$NEXT" "$B4/oases-gateway_1.0.0-dev.tar.gz" >/dev/null 2>&1
expect_status "a prerelease version is refused" 2 $?

# ------------------------------------------------------------------ mock-upstream.mjs

MOCK_PIDS=""
stop_mocks() {
  local pid
  for pid in $MOCK_PIDS; do kill -TERM "$pid" 2>/dev/null; done
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    alive=0
    for pid in $MOCK_PIDS; do kill -0 "$pid" 2>/dev/null && alive=1; done
    [ "$alive" -eq 0 ] && break
    sleep 0.5
  done
  for pid in $MOCK_PIDS; do kill -KILL "$pid" 2>/dev/null; done
}
trap stop_mocks EXIT

start_mock() { # <name> <log prefix> [--fail]; sets MOCK_PORT and MOCK_PID
  "$NODE" "$MOCK" --port 0 --name "$1" ${3:+"$3"} >"$WORK/$2.out" 2>"$WORK/$2.err" &
  MOCK_PID=$!
  MOCK_PIDS="$MOCK_PIDS $MOCK_PID"
  MOCK_PORT=
  for _ in $(seq 1 50); do
    MOCK_PORT=$(sed -n 's|^mock-upstream .* listening on http://127\.0\.0\.1:\([0-9]*\)/v1$|\1|p' "$WORK/$2.err")
    [ -n "$MOCK_PORT" ] && return 0
    sleep 0.1
  done
  return 1
}

UPSTREAM_SECRET="synthetic-upstream-$(printf '%s' credential)-0000"
chat() { # <port> <body file> <out file>; prints the status
  printf 'header = "Authorization: Bearer %s"\n' "$UPSTREAM_SECRET" \
    | curl -sS -K - -o "$3" -w '%{http_code}' -H 'Content-Type: application/json' \
      --data-binary @"$2" "http://127.0.0.1:$1/v1/chat/completions"
}

start_mock a mock-a || not_ok "mock a did not report its port"
printf '{"model":"glm-5","messages":[{"role":"user","content":"hi"}]}' >"$WORK/chat.json"
printf '{"model":"mock-chat","stream":true,"messages":[{"role":"user","content":"hi"}]}' >"$WORK/stream.json"

status=$(curl -sS -o "$WORK/models.json" -w '%{http_code}' "http://127.0.0.1:$MOCK_PORT/v1/models")
expect_equal "GET /v1/models answers 200" 200 "$status"
expect_equal "/v1/models lists glm-5 and mock-chat" '["glm-5","mock-chat"]' "$(json "$WORK/models.json" 'v.data.map(m => m.id)')"
expect_equal "/v1/models names the provider as owner" a "$(json "$WORK/models.json" 'v.data[0].owned_by')"

status=$(chat "$MOCK_PORT" "$WORK/chat.json" "$WORK/chat-a.json")
expect_equal "POST /v1/chat/completions answers 200" 200 "$status"
expect_equal "the answer names the provider" served-by:a "$(json "$WORK/chat-a.json" 'v.choices[0].message.content')"
expect_equal "the answer echoes the model" glm-5 "$(json "$WORK/chat-a.json" 'v.model')"
expect_equal "usage is 10 prompt and 5 completion tokens" '{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}' "$(json "$WORK/chat-a.json" 'v.usage')"
expect_equal "it is not streamed" chat.completion "$(json "$WORK/chat-a.json" 'v.object')"

status=$(chat "$MOCK_PORT" "$WORK/stream.json" "$WORK/stream-a.txt")
expect_equal "a stream: true request answers 200" 200 "$status"
expect_contains "the stream carries the provider name" "$(cat "$WORK/stream-a.txt")" 'served-by:a'
expect_contains "the stream ends with [DONE]" "$(cat "$WORK/stream-a.txt")" 'data: [DONE]'

status=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$MOCK_PORT/v1/embeddings")
expect_equal "another path answers 404" 404 "$status"

sleep 0.2
log=$(cat "$WORK/mock-a.out")
expect_equal "one log line per request" 4 "$(printf '%s\n' "$log" | grep -c '^{')"
expect_contains "the log names method, path, model and status" "$log" '{"name":"a","method":"POST","path":"/v1/chat/completions","model":"glm-5","status":200}'
expect_not_contains "the log never holds the upstream credential" "$log$(cat "$WORK/mock-a.err")" "$UPSTREAM_SECRET"

start_mock b mock-b --fail || not_ok "mock b did not report its port"
status=$(chat "$MOCK_PORT" "$WORK/chat.json" "$WORK/chat-b.json")
expect_equal "--fail answers 500" 500 "$status"
expect_contains "the 500 names the provider" "$(json "$WORK/chat-b.json" 'v.error.message')" "b answers 500"
status=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:$MOCK_PORT/v1/models")
expect_equal "--fail still lists the models" 200 "$status"

kill -TERM "$MOCK_PID"
wait "$MOCK_PID"
expect_status "SIGTERM stops the mock with exit 0" 0 $?

"$NODE" "$MOCK" --name a >/dev/null 2>&1
expect_status "a missing --port is a usage error" 2 $?
"$NODE" "$MOCK" --port 0 --name 'a b' >/dev/null 2>&1
expect_status "a bad --name is a usage error" 2 $?

stop_mocks
trap - EXIT
leftover=0
for pid in $MOCK_PIDS; do kill -0 "$pid" 2>/dev/null && leftover=1; done
expect_equal "no mock upstream is left running" 0 "$leftover"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
