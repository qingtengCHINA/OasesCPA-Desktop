# Legacy 0.1.x → full edition migration drill with the real packages

Recorded 2026-11-08 on an Apple-silicon Mac (macOS, `/bin/bash` 3.2.57). `<scratch>` is the
session's scratch directory, `<install>` the scratch install root of the drill. No key, host name
or real path of the owner's machine appears here.

## How it ran

`NativeInstallRealArtifactsTests.testRealLegacyMigrationAndRollback` (opt-in; skipped unless
`OASES_E2E_REAL_ARTIFACTS` names a directory with the pinned packages), with the isolation of the
install drill (`native-install-drill.md`): the pinned darwin/arm64 engine v8.0.51, CPA Manager Plus
v1.14.10 and Node v24.22.2 (SHA-256 checked against `DeploymentPinSet.current` before the run:
`fb8e2568…ce168`, `3a8df00d…e4872`, `aa954934…f385a`) served by a curl shim from a local directory
(nothing downloaded, every other HTTPS request refused), the bundled gateway 0.1.0 (`6a6e1a85…d22b`),
a scratch `HOME`, a closed loopback port as `HTTPS_PROXY`, `MODEL_CATALOG_URL=off`.

Ports: SIX random free loopback ports (gateway API, gateway admin, engine, CPA Manager Plus, the
legacy engine port, the mock upstream). The migration rewrites the line `port: <legacy port>` of the
engine config; that port is now a parameter of the script (`DeploymentScriptPorts.legacyEngine`,
8317 for every real deployment), so every phase, the binding ones included, ran on random ports.
Nothing in the drill bound, contacted or stopped 8317, 18316, 18317 or 18320. `lsof -iTCP:8317,18316,
18317,18320 -sTCP:LISTEN` before and after the drill showed the same two listeners of another
deployment (8317 and 18317, not part of the drill), with the same process ids.

### The 0.1.x fixture (`<install>`, mode 0700 in a 0700 parent)

The layout of a real 0.1.x deployment (names only were taken from one):

- `.oases-cpa-installed` and NO `.oases-cpa-managed`; `secrets/cpa-management-key`,
  `secrets/cpamp-admin-key` (0600, directory 0700); `logs/cli-proxy-api.log`,
  `logs/cpa-manager-plus.log`; the pid files written by the app's own start script.
- `cli-proxy-api/{auths/,config.yaml,downloads/CLIProxyAPI_7.2.113_darwin_aarch64.tar.gz,logs/,run.sh,runtime/CLIProxyAPI_7.2.113_darwin_aarch64/}`.
  The 0.1.x engine is a stub (no old package is available here): a bash script under the runtime
  directory with a Node child that serves `/v0/management/*` for the management key and
  `/v1/models` for the client keys on the legacy port.
- `config.yaml` with the owner's top-level keys in their order: `host: "127.0.0.1"`, `port`,
  `remote-management` (`allow-remote: false`, `secret-key` as a bcrypt hash, as a running engine
  leaves it), `auth-dir`, `api-keys` (two client keys), `usage-statistics-enabled`,
  `credential-concurrency: {}`, `credential-in-flight: {}`,
  `redis-usage-queue-retention-seconds`, `ws-auth`, and `openai-compatibility` with one provider
  (`drill-mock`, `base-url` = a loopback mock upstream, one `api-key-entries` key, model
  `drill-upstream-model` aliased `drill-model`). The value types of the two `credential-*` blocks
  are a guess (empty maps); the real file's values were not read.
- `auths/` with two synthetic auth files (types `codex` and `claude`, expiry in 2099).
- `cpamp/{data/,downloads/cpa-manager-plus_v1.11.11_darwin_arm64.tar.gz,run.sh,runtime/cpa-manager-plus_v1.11.11_darwin_arm64/}`
  with a stub panel (answers `/health`) and its `config.json` inside the runtime directory, like
  0.1.x. `cpamp/data/`: `data.key` (32 random bytes, raw base64, the format CPA Manager Plus
  writes), `usage-imports/import-drill.json`, and `usage.sqlite` + `-wal` + `-shm` copied while
  the writing connection was open: an `usage_events` table WITHOUT the account-snapshot columns
  that v1.14 adds, three rows that live only in the WAL.

