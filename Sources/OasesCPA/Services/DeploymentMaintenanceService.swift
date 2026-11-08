import Foundation

struct DeploymentMaintenanceResult: Sendable {
    let backupName: String
    let detail: String
    /// The layout after the operation (stdout line `OASES_CPA_TOPOLOGY=legacy|gateway`).
    var topology: DeploymentTopology = .legacy
    /// SHA-256 of the gateway's internal engine key after the operation (never the key).
    var packEngineKeyFingerprint: String? = nil
}

/// Upgrade and rollback of an installed deployment.
///
/// Native upgrade order: the installed marker → platform and pins → the versions on the target
/// → the no-downgrade guard (exit 22 before anything is stopped or written) → a backup →
/// stop → download and verify → install → start and wait → versions file → `gateway/run.sh`.
/// Any failure after the backup restores it (`oases_restore_backup`). The rollback restores
/// the newest backup the same way. Authentication files and CPA Manager Plus `data/` are never
/// rolled back; `gateway-data/` is (a newer gateway may have rewritten it one way).
struct DeploymentMaintenanceService {
    /// One `/healthz` (and engine/panel) attempt per second.
    static let healthAttempts = 45

    func upgrade(request: DeploymentExecutionRequest) async throws -> DeploymentMaintenanceResult {
        let pins = try DeploymentPinSet.current
            .with(gateway: GatewayBundle.resolve(environment: ProcessInfo.processInfo.environment))
            .deployable()
        let payload = request.method == .native
            ? try pins.gateway.verifiedPayload(in: GatewayBundle.resourceBundle).base64EncodedString()
            : ""
        let output = try await execute(
            request: request,
            script: upgradeScript(
                method: request.method,
                installDirectory: request.installDirectory,
                pins: pins,
                gatewayPayloadBase64: payload,
                ports: .standard,
                healthAttempts: Self.healthAttempts
            )
        )
        return parseResult(output)
    }

    func rollback(request: DeploymentExecutionRequest) async throws -> DeploymentMaintenanceResult {
        let output = try await execute(
            request: request,
            script: rollbackScript(
                method: request.method,
                installDirectory: request.installDirectory,
                ports: .standard,
                healthAttempts: Self.healthAttempts
            )
        )
        return parseResult(output)
    }

