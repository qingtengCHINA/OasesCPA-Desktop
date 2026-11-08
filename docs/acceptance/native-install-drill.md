# Fresh native install drill with the real packages (Task 8)

Recorded 2026-11-08 on an Apple-silicon Mac (macOS, `/bin/bash` 3.2.57). `<scratch>` is the
session's scratch directory, `<install>` the scratch install root of the drill.

## How it ran

`NativeInstallRealArtifactsTests.testRealPackagesInstallBootstrapAndAnswerHealthChecks`
(opt-in; skipped unless `OASES_E2E_REAL_ARTIFACTS` names a directory with the pinned packages):

- The script is the app's real fresh-install script (`DeploymentExecutor.scriptForVerification`
  with `DeploymentPinSet.current` and the bundled gateway 0.1.0), only with four random free
  loopback ports instead of 8317/18320/18316/18317 (`DeploymentScriptPorts`); the fixed ports
  were checked free with `lsof` before and were never bound.
- Packages: the pinned darwin/arm64 engine v8.0.51, CPA Manager Plus v1.14.10 and Node v24.22.2
  (the files recorded in `supply-chain-pins.md`), served to the script by a curl shim from a
  local directory: nothing was downloaded during the drill. Every other HTTPS request of the
  shim was refused; loopback requests went to `/usr/bin/curl`.
- Install root `<install>` and `HOME` under `<scratch>`; the started programs got a closed
  loopback port as `HTTPS_PROXY`/`HTTP_PROXY` (loopback in `NO_PROXY`), and the gateway
  `MODEL_CATALOG_URL=off`.
- All three processes were stopped at the end (SIGTERM, SIGKILL after 30 s if needed);
  `ps` showed none of them afterwards.

## Result

Exit 0 in about 6 seconds. Stages in the deployment log, in order: prepare,
secure-directories, resolve/download/verify/install for the engine and the panel backend,
install-node, install-gateway, bootstrap-gateway, configure-cli, start-cli, wait-cli,
start-cpamp, wait-cpamp, start-gateway, wait-gateway, finalize.

- `.oases-cpa-versions`: `{"engine":"v8.0.51","cpamp":"v1.14.10","node":"v24.22.2","gateway":"0.1.0"}`
  (one key per line).
- The real `bootstrap.mjs` exited 0 with its one-line JSON summary (no key material) in the
  deployment log; `gateway-data/permissions.json`, `secrets/pack-engine-key` and
  `secrets/pack-store-key` are mode 0600, `gateway-data` and `secrets` 0700.
- `GET /healthz` on the admin port: 200 `{"ok":true,"version":"0.1.0"}`; the same path on the
  API port: 404 (split mode). `GET /cpa-admin/host/status` with `x-management-key`: 200 and it
  names v8.0.51 and v1.14.10 (from `HOST_STATUS_ENGINE_VERSION` / `HOST_STATUS_PANEL_VERSION`).
- The engine answered `/v0/management/config` with the management key on its own port; CPA
  Manager Plus answered `/health`.
- The engine rewrote `config.yaml` on start (blank lines dropped, `secret-key` replaced by its
  bcrypt hash) and kept the legacy layout the gateway reads: top-level `api-keys` with the
  internal key, `response-compression.enabled: false` (R14).
- None of the four generated keys appeared in `ps -axww` output, in `logs/deployment.log` or in
  the argv of any curl call; the readiness checks passed the key as `-K -` on stdin.
- `ps` showed the gateway as `<install>/node/current/bin/node
  <install>/gateway/current/server.mjs`, the engine and the panel under `<install>/…/runtime/`.
- The engine's own update checks at start (Antigravity version service, npm registry) failed
  against the refusing proxy and only logged warnings.

## Not covered

- CPA Manager Plus collecting usage through the engine, and a `/v1` request through the gateway
  (no upstream provider and no client key exist in a fresh install).
- `disable-control-panel: true` (L3) was not probed; the install keeps `false`.
- darwin/amd64 and Linux (no packages for them were downloaded).