## Result

1. Upgrade (the app's native upgrade script, legacy branch): exit 0 in about 6 s, result lines
   `OASES_PACK_ENGINE_KEY_SHA256`, `OASES_CPA_BACKUP`, `OASES_CPA_TOPOLOGY=gateway`,
   `OASES_CPA_MAINTENANCE_DETAIL`.
2. Backup `backups/upgrade-<time>/` (mode 0700): `backup-started`, `backup-complete`,
   `cli-proxy-api-config.yaml`, `cli-proxy-api-run.sh`, `cli-proxy-api-runtime/`, `cpamp-run.sh`,
   `cpamp-runtime/`, `versions.absent`, and new in this round `cpamp-data/` (+ `cpamp-data.saved`),
   `secrets/` (+ `secrets.saved`), `root-files/` with `.oases-cpa-installed`, `cli-proxy-api.pid`,
   `cpa-manager-plus.pid` and `managed-marker.absent`. `cpamp-data/`, `secrets/` and the config
   equal the originals byte for byte.
3. Config rewrite: still the legacy layout (R14). Top-level keys afterwards: `host port
   remote-management auth-dir api-keys usage-statistics-enabled credential-concurrency
   credential-in-flight redis-usage-queue-retention-seconds ws-auth openai-compatibility
   response-compression discovery disable-cooling request-retry` (the engine appended the last
   three itself on start). Both client keys and the gateway's internal key are under `api-keys`
   (the inline api-keys script reported 3 keys); the provider is unchanged; no `config-version`.
   The real v8.0.51 engine accepted the bcrypt `secret-key` written by the old layout (the
   management API answered with the key from `secrets/`).
4. The two auth files are byte for byte unchanged after the upgrade.
5. `.oases-cpa-managed` = `owned-by=oases-cpa`, mode 0600, written after the health checks.
6. Order: start times engine 12:37:51, CPA Manager Plus 12:37:53, gateway 12:37:53 (`ps -o
   lstart`, one-second resolution): the engine started alone first on its new port, then the two
   others.
7. `GET /healthz` on the admin port: 200 `{"ok":true,"version":"0.1.0"}`.
8. Through the gateway API port with an EXISTING client key: `GET /v1/models` 200 and it lists
   `drill-model`; `POST /v1/chat/completions` (model `drill-model`, the second client key) 200 with
   the mock upstream's answer.
9. Real CPA Manager Plus v1.14.10: `/health` 200; it opened the older database, kept the three
   rows from the WAL, added `account_snapshot` and the other snapshot columns and created its
   other tables (52 tables afterwards): the schema moved forward.
10. Rollback (the app's native rollback script): exit 0, `OASES_CPA_TOPOLOGY=legacy`.
    `config.yaml`, `auths/`, `cpamp/data/` (all five files, the SQLite file and its -wal/-shm
    included) and `secrets/` equal the pre-upgrade bytes. The migrated database is kept in the
    backup (`cpamp-data-after-upgrade/`), the gateway's two pack keys in `secrets-after-upgrade/`,
    the ownership marker in `oases-cpa-managed.after-upgrade`; no `.oases-cpa-managed`, no
    `gateway.pid`. The stub 0.1.x engine answered `/v1/models` on the legacy port again.
11. Everything the drill started was stopped (the app's scripts, then SIGTERM/SIGKILL of the pid
    files, the mock upstream terminated); `ps` showed nothing of the drill afterwards.

The other two real-package drills (`testRealPackagesInstallBootstrapAndAnswerHealthChecks`,
`testRealUpgradeRollbackAndApiKeysScript`) passed in the same run with the changed scripts.

## Not covered

- The real engine v7.2.113 and CPA Manager Plus v1.11.11 binaries (no old packages; stubs stood in
  for them). Not exercised therefore: v7's own rewrite of `config.yaml` (its `credential-*` value
  shapes), the real v1.11 database schema (the fixture's older schema is derived from the v1.14
  migration code, not from a v1.11 file), and whether v1.11.11 can still read a database v1.14.10
  touched (the rollback avoids that by restoring `cpamp/data`).
- Real OAuth auth files under load: the synthetic files were not refreshed (no egress), so an
  engine that refreshes a token would legitimately change them.
- A remote (SSH) target and Linux.