    func latestBackup(request: DeploymentExecutionRequest) async throws -> String? {
        let output = try await execute(
            request: request,
            script: latestBackupScript(installDirectory: request.installDirectory)
        )
        let path = output
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasPrefix("OASES_CPA_BACKUP=") })
            .map { String($0.dropFirst("OASES_CPA_BACKUP=".count)) }
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// The upgrade script `upgrade` would run. `gatewayPayloadBase64` defaults to the verified
    /// package of `pins.gateway` (empty when unavailable: the script then stops with 24);
    /// `ports` other than `.standard` and fewer `healthAttempts` are for scratch runs and tests.
    func upgradeScriptForVerification(
        method: DeploymentMethod,
        installDirectory: String,
        pins: DeploymentPinSet = .current,
        gatewayPayloadBase64: String? = nil,
        ports: DeploymentScriptPorts = .standard,
        healthAttempts: Int = DeploymentMaintenanceService.healthAttempts
    ) -> String {
        let payload = gatewayPayloadBase64
            ?? (try? pins.gateway.verifiedPayload(in: GatewayBundle.resourceBundle))?.base64EncodedString()
            ?? ""
        return upgradeScript(
            method: method,
            installDirectory: installDirectory,
            pins: pins,
            gatewayPayloadBase64: payload,
            ports: ports,
            healthAttempts: healthAttempts
        )
    }

    func rollbackScriptForVerification(
        method: DeploymentMethod,
        installDirectory: String,
        ports: DeploymentScriptPorts = .standard,
        healthAttempts: Int = DeploymentMaintenanceService.healthAttempts
    ) -> String {
        rollbackScript(method: method, installDirectory: installDirectory, ports: ports, healthAttempts: healthAttempts)
    }

    func latestBackupScriptForVerification(installDirectory: String) -> String {
        latestBackupScript(installDirectory: installDirectory)
    }

    func parseResultForVerification(_ output: String) -> DeploymentMaintenanceResult {
        parseResult(output)
    }

    /// Exit 22 with the guard's line on stderr becomes `downgradeRefused`; everything else keeps
    /// the general mapping.
    static func mapError(_ error: BoundedProcessError) -> DeploymentExecutionError {
        if case .nonZero(22, _, let standardError) = error,
           let refusal = DowngradeRefusal(standardError: standardError) {
            return .downgradeRefused(component: refusal.component, installed: refusal.installed, target: refusal.target)
        }
        return .commandFailed(
            BoundedProcessRunner.userFacingMessage(
                for: error,
                fallback: OasesLocalization.localized("目标终端维护命令失败。")
            )
        )
    }

    private func parseResult(_ output: String) -> DeploymentMaintenanceResult {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let backupPath = values["OASES_CPA_BACKUP"] ?? ""
        let fingerprint = values["OASES_PACK_ENGINE_KEY_SHA256"].flatMap { value in
            value.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == nil ? nil : value
        }
        return DeploymentMaintenanceResult(
            backupName: URL(fileURLWithPath: backupPath).lastPathComponent,
            detail: values["OASES_CPA_MAINTENANCE_DETAIL"] ?? OasesLocalization.localized("目标服务已完成维护操作。"),
            topology: values["OASES_CPA_TOPOLOGY"].flatMap(DeploymentTopology.init(rawValue:)) ?? .legacy,
            packEngineKeyFingerprint: fingerprint
        )
    }

    private func execute(request: DeploymentExecutionRequest, script: String) async throws -> String {
        do {
            switch request.target {
            case .local:
                return try await BoundedProcessRunner.run(
                    executable: "/bin/bash",
                    arguments: ["-s"],
                    standardInput: script,
                    timeout: 45 * 60
                ).standardOutput
            case .ssh:
                let sshArguments = try SSHConnectionService.connectionArguments(
                    port: request.port,
                    privateKeyPath: request.privateKeyPath
                )
                return try await BoundedProcessRunner.run(
                    executable: "/usr/bin/ssh",
                    arguments: sshArguments + ["\(request.user)@\(request.host)", "bash -s"],
                    standardInput: script,
                    timeout: 45 * 60
                ).standardOutput
            }
        } catch let error as BoundedProcessError {
            throw Self.mapError(error)
        }
    }

    private func upgradeScript(
        method: DeploymentMethod,
        installDirectory: String,
        pins: DeploymentPinSet,
        gatewayPayloadBase64: String,
        ports: DeploymentScriptPorts,
        healthAttempts: Int
    ) -> String {
        switch method {
        case .native:
            nativeUpgradeScript(
                installDirectory: installDirectory,
                pins: pins,
                gatewayPayloadBase64: gatewayPayloadBase64,
                ports: ports,
                healthAttempts: healthAttempts
            )
        case .docker:
            dockerUpgradeScript(installDirectory: installDirectory, pins: pins)
        }
    }

    private func rollbackScript(
        method: DeploymentMethod,
        installDirectory: String,
        ports: DeploymentScriptPorts,
        healthAttempts: Int
    ) -> String {
        switch method {
        case .native:
            nativeRollbackScript(installDirectory: installDirectory, ports: ports, healthAttempts: healthAttempts)
        case .docker:
            dockerRollbackScript(installDirectory: installDirectory)
        }
    }

    private func latestBackupScript(installDirectory: String) -> String {
        let root = shellQuote(installDirectory)
        return """
        set -euo pipefail
        ROOT=\(root)
        case "$ROOT" in
          "~") ROOT="$HOME" ;;
          "~/"*) ROOT="$HOME/$(printf '%s' "$ROOT" | cut -c 3-)" ;;
        esac
        ROOT="$(printf '%s' "$ROOT" | sed 's#/$##')"
        BACKUP_ROOT=""
        if [ -d "$ROOT/backups" ]; then
          BACKUP_ROOT="$(find "$ROOT/backups" -mindepth 1 -maxdepth 1 -type d -name 'upgrade-*' -print 2>/dev/null | sort | tail -n 1 || true)"
        fi
        if [ -n "$BACKUP_ROOT" ]; then printf 'OASES_CPA_BACKUP=%s\\n' "$BACKUP_ROOT"; fi
        """
    }

    // MARK: - Shared native pieces

    private func rootPrelude(installDirectory: String) -> String {
        """
        ROOT=\(shellQuote(installDirectory))
        case "$ROOT" in
          "~") ROOT="$HOME" ;;
          "~/"*) ROOT="$HOME/$(printf '%s' "$ROOT" | cut -c 3-)" ;;
        esac
        ROOT="$(printf '%s' "$ROOT" | sed 's#/$##')"
        [ "$ROOT" != "" ] && [ "$ROOT" != "/" ] || { printf '%s\\n' '维护目录无效，为保护文件系统已停止。' >&2; exit 18; }
        [ -f "$ROOT/.oases-cpa-installed" ] || { printf '%s\\n' '未找到已安装的 Oases CPA 部署。' >&2; exit 18; }
        [ ! -L "$ROOT" ] || { printf '%s\\n' '安装目录是符号链接，已停止维护。' >&2; exit 25; }
        """
    }

    /// Bash functions both native scripts use: the lifecycle stop/start (as subshells), the
    /// health wait and `oases_restore_backup`.
    private func nativeMaintenanceFunctions(installDirectory: String, ports: DeploymentScriptPorts, healthAttempts: Int) -> String {
        let lifecycle = RuntimeLifecycleService()
        let stopScript = lifecycle.stopScriptForVerification(method: .native, installDirectory: installDirectory)
        let startScript = lifecycle.startScriptForVerification(method: .native, installDirectory: installDirectory)
        return """
        CPAMP_PORT=\(ports.cpamp)
        HEALTH_ATTEMPTS=\(max(1, healthAttempts))
        \(DeploymentScriptFragments.managedProcessList(topology: .gateway))
        \(DeploymentScriptFragments.managedProcessStop())
        \(DeploymentScriptFragments.managementCurl())
        \(DeploymentScriptFragments.versionCompareFunctions())
        \(DeploymentScriptFragments.readInstalledVersions())
        \(DeploymentScriptFragments.writeVersionsFile())

        oases_stop_all() {
          (
        \(stopScript)
          )
        }
        oases_start_all() {
          (
        \(startScript)
          )
        }

        # The engine listens where its config.yaml says (8317 in the legacy layout, 18316 behind
        # the gateway); the gateway admin port is the one gateway/run.sh exports.
        oases_engine_port() {
          sed -n 's/^port:[[:space:]]*\\([0-9][0-9]*\\)[[:space:]]*$/\\1/p' "$ROOT/cli-proxy-api/config.yaml" 2>/dev/null | head -n 1
        }
        oases_gateway_admin_port() {
          sed -n 's/^export ADMIN_LISTEN_PORT=\\([0-9][0-9]*\\)$/\\1/p' "$ROOT/gateway/run.sh" 2>/dev/null | head -n 1
        }

        # oases_wait_services <legacy|gateway> [<gateway version>]: the engine (management API,
        # Bearer key through oases_mgmt_curl) and CPA Manager Plus, then for the gateway
        # topology /healthz without credentials, with the expected version, while our own
        # gateway process lives, on two checks one second apart (a gateway that dies right after
        # its start must not pass on the first answer).
        oases_wait_services() {
          local topology="$1" expected="${2:-}" engine_port admin_port gateway_pid body ready=0 confirmed=0
          engine_port="$(oases_engine_port)"
          [ -n "$engine_port" ] || { printf '%s\\n' '引擎配置中没有可用的端口。' >&2; return 1; }
          for _ in $(seq 1 "$HEALTH_ATTEMPTS"); do
            if oases_mgmt_curl "$ROOT/secrets/cpa-management-key" -fsS -o /dev/null "http://127.0.0.1:$engine_port/v0/management/config" >/dev/null 2>&1 &&
               curl -fsS -o /dev/null "http://127.0.0.1:$CPAMP_PORT/health" >/dev/null 2>&1; then
              ready=1
              break
            fi
            sleep 1
          done
          [ "$ready" -eq 1 ] || { printf '%s\\n' 'CLIProxyAPI 或 CPA Manager Plus 没有通过健康检查。' >&2; return 1; }
          [ "$topology" = gateway ] || return 0
          admin_port="$(oases_gateway_admin_port)"
          [ -n "$admin_port" ] || { printf '%s\\n' 'gateway/run.sh 没有管理端口。' >&2; return 1; }
          gateway_pid="$(cat "$ROOT/gateway.pid" 2>/dev/null || true)"
          for _ in $(seq 1 "$HEALTH_ATTEMPTS"); do
            body="$(curl -fsS --max-time 2 "http://127.0.0.1:$admin_port/healthz" 2>/dev/null || true)"
            case "$body" in
              *'"ok":true'*'"version":"'"$expected"'"'*)
                if oases_pid_owned_by "$gateway_pid" "$ROOT/gateway"; then
                  confirmed=$((confirmed + 1))
                  [ "$confirmed" -lt 2 ] || return 0
                fi
                ;;
              *) confirmed=0 ;;
            esac
            oases_pid_owned_by "$gateway_pid" "$ROOT/gateway" || break
            sleep 1
          done
          printf '%s\\n' 'Oases 网关没有通过健康检查。' >&2
          return 1
        }

        oases_after_path() {
          local candidate="$1"
          if [ -e "$candidate" ] || [ -L "$candidate" ]; then candidate="$candidate-$(date -u '+%Y%m%dT%H%M%SZ')-$$"; fi
          printf '%s' "$candidate"
        }

        # The topology a backup belongs to. A backup of app 0.1.4 has neither versions.json nor
        # versions.absent nor gateway-data/: that is the legacy layout.
        oases_backup_topology() {
          if [ -f "$1/versions.json" ] && [ -f "$1/gateway-run.sh" ]; then
            printf '%s' gateway
          else
            printf '%s' legacy
          fi
        }

        # oases_restore_backup <backup>: puts back run scripts, the engine config, the runtime
        # directories moved aside, cpamp/config.json, the versions file, gateway/run.sh, the
        # node/ and gateway/ symlinks and gateway-data/. What only the newer version had is
        # moved into the backup (…-after-upgrade), never deleted. Needs stopped processes.
        oases_restore_backup() {
          local backup="$1" package package_name link name
          [ -d "$backup" ] || return 1
          if [ -f "$backup/cli-proxy-api-run.sh" ]; then cp -p "$backup/cli-proxy-api-run.sh" "$ROOT/cli-proxy-api/run.sh" || return 1; fi
          if [ -f "$backup/cpamp-run.sh" ]; then cp -p "$backup/cpamp-run.sh" "$ROOT/cpamp/run.sh" || return 1; fi
          if [ -f "$backup/cli-proxy-api-config.yaml" ]; then cp -p "$backup/cli-proxy-api-config.yaml" "$ROOT/cli-proxy-api/config.yaml" || return 1; fi
          for package in "$backup/cli-proxy-api-runtime"/*; do
            [ -e "$package" ] || continue
            package_name="$(basename "$package")"
            rm -rf "$ROOT/cli-proxy-api/runtime/$package_name"
            mv "$package" "$ROOT/cli-proxy-api/runtime/$package_name" || return 1
          done
          for package in "$backup/cpamp-runtime"/*; do
            [ -e "$package" ] || continue
            package_name="$(basename "$package")"
            rm -rf "$ROOT/cpamp/runtime/$package_name"
            mv "$package" "$ROOT/cpamp/runtime/$package_name" || return 1
          done
          if [ -f "$backup/cpamp-config.json" ]; then
            cp -p "$backup/cpamp-config.json" "$ROOT/cpamp/config.json" || return 1
          elif [ -f "$ROOT/cpamp/config.json" ]; then
            mv "$ROOT/cpamp/config.json" "$(oases_after_path "$backup/cpamp-config.json.after-upgrade")" || return 1
          fi
          if [ -f "$backup/versions.json" ]; then
            cp -p "$backup/versions.json" "$ROOT/.oases-cpa-versions" || return 1
          elif [ -f "$ROOT/.oases-cpa-versions" ]; then
            mv "$ROOT/.oases-cpa-versions" "$(oases_after_path "$backup/versions-after-upgrade.json")" || return 1
          fi
          if [ -f "$backup/gateway-run.sh" ]; then
            mkdir -p "$ROOT/gateway" && cp -p "$backup/gateway-run.sh" "$ROOT/gateway/run.sh" || return 1
          elif [ -f "$ROOT/gateway/run.sh" ]; then
            mv "$ROOT/gateway/run.sh" "$(oases_after_path "$backup/gateway-run.sh.after-upgrade")" || return 1
          fi
          for name in gateway node; do
            [ -f "$backup/$name-current" ] || continue
            link="$(head -n 1 "$backup/$name-current")"
            case "$link" in ''|*/*|.|..) continue ;; esac
            if [ -d "$ROOT/$name/$link" ]; then ln -sfn "$link" "$ROOT/$name/current" || return 1; fi
          done
          if [ -d "$backup/gateway-data" ] && [ -f "$backup/gateway-data.saved" ]; then
            if [ -e "$ROOT/gateway-data" ]; then
              mv "$ROOT/gateway-data" "$(oases_after_path "$backup/gateway-data-after-upgrade")" || return 1
            fi
            cp -Rp "$backup/gateway-data" "$ROOT/gateway-data" || return 1
          elif [ "$(oases_backup_topology "$backup")" = legacy ] && [ -e "$ROOT/gateway-data" ]; then
            mv "$ROOT/gateway-data" "$(oases_after_path "$backup/gateway-data-after-upgrade")" || return 1
          fi
          return 0
        }
        """
    }

    // MARK: - Native upgrade

    private func nativeUpgradeScript(
        installDirectory: String,
        pins: DeploymentPinSet,
        gatewayPayloadBase64: String,
        ports: DeploymentScriptPorts,
        healthAttempts: Int
    ) -> String {
        """
        set -euo pipefail
        umask 077

        \(rootPrelude(installDirectory: installDirectory))
        command -v curl >/dev/null 2>&1 || { printf '%s\\n' '目标环境缺少 curl。' >&2; exit 13; }
        command -v tar >/dev/null 2>&1 || { printf '%s\\n' '目标环境缺少 tar。' >&2; exit 13; }
        command -v openssl >/dev/null 2>&1 || { printf '%s\\n' '目标环境缺少 openssl。' >&2; exit 13; }
        if command -v shasum >/dev/null 2>&1; then SHA256_COMMAND="shasum"; elif command -v sha256sum >/dev/null 2>&1; then SHA256_COMMAND="sha256sum"; else printf '%s\\n' '目标环境缺少 shasum 或 sha256sum。' >&2; exit 13; fi

        case "$(uname -s)" in
          Darwin) RELEASE_OS="darwin" ;;
          Linux) RELEASE_OS="linux" ;;
          *) printf '%s\\n' '目标系统不是支持的 macOS 或 Linux。' >&2; exit 14 ;;
        esac
        case "$(uname -m)" in
          arm64|aarch64) ARCH="arm64" ;;
          x86_64|amd64) ARCH="amd64" ;;
          *) printf '%s\\n' '目标架构不在官方原生包支持范围内。' >&2; exit 14 ;;
        esac

        \(pins.nativeSelectionScript())
        GATEWAY_PAYLOAD_BASE64='\(gatewayPayloadBase64)'
        ENGINE_PORT=\(ports.engine)
        GATEWAY_API_PORT=\(ports.gatewayAPI)
        GATEWAY_ADMIN_PORT=\(ports.gatewayAdmin)

        \(nativeMaintenanceFunctions(installDirectory: installDirectory, ports: ports, healthAttempts: healthAttempts))
        \(DeploymentScriptFragments.engineRunScript())
        \(DeploymentScriptFragments.cpampRunScript())
        \(DeploymentScriptFragments.gatewayRunScript())
        \(DeploymentScriptFragments.installNode())
        \(DeploymentScriptFragments.installGateway())
        \(DeploymentScriptFragments.securePrivateDirectories())
        \(DeploymentScriptFragments.runBootstrap())

        curl_retry() {
          local attempt
          for attempt in 1 2 3 4; do
            if curl --connect-timeout 20 --speed-limit 1024 --speed-time 60 --max-time 1800 "$@"; then
              return 0
            fi
            [ "$attempt" -lt 4 ] || return 1
            sleep $((attempt * 2))
          done
        }

        verify_fixed_archive() {
          local expected="$1" archive_name="$2" archive_path="$3" actual
          case "$expected" in
            ''|*[!0-9a-fA-F]*) printf '%s\\n' '固定发布摘要格式无效。' >&2; return 17 ;;
          esac
          [ "${#expected}" -eq 64 ] || { printf '%s\\n' '固定发布摘要长度无效。' >&2; return 17; }
          if [ "$SHA256_COMMAND" = "shasum" ]; then actual="$(shasum -a 256 "$archive_path" | awk '{print $1}')"; else actual="$(sha256sum "$archive_path" | awk '{print $1}')"; fi
          [ "$actual" = "$expected" ] || { printf '固定 SHA-256 校验失败：%s。\\n' "$archive_name" >&2; return 17; }
        }

        yaml_escape() {
          printf '%s' "$1" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g'
        }

        # --- No downgrade: compare before anything is stopped, backed up or written. ---
        oases_read_installed_versions "$ROOT"
        oases_refuse_downgrade() {
          printf 'OASES_DOWNGRADE_REFUSED component=%s installed=%s target=%s\\n' "$1" "$2" "$3" >&2
          printf '%s\\n' '目标上的组件版本高于本应用要安装的版本，已拒绝降级，未做任何改动。' >&2
          exit 22
        }
        if oases_version_gt "$INSTALLED_ENGINE" "$CLI_VERSION_TAG"; then oases_refuse_downgrade engine "$INSTALLED_ENGINE" "$CLI_VERSION_TAG"; fi
        if oases_version_gt "$INSTALLED_CPAMP" "$CPAMP_VERSION_TAG"; then oases_refuse_downgrade cpamp "$INSTALLED_CPAMP" "$CPAMP_VERSION_TAG"; fi
        if oases_version_gt "$INSTALLED_NODE" "$NODE_VERSION_TAG"; then oases_refuse_downgrade node "$INSTALLED_NODE" "$NODE_VERSION_TAG"; fi
        if oases_version_gt "$INSTALLED_GATEWAY" "$GATEWAY_VERSION"; then oases_refuse_downgrade gateway "$INSTALLED_GATEWAY" "$GATEWAY_VERSION"; fi

        if [ -x "$ROOT/gateway/run.sh" ] && [ -n "$INSTALLED_GATEWAY" ]; then
          PREVIOUS_TOPOLOGY="gateway"
        else
          PREVIOUS_TOPOLOGY="legacy"
        fi
        \(nativeTargetTopologyDecision())

        # --- Backup (before anything changes). ---
        BACKUP_NAME="upgrade-$(date -u '+%Y%m%d-%H%M%S')"
        if [ -e "$ROOT/backups/$BACKUP_NAME" ]; then BACKUP_NAME="$BACKUP_NAME-$$"; fi
        BACKUP_ROOT="$ROOT/backups/$BACKUP_NAME"
        TEMP_ROOT="$ROOT/.oases-cpa-upgrade-$BACKUP_NAME"
        mkdir -p "$ROOT/backups"
        mkdir -m 700 "$BACKUP_ROOT"
        mkdir -p "$BACKUP_ROOT/cli-proxy-api-runtime" "$BACKUP_ROOT/cpamp-runtime" "$TEMP_ROOT"
        if [ -f "$ROOT/cli-proxy-api/run.sh" ]; then cp -p "$ROOT/cli-proxy-api/run.sh" "$BACKUP_ROOT/cli-proxy-api-run.sh"; fi
        if [ -f "$ROOT/cpamp/run.sh" ]; then cp -p "$ROOT/cpamp/run.sh" "$BACKUP_ROOT/cpamp-run.sh"; fi
        if [ -f "$ROOT/cli-proxy-api/config.yaml" ]; then cp -p "$ROOT/cli-proxy-api/config.yaml" "$BACKUP_ROOT/cli-proxy-api-config.yaml"; fi
        if [ -f "$ROOT/cpamp/config.json" ]; then cp -p "$ROOT/cpamp/config.json" "$BACKUP_ROOT/cpamp-config.json"; fi
        if [ -f "$ROOT/.oases-cpa-versions" ]; then cp -p "$ROOT/.oases-cpa-versions" "$BACKUP_ROOT/versions.json"; else : > "$BACKUP_ROOT/versions.absent"; fi
        if [ -f "$ROOT/gateway/run.sh" ]; then cp -p "$ROOT/gateway/run.sh" "$BACKUP_ROOT/gateway-run.sh"; fi
        if [ -L "$ROOT/gateway/current" ]; then readlink "$ROOT/gateway/current" > "$BACKUP_ROOT/gateway-current"; fi
        if [ -L "$ROOT/node/current" ]; then readlink "$ROOT/node/current" > "$BACKUP_ROOT/node-current"; fi
        printf '%s\\n' "$PREVIOUS_TOPOLOGY" > "$BACKUP_ROOT/topology"

        upgrade_exit() {
          local status="$?"
          trap - EXIT
          set +e
          if [ "$status" -ne 0 ]; then
            printf '升级失败（退出码 %s），正在恢复升级前的版本。\\n' "$status" >&2
            oases_stop_all >/dev/null 2>&1
            oases_restore_backup "$BACKUP_ROOT" || printf '%s\\n' '自动恢复不完整，请使用回滚并查看 backups 目录。' >&2
            oases_start_all >/dev/null 2>&1
          fi
          rm -rf "$TEMP_ROOT" >/dev/null 2>&1
          exit "$status"
        }
        trap upgrade_exit EXIT

        # --- Stop all three processes (gateway first, up to 30 s), then copy gateway-data. ---
        oases_stop_all
        if [ -d "$ROOT/gateway-data" ] && [ ! -L "$ROOT/gateway-data" ]; then
          cp -Rp "$ROOT/gateway-data" "$BACKUP_ROOT/gateway-data"
          : > "$BACKUP_ROOT/gateway-data.saved"
        fi

        # --- Engine (CLIProxyAPI). ---
        CLI_TEMP_DIR="$TEMP_ROOT/cli-proxy-api/runtime/$CLI_PACKAGE"
        CLI_ARCHIVE="$TEMP_ROOT/cli-proxy-api/$CLI_ASSET"
        mkdir -p "$CLI_TEMP_DIR"
        curl_retry --fail --silent --show-error --location --max-redirs 3 --proto '=https' --proto-redir '=https' --max-filesize \(DeploymentPinSet.nativeArchiveMaxBytes) "https://github.com/router-for-me/CLIProxyAPI/releases/download/$CLI_VERSION_TAG/$CLI_ASSET" -o "$CLI_ARCHIVE" || exit 18
        verify_fixed_archive "$CLI_EXPECTED_SHA256" "$CLI_ASSET" "$CLI_ARCHIVE" || exit 17
        oases_archive_paths_are_relative "$CLI_ARCHIVE" || { printf '%s\\n' 'CLIProxyAPI 升级包含有绝对路径或 .. 路径，已拒绝。' >&2; exit 17; }
        tar -xzf "$CLI_ARCHIVE" -C "$CLI_TEMP_DIR"
        [ -f "$CLI_TEMP_DIR/cli-proxy-api" ] || { printf '%s\\n' 'CLIProxyAPI 升级包中没有找到 cli-proxy-api。' >&2; exit 15; }
        chmod 755 "$CLI_TEMP_DIR/cli-proxy-api"
        mkdir -p "$ROOT/cli-proxy-api/runtime"
        if [ -e "$ROOT/cli-proxy-api/runtime/$CLI_PACKAGE" ]; then mv "$ROOT/cli-proxy-api/runtime/$CLI_PACKAGE" "$BACKUP_ROOT/cli-proxy-api-runtime/$CLI_PACKAGE"; fi
        mv "$CLI_TEMP_DIR" "$ROOT/cli-proxy-api/runtime/$CLI_PACKAGE"
        oases_write_engine_run "$ROOT/cli-proxy-api" "$ROOT/cli-proxy-api/runtime/$CLI_PACKAGE/cli-proxy-api"

        # --- CPA Manager Plus (fixed cpamp/config.json, data/ untouched). ---
        CPAMP_TEMP_DIR="$TEMP_ROOT/cpamp/runtime"
        CPAMP_ARCHIVE="$TEMP_ROOT/cpamp/$CPAMP_ASSET"
        mkdir -p "$CPAMP_TEMP_DIR"
        curl_retry --fail --silent --show-error --location --max-redirs 3 --proto '=https' --proto-redir '=https' --max-filesize \(DeploymentPinSet.nativeArchiveMaxBytes) "https://github.com/seakee/CPA-Manager-Plus/releases/download/$CPAMP_VERSION_TAG/$CPAMP_ASSET" -o "$CPAMP_ARCHIVE" || exit 18
        verify_fixed_archive "$CPAMP_EXPECTED_SHA256" "$CPAMP_ASSET" "$CPAMP_ARCHIVE" || exit 17
        oases_archive_paths_are_relative "$CPAMP_ARCHIVE" || { printf '%s\\n' 'CPA Manager Plus 升级包含有绝对路径或 .. 路径，已拒绝。' >&2; exit 17; }
        tar -xzf "$CPAMP_ARCHIVE" -C "$CPAMP_TEMP_DIR"
        [ -f "$CPAMP_TEMP_DIR/$CPAMP_PACKAGE/cpa-manager-plus" ] || { printf '%s\\n' 'CPA Manager Plus 升级包中没有找到 cpa-manager-plus。' >&2; exit 16; }
        chmod 755 "$CPAMP_TEMP_DIR/$CPAMP_PACKAGE/cpa-manager-plus"
        mkdir -p "$ROOT/cpamp/runtime" "$ROOT/cpamp/data"
        if [ -e "$ROOT/cpamp/runtime/$CPAMP_PACKAGE" ]; then mv "$ROOT/cpamp/runtime/$CPAMP_PACKAGE" "$BACKUP_ROOT/cpamp-runtime/$CPAMP_PACKAGE"; fi
        mv "$CPAMP_TEMP_DIR/$CPAMP_PACKAGE" "$ROOT/cpamp/runtime/$CPAMP_PACKAGE"

        \(nativeTopologyStep())

        CPAMP_DATA_JSON="$(yaml_escape "$ROOT/cpamp/data")"
        CPAMP_ADMIN_KEY_JSON="$(yaml_escape "$ROOT/secrets/cpamp-admin-key")"
        CPAMP_DATA_KEY_JSON="$(yaml_escape "$ROOT/cpamp/data/data.key")"
        CPAMP_MANAGEMENT_KEY_JSON="$(yaml_escape "$ROOT/secrets/cpa-management-key")"
        CPAMP_UPSTREAM_PORT="$(oases_engine_port)"
        [ -n "$CPAMP_UPSTREAM_PORT" ] || { printf '%s\\n' '引擎配置中没有可用的端口。' >&2; exit 27; }
        cat > "$ROOT/cpamp/config.json.part.$$" <<EOF
        {
          "httpAddr": "127.0.0.1:$CPAMP_PORT",
          "dataDir": "$CPAMP_DATA_JSON",
          "adminKeyFile": "$CPAMP_ADMIN_KEY_JSON",
          "dataKeyPath": "$CPAMP_DATA_KEY_JSON",
          "cpaUpstreamUrl": "http://127.0.0.1:$CPAMP_UPSTREAM_PORT",
          "managementKeyFile": "$CPAMP_MANAGEMENT_KEY_JSON",
          "collectorMode": "auto",
          "queue": "usage",
          "popSide": "right",
          "batchSize": 100,
          "pollIntervalMs": 500,
          "queryLimit": 50000
        }
        EOF
        mv "$ROOT/cpamp/config.json.part.$$" "$ROOT/cpamp/config.json"
        oases_write_cpamp_run "$ROOT/cpamp" "$ROOT/cpamp/runtime/$CPAMP_PACKAGE/cpa-manager-plus"

        # --- Start (engine, CPA Manager Plus, gateway) and wait. ---
        oases_start_all
        if [ "$TARGET_TOPOLOGY" = gateway ]; then
          oases_wait_services gateway "$GATEWAY_VERSION" || exit 26
          oases_write_versions "$ROOT" "$CLI_VERSION_TAG" "$CPAMP_VERSION_TAG" "$NODE_VERSION_TAG" "$GATEWAY_VERSION"
        else
          oases_wait_services legacy || exit 26
          oases_write_versions "$ROOT" "$CLI_VERSION_TAG" "$CPAMP_VERSION_TAG"
        fi

        # --- Keep the two newest previous versions of Node and the gateway. ---
        PRUNE_ROOT="$ROOT/backups/pruned-$(date -u '+%Y%m%d-%H%M%S')"
        oases_prune_old_versions() {
          local dir="$1" current entry count=0
          [ -d "$ROOT/$dir" ] || return 0
          current="$(readlink "$ROOT/$dir/current" 2>/dev/null || true)"
          for entry in $(ls -1t "$ROOT/$dir"); do
            case "$entry" in current|downloads|run.sh|.*) continue ;; esac
            [ -d "$ROOT/$dir/$entry" ] && [ ! -L "$ROOT/$dir/$entry" ] || continue
            [ "$entry" != "$current" ] || continue
            count=$((count + 1))
            if [ "$count" -gt 2 ]; then
              mkdir -p "$PRUNE_ROOT/$dir"
              mv "$ROOT/$dir/$entry" "$PRUNE_ROOT/$dir/$entry"
            fi
          done
        }
        oases_prune_old_versions node
        oases_prune_old_versions gateway

        if [ -s "$ROOT/secrets/pack-engine-key" ]; then
          if [ "$SHA256_COMMAND" = "shasum" ]; then
            PACK_ENGINE_KEY_SHA256="$(tr -d '\\n' < "$ROOT/secrets/pack-engine-key" | shasum -a 256 | awk '{print $1}')"
          else
            PACK_ENGINE_KEY_SHA256="$(tr -d '\\n' < "$ROOT/secrets/pack-engine-key" | sha256sum | awk '{print $1}')"
          fi
          printf 'OASES_PACK_ENGINE_KEY_SHA256=%s\\n' "$PACK_ENGINE_KEY_SHA256"
        fi
        printf 'OASES_CPA_BACKUP=%s\\n' "$BACKUP_ROOT"
        printf 'OASES_CPA_TOPOLOGY=%s\\n' "$TARGET_TOPOLOGY"
        if [ "$TARGET_TOPOLOGY" = gateway ]; then
          printf 'OASES_CPA_MAINTENANCE_DETAIL=%s\\n' '已升级 CLIProxyAPI、CPA Manager Plus、Node 与 Oases 网关；配置、认证文件和数据保持不变，升级前的版本与网关数据已备份。'
        else
          printf 'OASES_CPA_MAINTENANCE_DETAIL=%s\\n' '已升级 CLIProxyAPI 与 CPA Manager Plus；原配置、认证文件和 CPAMP 数据保持不变。'
        fi
        """
    }

    /// Sets `TARGET_TOPOLOGY`. A gateway deployment stays one; a legacy 0.1.x deployment keeps
    /// its layout (engine on 8317, no gateway).
    private func nativeTargetTopologyDecision() -> String {
        """
        TARGET_TOPOLOGY="$PREVIOUS_TOPOLOGY"
        """
    }

    /// The topology-specific install step after the engine and CPA Manager Plus: Node, the
    /// gateway package, `gateway/run.sh` (following the new versions), private directories and
    /// the idempotent bootstrap.
    private func nativeTopologyStep() -> String {
        """
        if [ "$TARGET_TOPOLOGY" = gateway ]; then
          oases_install_node "$ROOT"
          oases_install_gateway "$ROOT"
          oases_write_gateway_run "$ROOT" "$CLI_VERSION_TAG" "$CPAMP_VERSION_TAG" "$GATEWAY_API_PORT" "$GATEWAY_ADMIN_PORT" "$ENGINE_PORT"
          oases_secure_private_directories "$ROOT"
          oases_run_bootstrap "$ROOT"
        fi
        """
    }

    // MARK: - Native rollback

    private func nativeRollbackScript(installDirectory: String, ports: DeploymentScriptPorts, healthAttempts: Int) -> String {
        """
        set -euo pipefail
        umask 077
        \(rootPrelude(installDirectory: installDirectory))
        \(nativeMaintenanceFunctions(installDirectory: installDirectory, ports: ports, healthAttempts: healthAttempts))

        BACKUP_ROOT=""
        if [ -d "$ROOT/backups" ]; then
          BACKUP_ROOT="$(find "$ROOT/backups" -mindepth 1 -maxdepth 1 -type d -name 'upgrade-*' -print 2>/dev/null | sort | tail -n 1 || true)"
        fi
        [ -n "$BACKUP_ROOT" ] || { printf '%s\\n' '目标目录中还没有可回滚的升级备份。' >&2; exit 19; }
        [ -f "$BACKUP_ROOT/cli-proxy-api-run.sh" ] || { printf '%s\\n' '升级备份缺少 CLIProxyAPI 启动脚本。' >&2; exit 19; }
        [ -f "$BACKUP_ROOT/cpamp-run.sh" ] || { printf '%s\\n' '升级备份缺少 CPAMP 启动脚本。' >&2; exit 19; }
        ROLLBACK_TOPOLOGY="$(oases_backup_topology "$BACKUP_ROOT")"
        ROLLBACK_GATEWAY_VERSION=""
        if [ "$ROLLBACK_TOPOLOGY" = gateway ]; then
          ROLLBACK_GATEWAY_VERSION="$(head -n 1 "$BACKUP_ROOT/gateway-current" 2>/dev/null || true)"
          case "$ROLLBACK_GATEWAY_VERSION" in ''|*/*|.|..) printf '%s\\n' '升级备份缺少网关版本记录。' >&2; exit 19 ;; esac
          [ -d "$ROOT/gateway/$ROLLBACK_GATEWAY_VERSION" ] || { printf '%s\\n' '升级前的网关版本目录已不存在，无法回滚。' >&2; exit 19; }
        fi

        oases_stop_all
        oases_restore_backup "$BACKUP_ROOT" || { printf '%s\\n' '回滚未能完整恢复备份，服务保持停止；请查看 backups 目录。' >&2; exit 19; }
        oases_start_all
        oases_wait_services "$ROLLBACK_TOPOLOGY" "$ROLLBACK_GATEWAY_VERSION" || exit 26
        printf 'OASES_CPA_BACKUP=%s\\n' "$BACKUP_ROOT"
        printf 'OASES_CPA_TOPOLOGY=%s\\n' "$ROLLBACK_TOPOLOGY"
        printf 'OASES_CPA_MAINTENANCE_DETAIL=%s\\n' '已恢复上一版原生运行时与网关数据；认证文件和 CPAMP 数据保持不变。'
        """
    }

    // MARK: - Docker

    private func dockerUpgradeScript(installDirectory: String, pins: DeploymentPinSet) -> String {
        let root = shellQuote(installDirectory)
        return """
        set -euo pipefail
        ROOT=\(root)
        case "$ROOT" in
          "~") ROOT="$HOME" ;;
          "~/"*) ROOT="$HOME/$(printf '%s' "$ROOT" | cut -c 3-)" ;;
        esac
        ROOT="$(printf '%s' "$ROOT" | sed 's#/$##')"
        [ -f "$ROOT/.oases-cpa-installed" ] || { printf '%s\\n' '未找到已安装的 Oases CPA 部署。' >&2; exit 18; }
        command -v docker >/dev/null 2>&1 || { printf '%s\\n' '目标环境缺少 Docker。' >&2; exit 13; }
        docker compose version >/dev/null 2>&1 || { printf '%s\\n' '目标环境缺少 Docker Compose。' >&2; exit 13; }
        docker info >/dev/null 2>&1 || { printf '%s\\n' 'Docker daemon 不可用，请先启动 Docker。' >&2; exit 13; }
        \(pins.dockerImageEnvironmentScript())
        CLI_VERSION_TAG="\(pins.engine.tag)"
        CPAMP_VERSION_TAG="\(pins.cpamp.tag)"
        \(DeploymentScriptFragments.versionCompareFunctions())
        \(DeploymentScriptFragments.readInstalledVersions())
        \(DeploymentScriptFragments.writeVersionsFile())
        # No downgrade (Docker records engine and cpamp only), before anything is pulled.
        INSTALLED_ENGINE=""
        INSTALLED_CPAMP=""
        if [ -f "$ROOT/.oases-cpa-versions" ]; then oases_read_installed_versions "$ROOT"; fi
        for pair in "engine:$INSTALLED_ENGINE:$CLI_VERSION_TAG" "cpamp:$INSTALLED_CPAMP:$CPAMP_VERSION_TAG"; do
          component="${pair%%:*}"; rest="${pair#*:}"; installed="${rest%%:*}"; target="${rest#*:}"
          if oases_version_gt "$installed" "$target"; then
            printf 'OASES_DOWNGRADE_REFUSED component=%s installed=%s target=%s\\n' "$component" "$installed" "$target" >&2
            printf '%s\\n' '目标上的组件版本高于本应用要安装的版本，已拒绝降级，未做任何改动。' >&2
            exit 22
          fi
        done
        BACKUP_NAME="upgrade-$(date -u '+%Y%m%d-%H%M%S')"
        if [ -e "$ROOT/backups/$BACKUP_NAME" ]; then BACKUP_NAME="$BACKUP_NAME-$$"; fi
        BACKUP_ROOT="$ROOT/backups/$BACKUP_NAME"
        mkdir -p "$BACKUP_ROOT" "$ROOT/logs"
        cp -p "$ROOT/compose.yaml" "$BACKUP_ROOT/compose.yaml"
        [ ! -e "$ROOT/.env" ] || cp -p "$ROOT/.env" "$BACKUP_ROOT/.env"
        if [ -f "$ROOT/.oases-cpa-versions" ]; then cp -p "$ROOT/.oases-cpa-versions" "$BACKUP_ROOT/versions.json"; else : > "$BACKUP_ROOT/versions.absent"; fi
        cd "$ROOT"
        CPAMP_IMAGE="$CPAMP_DOCKER_IMAGE" CPA_IMAGE="$CLI_DOCKER_IMAGE" docker compose pull > "$ROOT/logs/docker-upgrade-pull.log" 2>&1
        CPAMP_IMAGE="$CPAMP_DOCKER_IMAGE" CPA_IMAGE="$CLI_DOCKER_IMAGE" docker compose up -d > "$ROOT/logs/docker-upgrade-up.log" 2>&1
        for _ in $(seq 1 60); do
          if curl -fsS http://127.0.0.1:18317/health >/dev/null 2>&1; then break; fi
          sleep 1
        done
        curl -fsS http://127.0.0.1:18317/health >/dev/null
        oases_write_versions "$ROOT" "$CLI_VERSION_TAG" "$CPAMP_VERSION_TAG"
        printf 'OASES_CPA_BACKUP=%s\\n' "$BACKUP_ROOT"
        printf 'OASES_CPA_TOPOLOGY=%s\\n' legacy
        printf 'OASES_CPA_MAINTENANCE_DETAIL=%s\\n' '已拉取并重启 Docker Compose 服务；Docker 部署只包含上游 CLIProxyAPI 与 CPA Manager Plus，Oases 网关只支持原生部署。'
        """
    }

    private func dockerRollbackScript(installDirectory: String) -> String {
        let root = shellQuote(installDirectory)
        return """
        set -euo pipefail
        ROOT=\(root)
        case "$ROOT" in
          "~") ROOT="$HOME" ;;
          "~/"*) ROOT="$HOME/$(printf '%s' "$ROOT" | cut -c 3-)" ;;
        esac
        ROOT="$(printf '%s' "$ROOT" | sed 's#/$##')"
        [ -f "$ROOT/compose.yaml" ] || { printf '%s\\n' '未找到 Docker Compose 部署。' >&2; exit 18; }
        command -v docker >/dev/null 2>&1 || { printf '%s\\n' '目标环境缺少 Docker。' >&2; exit 13; }
        docker compose version >/dev/null 2>&1 || { printf '%s\\n' '目标环境缺少 Docker Compose。' >&2; exit 13; }
        docker info >/dev/null 2>&1 || { printf '%s\\n' 'Docker daemon 不可用，请先启动 Docker。' >&2; exit 13; }
        \(DeploymentPinSet.current.dockerImageEnvironmentScript())
        BACKUP_ROOT=""
        if [ -d "$ROOT/backups" ]; then
          BACKUP_ROOT="$(find "$ROOT/backups" -mindepth 1 -maxdepth 1 -type d -name 'upgrade-*' -print 2>/dev/null | sort | tail -n 1 || true)"
        fi
        [ -n "$BACKUP_ROOT" ] || { printf '%s\\n' '目标目录中还没有可回滚的升级备份。' >&2; exit 19; }
        [ -f "$BACKUP_ROOT/compose.yaml" ] || { printf '%s\\n' '升级备份缺少 Compose 文件。' >&2; exit 19; }
        cp -p "$BACKUP_ROOT/compose.yaml" "$ROOT/compose.yaml"
        if [ -f "$BACKUP_ROOT/.env" ]; then cp -p "$BACKUP_ROOT/.env" "$ROOT/.env"; fi
        if [ -f "$BACKUP_ROOT/versions.json" ]; then cp -p "$BACKUP_ROOT/versions.json" "$ROOT/.oases-cpa-versions"; fi
        cd "$ROOT"
        CPAMP_IMAGE="$CPAMP_DOCKER_IMAGE" CPA_IMAGE="$CLI_DOCKER_IMAGE" docker compose up -d > "$ROOT/logs/docker-rollback-up.log" 2>&1
        for _ in $(seq 1 60); do
          if curl -fsS http://127.0.0.1:18317/health >/dev/null 2>&1; then break; fi
          sleep 1
        done
        curl -fsS http://127.0.0.1:18317/health >/dev/null
        printf 'OASES_CPA_BACKUP=%s\\n' "$BACKUP_ROOT"
        printf 'OASES_CPA_TOPOLOGY=%s\\n' legacy
        printf 'OASES_CPA_MAINTENANCE_DETAIL=%s\\n' '已恢复上一版 Compose 配置；Docker 镜像是否可回退取决于备份中的镜像标签。'
        """
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

/// The guard's stderr line `OASES_DOWNGRADE_REFUSED component=<c> installed=<v> target=<v>`;
/// only known components and version-shaped values are accepted.
struct DowngradeRefusal: Equatable, Sendable {
    let component: String
    let installed: String
    let target: String

    init?(standardError: String) {
        guard let line = standardError.split(separator: "\n").first(where: { $0.hasPrefix("OASES_DOWNGRADE_REFUSED ") }) else {
            return nil
        }
        var fields: [String: String] = [:]
        for part in line.split(separator: " ").dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        guard let component = fields["component"], ["engine", "cpamp", "node", "gateway"].contains(component),
              let installed = fields["installed"], Self.isVersion(installed),
              let target = fields["target"], Self.isVersion(target) else { return nil }
        self.component = component
        self.installed = installed
        self.target = target
    }

    private static func isVersion(_ value: String) -> Bool {
        value.count <= 64 && value.range(of: "^[0-9A-Za-z][0-9A-Za-z.+_-]*$", options: .regularExpression) != nil
    }
}
