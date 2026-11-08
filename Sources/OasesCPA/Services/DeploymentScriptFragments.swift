import Foundation

/// The loopback ports a generated native script uses. Deployments always use `.standard`
/// (`DeploymentPorts`); script tests and scratch end-to-end runs may pick free ports.
struct DeploymentScriptPorts: Equatable, Sendable {
    let gatewayAPI: Int
    let gatewayAdmin: Int
    let engine: Int
    let cpamp: Int

    static let standard = DeploymentScriptPorts(
        gatewayAPI: DeploymentPorts.gatewayAPI,
        gatewayAdmin: DeploymentPorts.gatewayAdmin,
        engine: DeploymentPorts.engine,
        cpamp: DeploymentPorts.cpamp
    )
}

/// One long-running process of a deployment: its pid file, its log and the directory whose
/// absolute path appears in its `ps` command line (how a pid is proven to belong to the
/// deployment), all relative to the install root.
struct DeploymentManagedProcess: Equatable, Sendable {
    let name: String
    let pidFile: String
    let logFile: String
    let runScript: String
    let ownedPath: String
    /// How long a stop waits after SIGTERM before SIGKILL. The gateway lets in-flight requests
    /// finish for up to 25 s (`SHUTDOWN_GRACE_MS`) and then writes its usage ledger, so it gets
    /// 30 s; SIGKILL would lose the last usage records (Server `docs/upgrade.md`).
    let termGraceSeconds: Int
    /// Started only when its run script exists (a legacy 0.1.x deployment has no gateway).
    let startsOnlyWhenInstalled: Bool
}

/// Bash fragments shared by the install, upgrade, rollback and Docker scripts. Every fragment
/// defines variables or functions only; nothing runs until a script calls it. All of them work
/// with bash 3.2 (macOS `/bin/bash`) and bash 5, and none puts a key into a process argument.
enum DeploymentScriptFragments {
    // MARK: - Managed processes (M9: the one list every script uses)

    /// The processes of a topology in start order (engine, CPA Manager Plus, gateway). Stopping
    /// goes the other way, gateway first, so the gateway never answers while the engine is gone.
    static func managedProcesses(topology: DeploymentTopology) -> [DeploymentManagedProcess] {
        var processes = [
            DeploymentManagedProcess(
                name: "cli-proxy-api",
                pidFile: "cli-proxy-api.pid",
                logFile: "logs/cli-proxy-api.log",
                runScript: "cli-proxy-api/run.sh",
                ownedPath: "cli-proxy-api",
                termGraceSeconds: 5,
                startsOnlyWhenInstalled: false
            ),
            DeploymentManagedProcess(
                name: "cpa-manager-plus",
                pidFile: "cpa-manager-plus.pid",
                logFile: "logs/cpa-manager-plus.log",
                runScript: "cpamp/run.sh",
                ownedPath: "cpamp",
                termGraceSeconds: 5,
                startsOnlyWhenInstalled: false
            ),
        ]
        if topology == .gateway {
            processes.append(DeploymentManagedProcess(
                name: "gateway",
                pidFile: "gateway.pid",
                logFile: "logs/gateway.log",
                runScript: "gateway/run.sh",
                ownedPath: "gateway",
                termGraceSeconds: 30,
                startsOnlyWhenInstalled: true
            ))
        }
        return processes
    }

