# CLIProxyAPI v8.0.51 endpoint probe

Measurements against the real engine binary, for the app's management requests (plan Tasks
19-21). Paths are written as `<scratch>` (`$OASES_SCRATCH`); no host names, user names or keys
appear here.

## Setup

- `bash script/e2e/start_probe_engine.sh start --archive <scratch>/…/CLIProxyAPI_8.0.51_darwin_aarch64.tar.gz`:
  the archive's SHA-256 equals the pin (`fb8e2568…ce168`, the same value as
  `DeploymentPinSet.current.engine`); the binary reports `CLIProxyAPI Version: 8.0.51,
  Commit: 7cad1cb7`.
- Work directory `<scratch>/probe-engine` (0700): config in the legacy layout (top-level
  `api-keys: []`, `remote-management.secret-key`, `allow-remote: false`,
  `disable-control-panel: true`, `response-compression.enabled: false`), empty `auths/`,
  scratch `HOME` and `TMPDIR`, a random free port on 127.0.0.1 written to `port`.
- `lsof` showed one listener, `127.0.0.1:<port>` (IPv4 loopback only). `GET /healthz` answered
  within the 30 s window.
- No egress: the engine's HTTP(S) proxy points at a loopback port with no listener. Its
  start-up lookups (the Grok CLI package on registry.npmjs.org and an Antigravity version
  manifest) failed locally with `connection refused` and the engine kept its fallback versions;
  it logs that both lookups repeat every 3 h.
- Requests through `bash script/e2e/probe_curl.sh <method> <path> …` (key on curl's stdin).
  Stopped with `start_probe_engine.sh stop`; `ps` afterwards showed no engine process.

Run 2026-11-08, macOS arm64.

## Results

Filled by the tasks that measure (Tasks 19-21); a row that could not be measured says "not
measured" and why.

| Endpoint | Request | Status | Response headers or body shape | Conclusion |
|---|---|---|---|---|
