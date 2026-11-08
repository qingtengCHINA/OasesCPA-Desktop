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

| Endpoint | Request | Status | Response headers or body shape | Conclusion |
|---|---|---|---|---|
| `/v0/management/config` | `GET` | 200 | JSON object of the whole config without `host`, `port` and `remote-management`; has `disable-cooling` (bool), `response-compression` (`{"enabled": bool, "min-bytes": int}`), `max-retry-credentials` (int); `oauth-request-scoped-errors` absent while empty | Read-only view; the whole-list writes (Task 14) keep using it. |
| `/v0/management/max-retry-credentials` | `GET` | 200 | `{"max-retry-credentials": 0}` | Endpoint exists. |
| `/v0/management/max-retry-credentials` | `PUT` and `PATCH` `{"value": 2}` | 200 | `{"status": "ok"}`; GET then answers 2 | The app's `{"value": …}` PATCH applies (Task 19: `.endpoint`, integer). |
| `/v0/management/max-retry-credentials` | `PUT {"value": "x"}` | 400 | `{"error": "invalid body"}` | A wrong type is refused. |
| `/v0/management/max-retry-credentials` | `PUT {"value": -1}` | 200 | GET then answers 0 | Negative values are stored as 0 (0 = try every credential). |
| `/v0/management/oauth-request-scoped-errors` | `GET` | 200 | `{"oauth-request-scoped-errors": null}`, or `{"oauth-request-scoped-errors": {"<channel>": [{"status": 400, "match": […], "action": "stop"}]}}` | NOT a switch: a map of channels to rule lists. |
| `/v0/management/oauth-request-scoped-errors` | `PATCH {"channel": "codex", "rules": [...]}` | 200 | `{"status": "ok"}` | Per-channel replace. |
| `/v0/management/oauth-request-scoped-errors` | `PUT {"value": true}` | 200 | GET then answers `null` | DANGER: a `{"value": …}` PUT is accepted and REMOVES every rule. |
| `/v0/management/oauth-request-scoped-errors` | `PATCH {"value": false}` | 400 | `{"error": "invalid channel"}` | The app's quick-config PATCH shape does not apply. |
| `/v0/management/oauth-request-scoped-errors` | `PUT {"codex": [...]}`; `DELETE ?channel=codex` | 200 / 200 | `{"status": "ok"}` | Whole-map replace; per-channel delete. |
| `/v0/management/disable-cooling` | `GET`, `PUT {"value": true}` | 404 | empty body | No endpoint: written through `config.yaml`. |
| `/v0/management/response-compression`, `…/response-compression/enabled` | `GET` | 404 | empty body | No endpoint: written through `config.yaml`. |
| `/v0/management/config.yaml` | `GET` | 200 | `Content-Type: application/yaml; charset=utf-8`, `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, `Content-Length`; NO `ETag` and no `Last-Modified` (CORS `Access-Control-Expose-Headers` lists `ETag`, but none is sent) | No version token to send back (Task 20: keep "If-Match only when an ETag was received"; with v8.0.51 none is). |
| `/v0/management/config.yaml` | `GET` with `If-None-Match: "x"` | 200 | full body | Conditional reads are not supported. |
| `/v0/management/config.yaml` | `PUT` (unchanged file) with `If-Match: "bogus-etag"` | 200 | `{"changed": ["config"], "ok": true}` | `If-Match` is IGNORED: no compare-and-set; a read-modify-write can overwrite a concurrent change. |
| `/v0/management/config.yaml` | `PUT` without `If-Match` | 200 | `{"changed": ["config"], "ok": true}` | The current `saveConfigYAML` request shape works. |
| `/v0/management/config.yaml` | `PUT` invalid YAML (`host: [`) | 400 | `{"error": "invalid_yaml", "message": "yaml: line 1: …"}` | Invalid files are refused, nothing applied. |
| `/v0/management/config.yaml` | `PUT` with `disable-cooling: true # probe` and `response-compression.enabled: true` changed by lines | 200 | `GET /config` then shows `disable-cooling: true` and `response-compression.enabled: true`; the file read back is byte-for-byte the one written (comment kept) | The engine reloads the file and reads the LEGACY top-level keys; Task 19's line patch works. |
| `/v0/management/max-retry-credentials` | `PATCH {"value": 2}` after a file write | 200 | the file read back differs only in `max-retry-credentials: 2` (other lines and comments kept) | An endpoint write rewrites `config.yaml` too, so file writes must not run beside endpoint writes (the app writes file fields after the endpoint fields). |
| quick configuration (app code) | `ProbeEngineScriptTests.testQuickConfigurationAgainstTheLiveProbeEngine` (`OASES_PROBE_ENGINE_LIVE=1`) | — | the app's client read all four new fields without errors, changed disable-cooling, response-compression and max-retry-credentials, `GET /config` agreed, and the values were restored | Task 19 verified against the real engine. |

Observations on the engine's own file handling:

- At start (and on later writes) the engine appends blocks it knows to `config.yaml`
  (`credential-concurrency`, `credential-in-flight`, `discovery`,
  `redis-usage-queue-retention-seconds`, `disable-cooling`, `request-retry`,
  `max-retry-credentials`, `ws-auth`) and writes `oauth-request-scoped-errors: {}` in flow
  style. The patcher leaves flow values of other keys alone and refuses flow style only for the
  key it changes. The engine-written file is a test fixture
  (`CPAConfigYAMLPatcherTests.testEngineWrittenConfigChangesOneLine`).
- v8.0.51's `config.example.yaml` documents a nested layout (`config-version: 8`, groups such
  as `server:` and `routing:`). The app does not write that layout (R14); a file with
  `config-version` 8 or later makes the two file fields refuse with "use the configuration file
  editor".