    /// Bash: `OASES_MANAGED_PID_FILES` (start order), `OASES_MANAGED_STOP_ORDER` (gateway
    /// first), `OASES_MANAGED_LOG_FILES`, `oases_managed_owned_path <pid file>`, which prints
    /// the directory (relative to the root) a process of that pid file runs from, and
    /// `oases_managed_term_ticks <pid file>`, the SIGTERM grace in 0.2 s steps.
    static func managedProcessList(topology: DeploymentTopology) -> String {
        let processes = managedProcesses(topology: topology)
        let cases = processes.map { "    \($0.pidFile)) printf '%s' '\($0.ownedPath)' ;;" }.joined(separator: "\n")
        let ticks = processes.map { "    \($0.pidFile)) printf '%s' '\($0.termGraceSeconds * 5)' ;;" }.joined(separator: "\n")
        return """
        OASES_MANAGED_PID_FILES="\(processes.map(\.pidFile).joined(separator: " "))"
        OASES_MANAGED_STOP_ORDER="\(processes.reversed().map(\.pidFile).joined(separator: " "))"
        OASES_MANAGED_LOG_FILES="\(processes.map(\.logFile).joined(separator: " "))"
        oases_managed_owned_path() {
          case "$1" in
        \(cases)
            *) return 1 ;;
          esac
        }
        oases_managed_term_ticks() {
          case "$1" in
        \(ticks)
            *) printf '%s' '25' ;;
          esac
        }
        """
    }

    /// Bash: `oases_pid_owned_by <pid> <path>` succeeds when the pid is a number, the process
    /// lives, and its `ps` command line contains the absolute path (how a pid file is proven to
    /// belong to this deployment; a stale pid of another program is never signalled), and
    /// `oases_stop_owned_pid <pid> <path> <pid file>` sends it SIGTERM, waits its grace
    /// (`oases_managed_term_ticks`, so `managedProcessList` must come first) and only then
    /// SIGKILL. Not owned: nothing is sent. `oases_managed_process_alive_under <root>` succeeds
    /// while any process runs from a managed directory of that root (with or without a pid
    /// file), the last check before a root is removed.
    static func managedProcessStop() -> String {
        """
        oases_pid_owned_by() {
          local owned_pid="$1" owned_path="$2" owned_command
          case "$owned_pid" in ''|*[!0-9]*) return 1 ;; esac
          [ "$owned_pid" -gt 1 ] || return 1
          kill -0 "$owned_pid" >/dev/null 2>&1 || return 1
          owned_command="$(ps -p "$owned_pid" -o command= 2>/dev/null || true)"
          case "$owned_command" in
            *"$owned_path"*) return 0 ;;
            *) return 1 ;;
          esac
        }
        oases_stop_owned_pid() {
          local stop_pid="$1" stop_path="$2" stop_ticks
          oases_pid_owned_by "$stop_pid" "$stop_path" || return 0
          kill -TERM "$stop_pid" >/dev/null 2>&1 || true
          stop_ticks="$(oases_managed_term_ticks "$3")"
          while [ "$stop_ticks" -gt 0 ]; do
            oases_pid_owned_by "$stop_pid" "$stop_path" || return 0
            sleep 0.2
            stop_ticks=$((stop_ticks - 1))
          done
          if oases_pid_owned_by "$stop_pid" "$stop_path"; then
            kill -KILL "$stop_pid" >/dev/null 2>&1 || true
            stop_ticks=10
            while [ "$stop_ticks" -gt 0 ] && oases_pid_owned_by "$stop_pid" "$stop_path"; do
              sleep 0.2
              stop_ticks=$((stop_ticks - 1))
            done
          fi
          return 0
        }
        oases_managed_process_alive_under() {
          local alive_root="$1" alive_list alive_line alive_owned
          alive_list="$(ps -axo command= 2>/dev/null || true)"
          while IFS= read -r alive_line; do
            for alive_owned in \(managedProcesses(topology: .gateway).map(\.ownedPath).joined(separator: " ")); do
              case "$alive_line" in
                *"$alive_root/$alive_owned/"*) return 0 ;;
              esac
            done
          done <<< "$alive_list"
          return 1
        }
        """
    }


    // MARK: - Keys

