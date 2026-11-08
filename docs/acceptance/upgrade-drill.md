# Upgrade and rollback drill with the real packages (Task 10)

Recorded 2026-11-08 on an Apple-silicon Mac (macOS, `/bin/bash` 3.2.57). `<scratch>` is the
session's scratch directory, `<install>` the scratch install root of the drill.

## How it ran

`NativeInstallRealArtifactsTests.testRealUpgradeRollbackAndApiKeysScript` (opt-in; skipped
unless `OASES_E2E_REAL_ARTIFACTS` names a directory with the pinned packages), with the same
isolation as the install drill (`native-install-drill.md`): the pinned darwin/arm64 engine
v8.0.51, CPA Manager Plus v1.14.10 and Node v24.22.2 served by a curl shim from a local
directory (nothing downloaded, every other HTTPS request refused), the bundled gateway 0.1.0,
four random free loopback ports (the fixed ports were checked free with `lsof` before and
after and were never bound), a scratch `HOME`, a closed loopback port as `HTTPS_PROXY`, and
`MODEL_CATALOG_URL=off`.

1. The app's fresh-install script into `<install>`.
2. The app's native upgrade script with the same pins (equal versions pass the no-downgrade
   guard): stop of all three processes (gateway first), backup `backups/upgrade-<time>/`
   with `gateway-data/`, reinstall of engine, CPA Manager Plus, Node and gateway, bootstrap,
   start, wait.
3. The migration's inline api-keys script (`DeploymentMaintenanceService.apiKeysMigrationScript`)
   with the real Node against the real engine, the keys only in its environment and a synthetic
   extra key as `PACK_ENGINE_KEY`.
4. The app's native rollback script.

## Result

- Upgrade: exit 0, `OASES_CPA_TOPOLOGY=gateway`; the backup's `gateway-data/permissions.json`
  equals the file before the upgrade byte for byte; `GET /healthz` on the admin port 200 with
  version 0.1.0 afterwards.
- Inline api-keys script: exit 0 with real Node 24 `fetch`. `GET /v0/management/api-keys`
  answered `{"api-keys":[…]}`, the PUT of a JSON array was accepted, and the list afterwards held
  both the gateway's internal key and the synthetic key; the engine persisted the PUT into
  `config.yaml` and kept the top-level `api-keys:` layout (R14). The script's output held no key.
- Rollback: exit 0, `OASES_CPA_TOPOLOGY=gateway`; `config.yaml` came back from the backup
  (without the synthetic key), `gateway-data/permissions.json` equals the original; `/healthz`
  200 and the engine's management API 200 afterwards.
- No generated key appeared in `ps -axww`, in the curl shim's argv log, or in the upgrade and
  rollback output (the install's fd-3 result lines carry the management and admin keys to the
  app by design).
- Everything the drill started was stopped at the end; `ps` showed none of it afterwards.

Not covered by this drill: the 0.1.x → gateway migration with real packages; it has its own
drill since 2026-11-08 (`legacy-migration-drill.md`, random ports including the legacy engine
port).
