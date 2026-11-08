#!/usr/bin/env bash
#
# start_probe_engine.sh - a throw-away local CLIProxyAPI engine for endpoint measurements.
#
#   bash script/e2e/start_probe_engine.sh start --archive <CLIProxyAPI_*_darwin_*.tar.gz>
#   bash script/e2e/start_probe_engine.sh status
#   bash script/e2e/start_probe_engine.sh stop
#
# Everything lives in "$OASES_SCRATCH/probe-engine" (default
# "${TMPDIR:-/tmp}/oases-b-scratch/probe-engine"), mode 0700:
#   engine-<tag>/cli-proxy-api  the binary, unpacked from the pinned archive
#   config.yaml                 legacy layout (top-level api-keys, remote-management.secret-key)
#   management-key              the management key (0600; never on a command line)
#   port                        the random free loopback port the engine listens on
#   engine.pid, engine.log      the process
#   auths/, home/, tmp/         an empty auth dir, a scratch HOME and TMPDIR
#
# The archive is never downloaded here: pass the one already on disk with --archive; its
# SHA-256 must equal the pin below (the same values as DeploymentPinSet.current.engine), or
# nothing is started (exit 1). The engine listens on 127.0.0.1 only. Its HTTP(S) proxy points
# at a loopback port nobody listens on, so the version lookups it makes at start (an npm
# package and a version manifest) are refused locally and nothing leaves the machine.
#
# stop signals only the process in engine.pid whose command line contains the work directory,
# SIGTERM then SIGKILL after 10 s; the directory stays (it is scratch). Needs bash 3.2.
#
# Exit codes: 0 done / running; 1 refused or failed; 2 usage; 3 status: not running.

set -euo pipefail
umask 077

ENGINE_TAG="v8.0.51"
ENGINE_ASSET_darwin_arm64="CLIProxyAPI_8.0.51_darwin_aarch64.tar.gz"
ENGINE_SHA256_darwin_arm64="fb8e2568e98e3304a1b892c4f70a4c154c661078ad87007e63cf7ba71b4ce168"
ENGINE_ASSET_darwin_amd64="CLIProxyAPI_8.0.51_darwin_amd64.tar.gz"
ENGINE_SHA256_darwin_amd64="7f68be928979c3991d097255fd8fb732edc684e72fe10faf29a365e44246cedb"

SCRATCH="${OASES_SCRATCH:-${TMPDIR:-/tmp}/oases-b-scratch}"
SCRATCH="${SCRATCH%/}"
WORK="$SCRATCH/probe-engine"

fail() { printf 'start_probe_engine: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  printf '%s\n' 'usage: start_probe_engine.sh start --archive <path> | stop | status' >&2
  exit 2
}

platform() {
  local os arch
  os="$(uname -s)"; arch="$(uname -m)"
  [ "$os" = "Darwin" ] || fail "only macOS (darwin) archives are pinned here, not $os"
  case "$arch" in
    arm64|aarch64) printf '%s' darwin_arm64 ;;
    x86_64|amd64) printf '%s' darwin_amd64 ;;
    *) fail "no pinned engine for $arch" ;;
  esac
}

# The pid of the probe engine when it runs: the process in engine.pid whose command line
# contains the work directory. Anything else in the pid file is not ours.
owned_pid() {
  local pid command
  [ -f "$WORK/engine.pid" ] || return 1
  IFS= read -r pid < "$WORK/engine.pid" || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" -gt 1 ] || return 1
  command="$(ps -p "$pid" -o command= 2>/dev/null)" || return 1
  case "$command" in
    *"$WORK/"*) printf '%s' "$pid" ;;
    *) return 1 ;;
  esac
}

listening() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

# A random loopback port in 20000-49999 that nothing listens on (the product's fixed ports
# 8317, 18316, 18317 and 18320 are outside that range).
free_port() {
  local port tries=0
  while [ "$tries" -lt 200 ]; do
    port=$(( (RANDOM % 30000) + 20000 ))
    tries=$((tries + 1))
    [ "$port" != "${1:-}" ] || continue
    if ! listening "$port"; then printf '%s' "$port"; return 0; fi
  done
  return 1
}