    /// `oases_mgmt_curl <key file> <curl arguments…>`: a curl with the management key as a
    /// Bearer header. The key is read with the `read` builtin and handed to curl as a config
    /// file on standard input (`printf` is a builtin), so it is in no argument list and in no
    /// temporary file. Request bodies go in with `--data-binary @<0600 file>`.
    static func managementCurl() -> String {
        """
        oases_mgmt_curl() {
          local key_file="$1"
          local key=""
          shift
          [ -f "$key_file" ] || return 1
          IFS= read -r key < "$key_file" || [ -n "$key" ] || return 1
          [ -n "$key" ] || return 1
          { trap '' PIPE; printf 'header = "Authorization: Bearer %s"\\n' "$key" || :; } | curl -K - "$@"
        }
        """
    }

    // MARK: - Versions

    /// `oases_version_gt A B`: succeeds when version A is greater than B. A leading "v" and
    /// anything from the first "+" or "-" on are ignored; the dot-separated parts compare as
    /// numbers (a missing part is 0). Pure bash 3.2, no `sort -V`.
    static func versionCompareFunctions() -> String {
        """
        oases_version_core() {
          local value="${1#v}"
          value="${value%%+*}"
          value="${value%%-*}"
          printf '%s' "$value"
        }
        oases_version_gt() {
          local left right l r
          left="$(oases_version_core "$1")"
          right="$(oases_version_core "$2")"
          while [ -n "$left" ] || [ -n "$right" ]; do
            l="${left%%.*}"
            r="${right%%.*}"
            case "$left" in *.*) left="${left#*.}" ;; *) left="" ;; esac
            case "$right" in *.*) right="${right#*.}" ;; *) right="" ;; esac
            case "$l" in ''|*[!0-9]*) l=0 ;; esac
            case "$r" in ''|*[!0-9]*) r=0 ;; esac
            l=$((10#$l))
            r=$((10#$r))
            if [ "$l" -gt "$r" ]; then return 0; fi
            if [ "$l" -lt "$r" ]; then return 1; fi
          done
          return 1
        }
        """
    }

    /// `oases_read_installed_versions <root>`: sets `INSTALLED_ENGINE`, `INSTALLED_CPAMP`,
    /// `INSTALLED_NODE`, `INSTALLED_GATEWAY` from `<root>/.oases-cpa-versions` (the format
    /// `oases_write_versions` writes). Without that file (deployments of app 0.1.x) the engine
    /// and CPA Manager Plus versions come from the package names in their `run.sh`; Node and
    /// the gateway stay empty.
    static func readInstalledVersions() -> String {
        """
        oases_versions_value() {
          sed -n "s/^[[:space:]]*\\"$2\\"[[:space:]]*:[[:space:]]*\\"\\\\([^\\"]*\\\\)\\".*$/\\\\1/p" "$1" | head -n 1
        }
        oases_read_installed_versions() {
          local root="$1"
          INSTALLED_ENGINE=""
          INSTALLED_CPAMP=""
          INSTALLED_NODE=""
          INSTALLED_GATEWAY=""
          if [ -f "$root/.oases-cpa-versions" ]; then
            INSTALLED_ENGINE="$(oases_versions_value "$root/.oases-cpa-versions" engine)"
            INSTALLED_CPAMP="$(oases_versions_value "$root/.oases-cpa-versions" cpamp)"
            INSTALLED_NODE="$(oases_versions_value "$root/.oases-cpa-versions" node)"
            INSTALLED_GATEWAY="$(oases_versions_value "$root/.oases-cpa-versions" gateway)"
            return 0
          fi
          if [ -f "$root/cli-proxy-api/run.sh" ]; then
            INSTALLED_ENGINE="$(sed -n 's/.*runtime\\/CLIProxyAPI_\\([0-9][0-9A-Za-z.+-]*\\)_[a-z0-9]*_[a-z0-9]*\\/.*/v\\1/p' "$root/cli-proxy-api/run.sh" | head -n 1)"
          fi
          if [ -f "$root/cpamp/run.sh" ]; then
            INSTALLED_CPAMP="$(sed -n 's/.*runtime\\/cpa-manager-plus_\\(v[0-9][0-9A-Za-z.+-]*\\)_[a-z0-9]*_[a-z0-9]*.*/\\1/p' "$root/cpamp/run.sh" | head -n 1)"
          fi
          return 0
        }
        """
    }