## Task 20: conditional writes (re-measured)

Second run, same setup (`start_probe_engine.sh start --archive …`), 2026-11-08:

| Request | Status | Answer | Conclusion |
|---|---|---|---|
| `GET /v0/management/config.yaml` | 200 | `Cache-Control: no-store`, `Content-Type: application/yaml; charset=utf-8`, `Content-Length`; no `ETag`, no `Last-Modified` (`Access-Control-Expose-Headers` names `ETag`, none is sent) | Same as the first run. |
| `PUT config.yaml` (the file just read) without `If-Match` | 200 | `{"changed":["config"],"ok":true}` | Unconditional write. |
| `PUT config.yaml` with `If-Match: "1"` | 200 | `{"changed":["config"],"ok":true}` | `If-Match` ignored. |
| `PUT config.yaml` with `If-Match: *` | 200 | `{"changed":["config"],"ok":true}` | Ignored as well. |

What the app does with this:

- `ManagementAPIClient.configYAML` returns `RuntimeConfigYAMLSnapshot(data, etag)`; `saveConfigYAML(_:etag:…)`
  sends `If-Match` only when the read had an `ETag` and maps 412/428 to `.configConflict`
  ("配置已被其他人修改，请重新加载。"). Against v8.0.51 no `ETag` arrives, so no `If-Match` is
  sent and nothing is protected: a `config.yaml` write is **last-writer-wins**. The file editor
  says so under the editor ("当前引擎不提供文件版本号…最后保存的内容生效。"); the conditional
  path is kept and tested with stubs (`ConfigYAMLConcurrencyTests`) for a future engine.
- CPA Manager Plus `PUT /usage-service/config`: derived from source only (CPA Manager Plus was
  not run here). The oases fork's `managerconfig/handler.go` answers `ETag: "<updatedAtMs>"`,
  takes the expected version from `If-Match: "<ms>"` (else from the body's
  `config.updatedAtMs`, else 0) and refuses a stale one with 409
  `{"error":"manager config conflict","code":"manager_config_conflict"}`; upstream v1.14.10
  ignores both. The app sends the version it read in both places and maps that 409 to
  `.managerConfigConflict`; other 409s (for example `connection_env_managed`) stay server errors.
  UNVERIFIED against a running CPA Manager Plus (Task 23's drill).

## Open items

- **CPA Manager Plus prices usage events by `coalesce(nullif(resolved_model, ''), model)`**
  (`usageevent/aggregate.go`, `usagepricing/repository.go` in v1.14.10).
- **What a pinned request records (measured on the real engine, gateway not in the path):** a
  client key and one openai-compatibility provider with prefix `pin-mock` pointing at a
  loopback mock upstream; `POST /v1/chat/completions` with `model: "pin-mock/probe-model"`
  answered 200, and `/v1/models` listed both `probe-model` and `pin-mock/probe-model`. The
  record in `GET /v0/management/usage-queue` has `model: "probe-model"` (the public name),
  `alias: "pin-mock/probe-model"` (what the client sent), `response_model: "probe-model"`,
  `provider: "openai-compatible-mock"`, `executor_type: "OpenAICompatExecutor"`, and NO
  `resolved_model` field.
- **Derived, not run:** CPA Manager Plus v1.14.10 (`usage/event.go`) stores
  `requested_model ← alias`, `resolved_model ← resolved_model, else model`, and `model ←
  requested_model`. For the record above that gives `model = pin-mock/probe-model` and
  `resolved_model = probe-model`, so the price of a pinned request is looked up under the
  public name, and the event list shows the `pin-…/` name (the app's model detail queries both
  spellings and shows public names). UNVERIFIED end to end: CPA Manager Plus and the gateway
  were not run against the probe engine; Task 23's drill should record the `resolved_model` of
  a real pinned request through the gateway.
- **Privacy:** the engine's usage-queue records carry the client API key in plaintext
  (`api_key`) and the upstream credential in `source`; CPA Manager Plus masks `source` when it
  imports. `GET /v0/management/config` leaves out `remote-management`.
- **Not measured yet:** the request-error log endpoints (`/v0/management/request-error-logs`,
  Task 21); until they are measured, Task 21 lists and downloads only through the routes in
  `server_management.go` and tolerates unknown fields.