start() {
  local archive="" key platform_id asset_var sha_var asset expected actual bin port trap_port pid quoted_work
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --archive) [ "$#" -ge 2 ] || usage; archive="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$archive" ] || fail "pass the engine archive with --archive <path> (it is not downloaded here)" 2
  [ -f "$archive" ] || fail "no archive at $archive"
  if pid="$(owned_pid)"; then fail "the probe engine already runs (pid $pid); stop it first"; fi

  platform_id="$(platform)"
  asset_var="ENGINE_ASSET_$platform_id"; sha_var="ENGINE_SHA256_$platform_id"
  asset="${!asset_var}"; expected="${!sha_var}"
  [ "$(basename "$archive")" = "$asset" ] || fail "the archive for this Mac is $asset, not $(basename "$archive")"
  actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || fail "SHA-256 mismatch for $asset (expected the pinned value): nothing started"

  mkdir -p "$WORK"
  chmod 700 "$WORK"
  mkdir -p "$WORK/engine-$ENGINE_TAG" "$WORK/auths" "$WORK/home" "$WORK/tmp"
  [ -z "$(ls -A "$WORK/auths")" ] || fail "$WORK/auths is not empty"
  tar -xzf "$archive" -C "$WORK/engine-$ENGINE_TAG" cli-proxy-api
  bin="$WORK/engine-$ENGINE_TAG/cli-proxy-api"
  [ -x "$bin" ] || fail "the archive has no executable cli-proxy-api"

  port="$(free_port)" || fail "no free loopback port found"
  trap_port="$(free_port "$port")" || fail "no free loopback port found"
  printf '%s\n' "$port" > "$WORK/port"

  key="$(openssl rand -hex 32)"
  printf '%s\n' "$key" > "$WORK/management-key"
  chmod 600 "$WORK/management-key"
  quoted_work="$(printf '%s' "$WORK" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  {
    printf '%s\n' '# Probe engine (start_probe_engine.sh): legacy layout, loopback only.'
    printf '%s\n' 'host: "127.0.0.1"'
    printf 'port: %s\n' "$port"
    printf 'auth-dir: "%s/auths"\n' "$quoted_work"
    printf '%s\n' 'api-keys: []'
    printf '%s\n' 'remote-management:'
    printf '%s\n' '  allow-remote: false'
    printf '  secret-key: "%s"\n' "$key"
    printf '%s\n' '  disable-control-panel: true'
    printf '%s\n' 'response-compression:'
    printf '%s\n' '  enabled: false'
  } > "$WORK/config.yaml"
  chmod 600 "$WORK/config.yaml"
  key=""

  # The environment is built from scratch: no inherited proxy, HOME or credentials. The engine
  # resolves its relative `logs` directory against its working directory, so it runs inside the
  # work directory (never the caller's, for example the repository).
  cd "$WORK" || fail "cannot enter $WORK"
  nohup env -i \
    PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    HOME="$WORK/home" \
    TMPDIR="$WORK/tmp/" \
    HTTPS_PROXY="http://127.0.0.1:$trap_port" HTTP_PROXY="http://127.0.0.1:$trap_port" \
    https_proxy="http://127.0.0.1:$trap_port" http_proxy="http://127.0.0.1:$trap_port" \
    ALL_PROXY="http://127.0.0.1:$trap_port" all_proxy="http://127.0.0.1:$trap_port" \
    NO_PROXY="127.0.0.1,localhost" no_proxy="127.0.0.1,localhost" \
    "$bin" -config "$WORK/config.yaml" -local-model \
    > "$WORK/engine.log" 2>&1 < /dev/null &
  pid=$!
  printf '%s\n' "$pid" > "$WORK/engine.pid"

  local waited=0
  while [ "$waited" -lt 30 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      fail "the engine exited during start; see $WORK/engine.log"
    fi
    if curl -fsS --max-time 2 "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
      printf 'probe engine %s running: pid %s, http://127.0.0.1:%s\n' "$ENGINE_TAG" "$pid" "$port"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  stop >/dev/null 2>&1 || true
  fail "the engine did not answer /healthz within 30 s; stopped; see $WORK/engine.log"
}

stop() {
  local pid waited=0
  if ! pid="$(owned_pid)"; then
    if [ -f "$WORK/engine.pid" ]; then
      printf '%s\n' 'start_probe_engine: engine.pid does not name a running probe engine; nothing was signalled.' >&2
    else
      printf '%s\n' 'start_probe_engine: not running.' >&2
    fi
    return 0
  fi
  kill -TERM "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 10 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
  printf 'probe engine stopped (pid %s); %s is kept\n' "$pid" "$WORK"
}

status() {
  local pid port=""
  if pid="$(owned_pid)"; then
    [ ! -f "$WORK/port" ] || IFS= read -r port < "$WORK/port" || true
    printf 'running: pid %s, http://127.0.0.1:%s\n' "$pid" "$port"
    return 0
  fi
  printf '%s\n' 'stopped'
  return 3
}

[ "$#" -ge 1 ] || usage
command="$1"; shift
case "$command" in
  start) start "$@" ;;
  stop) [ "$#" -eq 0 ] || usage; stop ;;
  status) [ "$#" -eq 0 ] || usage; status ;;
  *) usage ;;
esac