    /// `oases_write_versions <root> <engine> <cpamp> [<node> <gateway>]`: writes
    /// `<root>/.oases-cpa-versions` atomically (temporary file, then `mv`): a JSON object with
    /// one key per line, in the order engine, cpamp, node, gateway. Docker deployments pass only
    /// the first two.
    static func writeVersionsFile() -> String {
        """
        oases_write_versions() {
          local root="$1"
          local part="$1/.oases-cpa-versions.part.$$"
          if [ "$#" -ge 5 ]; then
            printf '{\\n  "engine": "%s",\\n  "cpamp": "%s",\\n  "node": "%s",\\n  "gateway": "%s"\\n}\\n' "$2" "$3" "$4" "$5" > "$part" || return 1
          else
            printf '{\\n  "engine": "%s",\\n  "cpamp": "%s"\\n}\\n' "$2" "$3" > "$part" || return 1
          fi
          chmod 644 "$part" || return 1
          mv "$part" "$root/.oases-cpa-versions"
        }
        """
    }

    // MARK: - run.sh

    /// `oases_write_engine_run <engine dir> <binary>`: `<engine dir>/run.sh`.
    static func engineRunScript() -> String {
        """
        oases_write_engine_run() {
          local dir="$1" binary="$2" part="$1/run.sh.part.$$"
          {
            printf '#!/bin/bash\\nset -euo pipefail\\nexec 3>&- 4>&-\\n'
            printf 'cd %q\\n' "$dir"
            printf 'exec %q -config %q\\n' "$binary" "$dir/config.yaml"
          } > "$part" || return 1
          chmod 755 "$part" || return 1
          mv "$part" "$dir/run.sh"
        }
        """
    }

    /// `oases_write_cpamp_run <cpamp dir> <binary>`: `<cpamp dir>/run.sh`, which points
    /// CPA Manager Plus at the fixed `<cpamp dir>/config.json` (`CPA_MANAGER_CONFIG`), so the
    /// configuration stays where it is when the versioned runtime directory changes.
    static func cpampRunScript() -> String {
        """
        oases_write_cpamp_run() {
          local dir="$1" binary="$2" part="$1/run.sh.part.$$"
          {
            printf '#!/bin/bash\\nset -euo pipefail\\nexec 3>&- 4>&-\\n'
            printf 'export CPA_MANAGER_CONFIG=%q\\n' "$dir/config.json"
            printf 'cd %q\\n' "$dir"
            printf 'exec %q\\n' "$binary"
          } > "$part" || return 1
          chmod 755 "$part" || return 1
          mv "$part" "$dir/run.sh"
        }
        """
    }

    /// `oases_write_gateway_run <root> <engine version> <panel version> <api port> <admin port>
    /// <engine port>`: `<root>/gateway/run.sh` with the environment of interfaces §3 (all eleven
    /// variables, absolute paths, no `HOST_STATUS_UNITS`). It runs Node and `server.mjs` by
    /// absolute path, so `ps` shows both under the root.
    static func gatewayRunScript() -> String {
        """
        oases_write_gateway_run() {
          local root="$1" part="$1/gateway/run.sh.part.$$"
          {
            printf '#!/bin/bash\\nset -euo pipefail\\nexec 3>&- 4>&-\\n'
            printf 'export PORT=%s\\n' "$4"
            printf 'export BIND_HOST=127.0.0.1\\n'
            printf 'export ADMIN_LISTEN_PORT=%s\\n' "$5"
            printf 'export GO_BACKEND_URL=http://127.0.0.1:%s\\n' "$6"
            printf 'export CONFIG_PATH=%q\\n' "$root/cli-proxy-api/config.yaml"
            printf 'export KEY_FILE_PATH=%q\\n' "$root/secrets/cpa-management-key"
            printf 'export PACK_ENGINE_KEY_PATH=%q\\n' "$root/secrets/pack-engine-key"
            printf 'export PACK_STORE_KEY_FILE=%q\\n' "$root/secrets/pack-store-key"
            printf 'export OASES_DATA_DIR=%q\\n' "$root/gateway-data"
            printf 'export HOST_STATUS_ENGINE_VERSION=%q\\n' "$2"
            printf 'export HOST_STATUS_PANEL_VERSION=%q\\n' "$3"
            printf 'cd %q\\n' "$root/gateway-data"
            printf 'exec %q %q\\n' "$root/node/current/bin/node" "$root/gateway/current/server.mjs"
          } > "$part" || return 1
          chmod 755 "$part" || return 1
          mv "$part" "$root/gateway/run.sh"
        }
        """
    }

