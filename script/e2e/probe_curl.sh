#!/usr/bin/env bash
#
# probe_curl.sh - one management request to the probe engine (start_probe_engine.sh).
#
#   bash script/e2e/probe_curl.sh <method> <path> [curl arguments...]
#   bash script/e2e/probe_curl.sh GET /v0/management/config
#   bash script/e2e/probe_curl.sh PUT /v0/management/max-retry-credentials \
#        -H 'Content-Type: application/json' --data-binary @<0600 file>
#
# The key is read from "$OASES_SCRATCH/probe-engine/management-key" with the shell's `read`
# and handed to curl on stdin as a config line (`-K -`), so it is never in any process's
# arguments; the port comes from ".../probe-engine/port". Prints the response headers and the
# body (`-sS -D -`). Needs bash 3.2.

set -euo pipefail

SCRATCH="${OASES_SCRATCH:-${TMPDIR:-/tmp}/oases-b-scratch}"
SCRATCH="${SCRATCH%/}"
WORK="$SCRATCH/probe-engine"

[ "$#" -ge 2 ] || { printf '%s\n' 'usage: probe_curl.sh <method> <path> [curl arguments...]' >&2; exit 2; }
method="$1"; path="$2"; shift 2
case "$path" in /*) ;; *) printf '%s\n' 'probe_curl: the path starts with /' >&2; exit 2 ;; esac
[ -r "$WORK/management-key" ] && [ -r "$WORK/port" ] || {
  printf '%s\n' 'probe_curl: the probe engine has not been started (start_probe_engine.sh start)' >&2
  exit 1
}
IFS= read -r KEY < "$WORK/management-key" || true
IFS= read -r PORT < "$WORK/port" || true
case "$PORT" in ''|*[!0-9]*) printf '%s\n' 'probe_curl: no valid port file' >&2; exit 1 ;; esac
[ -n "$KEY" ] || { printf '%s\n' 'probe_curl: empty management key' >&2; exit 1; }

# printf is a shell builtin: the key goes to curl's stdin, never into argv. --noproxy '*':
# the request (and its key) never goes through an http_proxy/ALL_PROXY of the caller's shell.
printf 'header = "Authorization: Bearer %s"\n' "$KEY" \
  | curl -K - --noproxy '*' -sS -D - -X "$method" "http://127.0.0.1:$PORT$path" "$@"
