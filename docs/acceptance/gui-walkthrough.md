# GUI walkthrough checklist (Task 23b)

For the controller (computer use) or the owner. Everything scriptable already ran
(`2026-11-08-macos-e2e.md`); this list is what needs eyes and clicks. Fill in the **Result**
column (pass / fail + a short note) and keep screenshots in the git-ignored `dist/e2e/`. Never
write a key, host name or user name into this file; write paths as `<scratch>` and `<install>`.

## 0. Preconditions (safety, rulings C3/H6)

| # | Action | Expected | Result |
|---|---|---|---|
| 0.1 | `lsof -nP -iTCP -sTCP:LISTEN` | nothing on 8317, 18316, 18317, 18320, 19101, 19102. If anything listens there (for example the owner's deployment under `~/.oases-cpa`): STOP the walkthrough; do not stop that service. | |
| 0.2 | Build a Debug app with a separate bundle identifier: `xcodebuild -project OasesCPA.xcodeproj -scheme "Oases CPA" -configuration Debug -derivedDataPath <scratch>/gui-dd CODE_SIGNING_ALLOWED=NO OASES_BUNDLE_ID_PREFIX=dev.example.oases-e2e OASES_UPDATE_REPOSITORY= build` | build succeeds; the app's `CFBundleIdentifier` starts with `dev.example.oases-e2e` (`defaults read "<scratch>/gui-dd/Build/Products/Debug/Oases CPA.app/Contents/Info" CFBundleIdentifier`). | |
| 0.3 | `SCRATCH_HOME="$(mktemp -d "${TMPDIR:-/tmp}/oases-gui.XXXXXX")"`; build the next gateway: `bash script/e2e/make_gateway_next.sh <scratch>/release-out/oases-gateway_0.1.0.tar.gz > <scratch>/next.env` | `next.env` holds `OASES_E2E_GATEWAY_TARBALL`, `_SHA256`, `_VERSION=0.1.1`. | |
| 0.4 | Start the mock upstreams with any Node 24: `node script/e2e/mock-upstream.mjs --port 19101 --name a > <scratch>/a.log &` and `… --port 19102 --name b > <scratch>/b.log &` | each prints `mock-upstream <name> listening on http://127.0.0.1:<port>/v1` on stderr. | |
| 0.5 | Launch the app from a shell with the isolation from README "本机运行的隔离": `HOME="$SCRATCH_HOME" CFFIXED_USER_HOME="$SCRATCH_HOME" "<scratch>/gui-dd/Build/Products/Debug/Oases CPA.app/Contents/MacOS/Oases CPA" -OasesDisableAutoProbe` | the app opens. | |
| 0.6 | FIRST check after launch: open 连接与部署 | the connection centre shows NO saved target. If it shows one, quit the app at once and report (it would be the owner's profile). | |

Note: the Keychain service name is shared between builds; profiles are separate per target, but
the most complete isolation is a temporary macOS user account. The deployment in step 1
downloads the pinned packages from GitHub and nodejs.org (SHA-256 checked by the scripts).

## 1. Walkthrough (design §5.4 order)

| # | Action | Expected | Evidence | Result |
|---|---|---|---|---|
| 1 | 连接与部署 → 本机 Mac → native → install directory `~/.oases-cpa-e2e` (with the scratch HOME that is `<scratch-home>/.oases-cpa-e2e`, never the owner's) → deploy | the progress flow ends successfully; four ports only on `127.0.0.1` (`lsof -nP -iTCP:8317,18320,18316,18317 -sTCP:LISTEN`); `<install>/.oases-cpa-versions` = engine v8.0.51, cpamp v1.14.10, node v24.22.2, gateway 0.1.0 | lsof output, versions file, screenshot of the finished deployment | |
| 2 | AI 提供商 → add a compatible provider A (Base URL `http://127.0.0.1:19101/v1`, any upstream key, models `glm-5`, `mock-chat`), then B (`…:19102/v1`) | each gets an automatic `pin-…` prefix, the two differ; the prefix field shows it, other pages do not; `<install>/cli-proxy-api/config.yaml` lists both under top-level `openai-compatibility` | config.yaml prefix lines | |
| 3 | 调用 API Key → new key with policy: allowlist `glm-5`, RPM 10 | the one-time key sheet shows the key once; the list shows the key masked with the policy summary | screenshot (key masked) | |
| 4 | `curl` the gateway with that key (key via `-K -`, never on the command line): `POST http://127.0.0.1:8317/v1/chat/completions` model `glm-5`; `GET /v1/models` | 200 with `served-by:a` or `served-by:b`; `/v1/models` has no `pin-` id | status codes, model ids | |
| 5 | CPAMP price page: give `glm-5` a made-up price; open 用量分析 and the model detail of `glm-5` | the call count and a cost appear under `glm-5` (pinned calls of step 9 are priced under the public name too, see the e2e record) | screenshots | |
| 6 | 模型 → 全部测活 | the health dots update (A and B up) | screenshot | |
| 7 | Model detail of `glm-5` → drag B before A | a dry-run preview appears first; after confirming, the `priority` values in `config.yaml` change (B above A) | preview screenshot, config.yaml lines | |
| 8 | 模型包 → new pack (member `glm-5`, with prices) → pack key with a total cost limit and monthly reset | the `sk-pk-` key is shown once; one call with it (model = the pack's model id) succeeds | status code | |
| 9 | Policy key from step 3: pin `glm-5` only = A; restart mock A with `--fail`; call | the call returns A's 5xx (no failover); `<scratch>/b.log` shows no new request. Then disable A in AI 提供商 and call again: 403 `pinned_provider_unavailable` | status codes, b.log line count before/after | |
| 10 | Quit the app; relaunch it as in 0.5 but with the variables from `next.env` exported; 连接与部署 → 升级 | the upgrade succeeds; versions file gateway `0.1.1`; `<install>/gateway-data/e2e-format.json` exists; then create one more pack key | versions file, `ls gateway-data` | |
| 11 | Quit; relaunch WITHOUT the `OASES_E2E_GATEWAY_*` variables (bundled gateway 0.1.0); 升级 | the app refuses the downgrade with a readable message (script exit 22); all services keep running | screenshot of the message, `/healthz` still 0.1.1 | |
| 12 | 回滚 | gateway back to `0.1.0`; `e2e-format.json` and the pack key from step 10 are gone (kept in `backups/upgrade-*/gateway-data-after-upgrade/`); all services healthy | versions file, pack key list, `ls backups/upgrade-*/` | |
| 13 | Visit every page (usage analytics, request monitoring, dashboard rankings, prices, model detail, …) | no `pin-` anywhere except the provider editor's prefix field and the YAML editor; `grep -rlF -f <keys file> <install>/logs` lists nothing; `log show --predicate 'subsystem CONTAINS "Oases"' --last 1h \| grep -cF -f <keys file>` prints 0 (the keys file holds the four values of `<install>/secrets/*`, mode 0600, removed afterwards; never print it) | page screenshots, the two counts | |

## 2. Items earlier batches could only check without a GUI

| # | Where | Expected | Result |
|---|---|---|---|
| 2.1 | CPA Manager Plus settings (连接与部署 / 配置面板 → CPAMP 设置): save without a change right after the fresh deployment | KNOWN DEFECT from the scripted drill: refused with "at least one inspection target type is required" (HTTP 500). Record what the page shows. | |
| 2.2 | Config editor (YAML) | the note under the editor says the engine has no file version and the last save wins | |
| 2.3 | One-time key sheets (API key, pack key) | shown once; closing the page forgets the key; the hand-off from the editor sheet to the key sheet works | |
| 2.4 | Model detail drag and drop and the dry-run sheet; a changed plan between dry run and apply is surfaced | as described | |
| 2.5 | Pack and pack-key editor sheets; failover attempts follow the member count for a new pack | as described | |
| 2.6 | Quick configuration rows (disable cooling, response compression, max retry credentials, OAuth scoped errors read-only with a rule count) | as described | |
| 2.7 | Request-error files list and redacted download; monitoring filters and raw fields; price sync candidates adopted one by one | as described; no embedded web panel anywhere | |
| 2.8 | Light and dark mode, zh-Hans and en, on every page above; VoiceOver labels on the pin editor and the `ellipsis.circle` menus | readable, no clipped or untranslated strings | |

## 3. Closing

| # | Action | Expected | Result |
|---|---|---|---|
| 3.1 | In the app: 停止 the drill deployment | the three pids in `<install>/*.pid` have exited (`ps -p <pid>`); the four ports are free | |
| 3.2 | `mv <scratch-home>/.oases-cpa-e2e ~/.Trash/oases-cpa-e2e-$(date -u +%Y%m%dT%H%M%SZ)` | moved. Do NOT use 删除部署 here (its script ends with `rm -rf -- "$ROOT"`); the removal script was already exercised on a scratch root by the scripted drill. | |
| 3.3 | Stop both mock upstreams (SIGTERM); `lsof` again | 8317, 18316, 18317, 18320, 19101, 19102 free | |
| 3.4 | `bash script/check-no-private.sh --tree --require-private-terms` before committing this file | exit 0 | |