    // MARK: - Node, gateway, bootstrap

    /// `oases_archive_paths_are_relative <archive>`: fails when the listing of a tar.gz holds an
    /// absolute path or a `..` component (the rule of `script/vendor_gateway.sh`), checked
    /// before anything is unpacked. Defined by both the Node and the gateway fragment.
    private static let archivePathCheck = """
    oases_archive_paths_are_relative() {
      local listing
      listing="$(tar -tzf "$1")" || return 1
      # A here-string, not a pipe: with pipefail an early exit of grep -q could turn a
      # match into a failure of the pipeline and so into "no match".
      if grep -Eq '(^|/)\\.\\.(/|$)|^/' <<< "$listing"; then
        return 1
      fi
      return 0
    }
    """

    /// `oases_install_node <root>` (segment J). Needs `NODE_VERSION_TAG`, `NODE_ASSET`,
    /// `NODE_PACKAGE`, `NODE_EXPECTED_SHA256` (`DeploymentPinSet.nativeSelectionScript()`),
    /// `curl_retry` and `verify_fixed_archive`. Downloads the pinned package, checks its SHA-256,
    /// requires the single top directory `<NODE_PACKAGE>/`, unpacks it without that directory to
    /// `node/<tag>`, points `node/current` at it and requires `node --version` to print the tag.
    /// Never uses a Node that is already on the target. Sets `NODE_BIN`. Exit 18 for a failed
    /// download, 23 for every check.
    static func installNode() -> String {
        """
        \(archivePathCheck)
        oases_install_node() {
          local root="$1"
          local node_dir="$root/node"
          local archive="$node_dir/downloads/$NODE_ASSET"
          local part="$archive.part"
          local stage="$node_dir/.$NODE_VERSION_TAG.partial.$$"
          local tops actual
          mkdir -p "$node_dir/downloads"
          rm -f "$part"
          if ! curl_retry --fail --silent --show-error --location --max-redirs 3 --proto '=https' --proto-redir '=https' --max-filesize \(DeploymentPinSet.nativeArchiveMaxBytes) "https://nodejs.org/dist/$NODE_VERSION_TAG/$NODE_ASSET" -o "$part"; then
            rm -f "$part"
            exit 18
          fi
          if ! verify_fixed_archive "$NODE_EXPECTED_SHA256" "$NODE_ASSET" "$part"; then
            rm -f "$part"
            exit 23
          fi
          if ! tops="$(tar -tzf "$part" | sed -e 's|^\\./||' -e 's|/.*$||' | sort -u)"; then
            printf '%s\\n' 'Node 运行时下载包不完整或不是有效的 tar.gz。' >&2
            rm -f "$part"
            exit 23
          fi
          if ! oases_archive_paths_are_relative "$part"; then
            printf '%s\\n' 'Node 运行时包含有绝对路径或 .. 路径，已拒绝。' >&2
            rm -f "$part"
            exit 23
          fi
          if [ "$tops" != "$NODE_PACKAGE" ]; then
            printf '%s\\n' 'Node 运行时包的目录结构不符合预期。' >&2
            rm -f "$part"
            exit 23
          fi
          mv "$part" "$archive"
          rm -rf "$stage"
          mkdir -p "$stage"
          if ! tar -xzf "$archive" --strip-components=1 -C "$stage"; then
            printf '%s\\n' 'Node 运行时解压失败。' >&2
            exit 23
          fi
          [ -f "$stage/bin/node" ] || { printf '%s\\n' 'Node 运行时包中没有 bin/node。' >&2; exit 23; }
          rm -rf "$node_dir/$NODE_VERSION_TAG"
          mv "$stage" "$node_dir/$NODE_VERSION_TAG"
          ln -sfn "$NODE_VERSION_TAG" "$node_dir/current"
          NODE_BIN="$node_dir/current/bin/node"
          if ! actual="$("$NODE_BIN" --version 3>&- 4>&- 2>/dev/null)" || [ "$actual" != "$NODE_VERSION_TAG" ]; then
            printf 'Node 运行时冒烟检查失败：期望 %s。\\n' "$NODE_VERSION_TAG" >&2
            exit 23
          fi
        }
        """
    }

    /// `oases_install_gateway <root>` (segment K, first half). Needs `GATEWAY_VERSION`,
    /// `GATEWAY_FILE`, `GATEWAY_EXPECTED_SHA256`, `GATEWAY_PAYLOAD_BASE64` (the package the app
    /// carries, embedded in the script) and `verify_fixed_archive`. Decodes it with
    /// `openssl base64 -d -A` (`base64 -d` is a debug switch on macOS 12 and older), checks the
    /// SHA-256 and the single top directory `oases-gateway_<ver>/`, unpacks it without that
    /// directory to `gateway/<ver>` and points `gateway/current` at it. Every failure exits 24
    /// and leaves no `gateway/` directory behind on a fresh install.
    static func installGateway() -> String {
        """
        \(archivePathCheck)
        oases_gateway_package_failed() {
          rm -f "$1/gateway/downloads/$GATEWAY_FILE.part"
          rm -rf "$1/gateway/.$GATEWAY_VERSION.partial.$$"
          rmdir "$1/gateway/downloads" "$1/gateway" >/dev/null 2>&1 || true
          printf '%s\\n' "$2" >&2
          exit 24
        }
        oases_install_gateway() {
          local root="$1"
          local gateway_dir="$root/gateway"
          local part="$gateway_dir/downloads/$GATEWAY_FILE.part"
          local stage="$gateway_dir/.$GATEWAY_VERSION.partial.$$"
          local tops
          mkdir -p "$gateway_dir/downloads"
          rm -f "$part"
          if ! printf '%s' "$GATEWAY_PAYLOAD_BASE64" | openssl base64 -d -A > "$part"; then
            oases_gateway_package_failed "$root" 'Oases 网关包无法解码。'
          fi
          if ! verify_fixed_archive "$GATEWAY_EXPECTED_SHA256" "$GATEWAY_FILE" "$part"; then
            oases_gateway_package_failed "$root" 'Oases 网关包校验失败。'
          fi
          if ! tops="$(tar -tzf "$part" | sed -e 's|^\\./||' -e 's|/.*$||' | sort -u)"; then
            oases_gateway_package_failed "$root" 'Oases 网关包不是有效的 tar.gz。'
          fi
          if ! oases_archive_paths_are_relative "$part"; then
            oases_gateway_package_failed "$root" 'Oases 网关包含有绝对路径或 .. 路径，已拒绝。'
          fi
          if [ "$tops" != "oases-gateway_$GATEWAY_VERSION" ]; then
            oases_gateway_package_failed "$root" 'Oases 网关包必须只有一个顶层目录 oases-gateway_<版本>/。'
          fi
          rm -rf "$stage"
          mkdir -p "$stage"
          if ! tar -xzf "$part" --strip-components=1 -C "$stage"; then
            oases_gateway_package_failed "$root" 'Oases 网关包解压失败。'
          fi
          if [ ! -f "$stage/server.mjs" ] || [ ! -f "$stage/bootstrap.mjs" ]; then
            oases_gateway_package_failed "$root" 'Oases 网关包缺少 server.mjs 或 bootstrap.mjs。'
          fi
          mv "$part" "$gateway_dir/downloads/$GATEWAY_FILE"
          rm -rf "$gateway_dir/$GATEWAY_VERSION"
          mv "$stage" "$gateway_dir/$GATEWAY_VERSION"
          ln -sfn "$GATEWAY_VERSION" "$gateway_dir/current"
        }
        """
    }

    /// `oases_secure_private_directories <root>` (before keys are written and before
    /// bootstrap). The gateway's bootstrap refuses a secrets or data directory that is a
    /// symlink or that group or others can write to (exit 3, `insecure_directory`), and refuses
    /// to create a directory inside a parent that is not private. So: the root and `secrets`
    /// must not be symlinks (exit 25), the root loses group/other write permission, `secrets`
    /// becomes 0700 and `gateway-data` is created with mode 0700 (an existing one is set to
    /// 0700; a symlinked one exits 25).
    static func securePrivateDirectories() -> String {
        """
        oases_private_directory_failed() {
          printf '%s%s，已停止部署。\\n' "$1" "$2" >&2
          exit 25
        }
        oases_secure_private_directories() {
          local root="$1"
          if [ -L "$root" ]; then
            printf '%s\\n' '安装目录是符号链接，网关初始化拒绝使用；请选择真实目录。' >&2
            exit 25
          fi
          chmod go-w "$root" || oases_private_directory_failed '无法去掉安装目录的组与其他用户写权限（chmod go-w）：' "$root"
          if [ -L "$root/secrets" ]; then
            printf '%s\\n' 'secrets 目录是符号链接，已停止部署。' >&2
            exit 25
          fi
          mkdir -p "$root/secrets" || oases_private_directory_failed '无法创建 secrets 目录：' "$root/secrets"
          chmod 700 "$root/secrets" || oases_private_directory_failed '无法把 secrets 目录设为 0700：' "$root/secrets"
          if [ -L "$root/gateway-data" ]; then
            printf '%s\\n' 'gateway-data 目录是符号链接，已停止部署。' >&2
            exit 25
          fi
          if [ -d "$root/gateway-data" ]; then
            chmod 700 "$root/gateway-data" || oases_private_directory_failed '无法把 gateway-data 目录设为 0700：' "$root/gateway-data"
          else
            mkdir -m 700 "$root/gateway-data" || oases_private_directory_failed '无法创建 gateway-data 目录：' "$root/gateway-data"
          fi
        }
        """
    }

    /// `oases_run_bootstrap <root>` (segment K, second half). Needs `NODE_BIN`. Runs the
    /// gateway's `bootstrap.mjs` on `gateway-data` and `secrets`; its one-line JSON summary
    /// (no key material) goes to the deployment log. A non-zero status exits 25 with the
    /// bootstrap's own exit code (2 management key missing, 3 path or permission) in the message.
    static func runBootstrap() -> String {
        """
        oases_run_bootstrap() {
          local root="$1" status=0
          "$NODE_BIN" "$root/gateway/current/bootstrap.mjs" --data-dir "$root/gateway-data" --secrets-dir "$root/secrets" 3>&- 4>&- || status=$?
          if [ "$status" -ne 0 ]; then
            printf 'Oases 网关初始化失败（bootstrap 退出码 %s）。\\n' "$status" >&2
            exit 25
          fi
          [ -s "$root/secrets/pack-engine-key" ] || { printf '%s\\n' 'Oases 网关初始化没有生成内部引擎 Key。' >&2; exit 25; }
        }
        """
    }
}
