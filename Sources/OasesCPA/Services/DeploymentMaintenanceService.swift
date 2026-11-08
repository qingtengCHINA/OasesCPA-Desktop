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
/// the newest backup the same way. Authentication files are never rolled back; `gateway-data/`
/// and `secrets/` are, and CPA Manager Plus `data/` is whenever the rollback changes the
/// CPA Manager Plus binary (a newer version may have migrated `usage.sqlite` one way). The
/// newer copies are moved into the backup, never deleted. After every health check passed, a
/// root with the legacy install marker gets the ownership marker `.oases-cpa-managed`.
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
        if case .nonZero(_, _, let standardError) = error,
           let failure = UpgradeFailure(standardError: standardError) {
            return .upgradeFailed(failure)
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
        \(Self.latestBackupSelection())
        if [ -n "$BACKUP_ROOT" ] && [ "$BACKUP_INCOMPLETE" -eq 0 ]; then printf 'OASES_CPA_BACKUP=%s\\n' "$BACKUP_ROOT"; fi
        """
    }

    /// Sets `BACKUP_ROOT` to the newest `backups/upgrade-*` directory (empty when there is
    /// none) and `BACKUP_INCOMPLETE` to 1 when this app started that backup (`backup-started`)
    /// but never finished it (no `backup-complete`, written after the last copy). Backups of
    /// older builds carry neither marker and stay usable.
    static func latestBackupSelection() -> String {
        """
        BACKUP_ROOT=""
        BACKUP_INCOMPLETE=0
        if [ -d "$ROOT/backups" ]; then
          BACKUP_ROOT="$(find "$ROOT/backups" -mindepth 1 -maxdepth 1 -type d -name 'upgrade-*' -print 2>/dev/null | sort | tail -n 1 || true)"
        fi
        if [ -n "$BACKUP_ROOT" ] && [ -f "$BACKUP_ROOT/backup-started" ] && [ ! -f "$BACKUP_ROOT/backup-complete" ]; then
          BACKUP_INCOMPLETE=1
        fi
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
        \(DeploymentScriptFragments.gatewayHealthWait())
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
          local topology="$1" expected="${2:-}" engine_port admin_port gateway_pid ready=0
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
          if oases_wait_gateway_healthz "$admin_port" "$expected" "$gateway_pid" "$ROOT/gateway" "$HEALTH_ATTEMPTS" 2; then
            return 0
          fi
          printf '%s\\n' 'Oases 网关没有通过健康检查。' >&2
          return 1
        }

        # After the stop nothing of the deployment may run any more, pid file or not (a gateway
        # still writing gateway-data must not be copied or replaced). Exit 28, nothing changed.
        oases_refuse_if_still_running() {
          if oases_managed_process_alive_under "$ROOT"; then
            printf '%s\\n' '停止后目标目录中仍有 Oases CPA 进程在运行（没有可信的 PID 文件）；没有做任何改动，服务保持停止。请先结束这些进程再重试。' >&2
            exit 28
          fi
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
        # oases_restore_file <backup file> <current file> <kept name>: the backup's copy goes
        # back; the current file, when it differs, is first moved into the backup as
        # <kept name> (providers, upstream keys and client keys added since the upgrade stay
        # recoverable there).
        oases_restore_file() {
          local saved="$1" current="$2" kept="$3"
          [ -f "$saved" ] || return 0
          if [ -e "$current" ] && ! cmp -s "$saved" "$current"; then
            mv "$current" "$(oases_after_path "$kept")" || return 1
          fi
          cp -p "$saved" "$current"
        }
        # oases_restore_runtimes <backup dir> <runtime dir>: a runtime directory of the same name
        # (the newer package) is moved into the backup, never deleted.
        oases_restore_runtimes() {
          local saved="$1" runtime="$2" package package_name
          for package in "$saved"/*; do
            [ -e "$package" ] || continue
            package_name="$(basename "$package")"
            if [ -e "$runtime/$package_name" ] || [ -L "$runtime/$package_name" ]; then
              mkdir -p "$saved-after-upgrade" || return 1
              mv "$runtime/$package_name" "$(oases_after_path "$saved-after-upgrade/$package_name")" || return 1
            fi
            mv "$package" "$runtime/$package_name" || return 1
          done
        }

        # oases_restore_directory <backup dir> <current dir> <kept dir>: the current directory is
        # moved into the backup as <kept dir> (never deleted), then the backup's copy goes back.
        oases_restore_directory() {
          local saved="$1" current="$2" kept="$3"
          [ -d "$saved" ] || return 0
          if [ -e "$current" ] || [ -L "$current" ]; then
            mv "$current" "$(oases_after_path "$kept")" || return 1
          fi
          cp -Rp "$saved" "$current"
        }
        # oases_restore_secrets <backup>: every key of the backup goes back (a differing current
        # copy is kept in secrets-after-upgrade/); keys the upgrade created (the gateway's pack
        # keys after a 0.1.x migration) move there too. The directory itself stays (0700).
        oases_restore_secrets() {
          local backup="$1" saved current name kept="$1/secrets-after-upgrade"
          [ -f "$backup/secrets.saved" ] && [ -d "$backup/secrets" ] || return 0
          [ ! -L "$ROOT/secrets" ] || return 1
          mkdir -p "$ROOT/secrets" || return 1
          for current in "$ROOT/secrets"/* "$ROOT/secrets"/.[!.]*; do
            [ -e "$current" ] || [ -L "$current" ] || continue
            name="$(basename "$current")"
            if [ ! -e "$backup/secrets/$name" ]; then
              mkdir -m 700 -p "$kept" || return 1
              mv "$current" "$(oases_after_path "$kept/$name")" || return 1
            fi
          done
          for saved in "$backup/secrets"/* "$backup/secrets"/.[!.]*; do
            [ -f "$saved" ] || continue
            name="$(basename "$saved")"
            if [ -e "$ROOT/secrets/$name" ] && ! cmp -s "$saved" "$ROOT/secrets/$name"; then
              mkdir -m 700 -p "$kept" || return 1
              mv "$ROOT/secrets/$name" "$(oases_after_path "$kept/$name")" || return 1
            fi
            [ -e "$ROOT/secrets/$name" ] || cp -p "$saved" "$ROOT/secrets/$name" || return 1
          done
          return 0
        }

        oases_restore_backup() {
          local backup="$1" link name restore_cpamp_data=0
          [ -d "$backup" ] || return 1
          # CPA Manager Plus data comes back only when the rollback changes its binary (the
          # run script differs): a newer version may have migrated usage.sqlite forward. With
          # the same binary the usage recorded since the upgrade stays.
          if [ -f "$backup/cpamp-data.saved" ] && [ -d "$backup/cpamp-data" ] && ! cmp -s "$backup/cpamp-run.sh" "$ROOT/cpamp/run.sh"; then
            restore_cpamp_data=1
          fi
          oases_restore_file "$backup/cli-proxy-api-run.sh" "$ROOT/cli-proxy-api/run.sh" "$backup/cli-proxy-api-run.sh.after-upgrade" || return 1
          oases_restore_file "$backup/cpamp-run.sh" "$ROOT/cpamp/run.sh" "$backup/cpamp-run.sh.after-upgrade" || return 1
          oases_restore_file "$backup/cli-proxy-api-config.yaml" "$ROOT/cli-proxy-api/config.yaml" "$backup/cli-proxy-api-config.yaml.after-upgrade" || return 1
          oases_restore_runtimes "$backup/cli-proxy-api-runtime" "$ROOT/cli-proxy-api/runtime" || return 1
          oases_restore_runtimes "$backup/cpamp-runtime" "$ROOT/cpamp/runtime" || return 1
          if [ -f "$backup/cpamp-config.json" ]; then
            oases_restore_file "$backup/cpamp-config.json" "$ROOT/cpamp/config.json" "$backup/cpamp-config.json.after-upgrade" || return 1
          elif [ -f "$ROOT/cpamp/config.json" ]; then
            mv "$ROOT/cpamp/config.json" "$(oases_after_path "$backup/cpamp-config.json.after-upgrade")" || return 1
          fi
          if [ -f "$backup/versions.json" ]; then
            oases_restore_file "$backup/versions.json" "$ROOT/.oases-cpa-versions" "$backup/versions-after-upgrade.json" || return 1
          elif [ -f "$ROOT/.oases-cpa-versions" ]; then
            mv "$ROOT/.oases-cpa-versions" "$(oases_after_path "$backup/versions-after-upgrade.json")" || return 1
          fi
          if [ -f "$backup/gateway-run.sh" ]; then
            mkdir -p "$ROOT/gateway" || return 1
            oases_restore_file "$backup/gateway-run.sh" "$ROOT/gateway/run.sh" "$backup/gateway-run.sh.after-upgrade" || return 1
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
          if [ "$restore_cpamp_data" -eq 1 ]; then
            [ ! -L "$ROOT/cpamp/data" ] || return 1
            oases_restore_directory "$backup/cpamp-data" "$ROOT/cpamp/data" "$backup/cpamp-data-after-upgrade" || return 1
          fi
          oases_restore_secrets "$backup" || return 1
          # The legacy install marker goes back as it was. An ownership marker the upgrade wrote
          # (none before it, ours now) moves into the backup, so a restored 0.1.x root looks as
          # before. Pid files are not put back: the processes they named are stopped, and the
          # start writes the pid files of the restored ones.
          oases_restore_file "$backup/root-files/.oases-cpa-installed" "$ROOT/.oases-cpa-installed" "$backup/oases-cpa-installed.after-upgrade" || return 1
          if [ -f "$backup/root-files/managed-marker.absent" ] && [ -f "$ROOT/.oases-cpa-managed" ] && [ ! -L "$ROOT/.oases-cpa-managed" ] &&
             grep -Fqx 'owned-by=oases-cpa' "$ROOT/.oases-cpa-managed"; then
            mv "$ROOT/.oases-cpa-managed" "$(oases_after_path "$backup/oases-cpa-managed.after-upgrade")" || return 1
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
        LEGACY_ENGINE_PORT=\(ports.legacyEngine)
        GATEWAY_API_PORT=\(ports.gatewayAPI)
        GATEWAY_ADMIN_PORT=\(ports.gatewayAdmin)
        # The phase a failure belongs to (OASES_UPGRADE_FAILURE, mapped by the app to a
        # localized reason; DeploymentMaintenanceService.UpgradeFailure).
        UPGRADE_STAGE="prepare"

        \(nativeMaintenanceFunctions(installDirectory: installDirectory, ports: ports, healthAttempts: healthAttempts))
        \(DeploymentScriptFragments.engineRunScript())
        \(DeploymentScriptFragments.cpampRunScript())
        \(DeploymentScriptFragments.gatewayRunScript())
        \(DeploymentScriptFragments.archivePathCheck())
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
        # Every native upgrade ends in the gateway topology; a legacy 0.1.x deployment is
        # migrated (nativeTopologyStep).

        BACKUP_NAME="upgrade-$(date -u '+%Y%m%d-%H%M%S')"
        if [ -e "$ROOT/backups/$BACKUP_NAME" ]; then BACKUP_NAME="$BACKUP_NAME-$$"; fi
        BACKUP_ROOT="$ROOT/backups/$BACKUP_NAME"
        TEMP_ROOT="$ROOT/.oases-cpa-upgrade-$BACKUP_NAME"
        BACKUP_READY=0

        # A backup that did not finish is moved to backups/incomplete-* (never deleted), so a
        # later rollback cannot take it for the newest backup.
        oases_set_aside_partial_backup() {
          local target
          [ -d "$BACKUP_ROOT" ] || return 0
          target="$(oases_after_path "$ROOT/backups/incomplete-${BACKUP_NAME#upgrade-}")"
          if mv "$BACKUP_ROOT" "$target"; then
            printf '未完成的备份已移到 backups/%s。\\n' "$(basename "$target")" >&2
          else
            printf '%s\\n' '未完成的备份未能移走；它缺少完成标记，回滚不会使用它。' >&2
          fi
        }

        # Every failure leaves two machine-readable stderr lines for the app (mapped to a
        # localized message): OASES_UPGRADE_FAILURE stage=<phase> status=<exit> and
        # OASES_UPGRADE_OUTCOME changes=<unchanged|restored|restore_incomplete>
        # running=<yes|no|stopped>, where running=yes means the previous version passed its
        # health checks again.
        upgrade_exit() {
          local status="$?" changes="unchanged" running="no"
          trap - EXIT
          set +e
          if [ "$status" -ne 0 ]; then
            printf 'OASES_UPGRADE_FAILURE stage=%s status=%s\\n' "$UPGRADE_STAGE" "$status" >&2
          fi
          if [ "$status" -eq 28 ] && [ "$BACKUP_READY" -eq 0 ]; then
            # Refused after the stop (oases_refuse_if_still_running): nothing was changed or
            # backed up; a process without a pid file still runs, so nothing is started next to
            # it either. (28 is also curl's timeout code: once the backup is ready it is handled
            # like every other failure below.)
            oases_set_aside_partial_backup
            printf 'OASES_UPGRADE_OUTCOME changes=unchanged running=stopped\\n' >&2
            exit "$status"
          fi
          if [ "$status" -ne 0 ]; then
            oases_stop_all >/dev/null 2>&1
            if [ "$BACKUP_READY" -eq 1 ]; then
              printf '升级失败（退出码 %s），正在恢复升级前的版本。\\n' "$status" >&2
              if oases_restore_backup "$BACKUP_ROOT"; then
                changes="restored"
              else
                changes="restore_incomplete"
                printf '%s\\n' '自动恢复不完整，请使用回滚并查看 backups 目录。' >&2
              fi
            else
              printf '升级在备份完成前失败（退出码 %s），没有做任何改动，正在重新启动服务。\\n' "$status" >&2
              oases_set_aside_partial_backup
            fi
            oases_start_all >/dev/null 2>&1
            if oases_wait_services "$PREVIOUS_TOPOLOGY" "$INSTALLED_GATEWAY" >/dev/null 2>&1; then running="yes"; fi
            printf 'OASES_UPGRADE_OUTCOME changes=%s running=%s\\n' "$changes" "$running" >&2
          fi
          rm -rf "$TEMP_ROOT" >/dev/null 2>&1
          exit "$status"
        }
        trap upgrade_exit EXIT

        # oases_port_in_use <port>: something accepts connections on 127.0.0.1:<port> (bash's
        # /dev/tcp; where that is unavailable the check passes and a conflict shows up as a
        # failed start instead).
        oases_port_in_use() {
          (exec 9<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1
        }
        # After the stop every port of the gateway topology must be free: a port held by another
        # program would only fail later, after the old version was replaced. Exit 29 before the
        # backup; the previous version is started again.
        oases_require_free_ports() {
          local port
          for port in "$GATEWAY_API_PORT" "$GATEWAY_ADMIN_PORT" "$ENGINE_PORT" "$CPAMP_PORT"; do
            if oases_port_in_use "$port"; then
              printf 'OASES_UPGRADE_PORT_BUSY port=%s\\n' "$port" >&2
              printf '端口 %s 已被其他程序占用，升级需要它；没有做任何改动。\\n' "$port" >&2
              exit 29
            fi
          done
        }

        # --- Stop all three processes (gateway first, up to 30 s); nothing of the deployment
        # may still run, pid file or not (exit 28 before any backup). ---
        # The pid files as they were (the stop removes them), for the backup's record.
        OASES_PID_SNAPSHOT=""
        for name in $OASES_MANAGED_PID_FILES; do
          if [ -f "$ROOT/$name" ] && [ ! -L "$ROOT/$name" ]; then
            OASES_PID_SNAPSHOT="$OASES_PID_SNAPSHOT $name=$(head -n 1 "$ROOT/$name" 2>/dev/null | tr -cd '0-9')"
          fi
        done
        UPGRADE_STAGE="stop"
        oases_stop_all
        oases_refuse_if_still_running
        UPGRADE_STAGE="ports"
        oases_require_free_ports

        # --- Backup (before anything changes; gateway-data, cpamp/data and secrets while every
        # process is stopped, so the SQLite database and its -wal/-shm files are consistent). ---
        UPGRADE_STAGE="backup"
        mkdir -p "$ROOT/backups"
        mkdir -m 700 "$BACKUP_ROOT"
        : > "$BACKUP_ROOT/backup-started"
        mkdir -p "$BACKUP_ROOT/cli-proxy-api-runtime" "$BACKUP_ROOT/cpamp-runtime" "$TEMP_ROOT"
        if [ -f "$ROOT/cli-proxy-api/run.sh" ]; then cp -p "$ROOT/cli-proxy-api/run.sh" "$BACKUP_ROOT/cli-proxy-api-run.sh"; fi
        if [ -f "$ROOT/cpamp/run.sh" ]; then cp -p "$ROOT/cpamp/run.sh" "$BACKUP_ROOT/cpamp-run.sh"; fi
        if [ -f "$ROOT/cli-proxy-api/config.yaml" ]; then cp -p "$ROOT/cli-proxy-api/config.yaml" "$BACKUP_ROOT/cli-proxy-api-config.yaml"; fi
        if [ -f "$ROOT/cpamp/config.json" ]; then cp -p "$ROOT/cpamp/config.json" "$BACKUP_ROOT/cpamp-config.json"; fi
        if [ -f "$ROOT/.oases-cpa-versions" ]; then cp -p "$ROOT/.oases-cpa-versions" "$BACKUP_ROOT/versions.json"; else : > "$BACKUP_ROOT/versions.absent"; fi
        if [ -f "$ROOT/gateway/run.sh" ]; then cp -p "$ROOT/gateway/run.sh" "$BACKUP_ROOT/gateway-run.sh"; fi
        if [ -L "$ROOT/gateway/current" ]; then readlink "$ROOT/gateway/current" > "$BACKUP_ROOT/gateway-current"; fi
        if [ -L "$ROOT/node/current" ]; then readlink "$ROOT/node/current" > "$BACKUP_ROOT/node-current"; fi
        if [ -d "$ROOT/gateway-data" ] && [ ! -L "$ROOT/gateway-data" ]; then
          cp -Rp "$ROOT/gateway-data" "$BACKUP_ROOT/gateway-data"
          : > "$BACKUP_ROOT/gateway-data.saved"
        fi
        # Data that cannot be regenerated: CPA Manager Plus usage.sqlite (+ -wal/-shm), data.key
        # and usage-imports (a newer CPA Manager Plus migrates the schema forward, an older one
        # cannot read it back), the keys, and the root's markers and pid files.
        if [ -d "$ROOT/cpamp/data" ] && [ ! -L "$ROOT/cpamp/data" ]; then
          cp -Rp "$ROOT/cpamp/data" "$BACKUP_ROOT/cpamp-data"
          : > "$BACKUP_ROOT/cpamp-data.saved"
        fi
        if [ -d "$ROOT/secrets" ] && [ ! -L "$ROOT/secrets" ]; then
          cp -Rp "$ROOT/secrets" "$BACKUP_ROOT/secrets"
          : > "$BACKUP_ROOT/secrets.saved"
        fi
        mkdir -m 700 "$BACKUP_ROOT/root-files"
        for name in .oases-cpa-installed .oases-cpa-managed; do
          if [ -f "$ROOT/$name" ] && [ ! -L "$ROOT/$name" ]; then cp -p "$ROOT/$name" "$BACKUP_ROOT/root-files/$name"; fi
        done
        for entry in $OASES_PID_SNAPSHOT; do
          printf '%s\\n' "${entry#*=}" > "$BACKUP_ROOT/root-files/${entry%%=*}"
        done
        if [ ! -e "$ROOT/.oases-cpa-managed" ] && [ ! -L "$ROOT/.oases-cpa-managed" ]; then : > "$BACKUP_ROOT/root-files/managed-marker.absent"; fi
        # Written last: a rollback only uses a backup this app started when this marker exists.
        : > "$BACKUP_ROOT/backup-complete"
        BACKUP_READY=1

        # --- Engine (CLIProxyAPI). ---
        UPGRADE_STAGE="engine"
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
        UPGRADE_STAGE="cpamp"
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

        UPGRADE_STAGE="cpamp-config"
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
        UPGRADE_STAGE="start"
        oases_start_all
        UPGRADE_STAGE="health"
        oases_wait_services gateway "$GATEWAY_VERSION" || exit 26
        UPGRADE_STAGE="finalize"
        oases_write_versions "$ROOT" "$CLI_VERSION_TAG" "$CPAMP_VERSION_TAG" "$NODE_VERSION_TAG" "$GATEWAY_VERSION"

        # --- Every health check passed: a root with the legacy install marker was created by
        # this app, so it gets the installer's ownership marker (stop, cancel and removal
        # require it). Best effort, never overwrites another marker. ---
        oases_write_managed_marker() {
          local marker="$ROOT/.oases-cpa-managed" part="$ROOT/.oases-cpa-managed.part.$$"
          [ -f "$ROOT/.oases-cpa-installed" ] && [ ! -L "$ROOT/.oases-cpa-installed" ] || return 0
          if [ -e "$marker" ] || [ -L "$marker" ]; then
            if [ -f "$marker" ] && [ ! -L "$marker" ] && grep -Fqx 'owned-by=oases-cpa' "$marker"; then return 0; fi
            printf '%s\\n' '目标目录已有另一个 .oases-cpa-managed 标记，已保留原样；停止和删除仍会拒绝这个目录。' >&2
            return 0
          fi
          if printf 'owned-by=oases-cpa\\n' > "$part" && chmod 600 "$part" && mv "$part" "$marker"; then
            return 0
          fi
          rm -f "$part"
          printf '%s\\n' '升级已完成，但未能写入受管标记 .oases-cpa-managed；停止和删除仍会拒绝这个目录。' >&2
          return 0
        }
        oases_write_managed_marker

        # --- Keep the two newest previous versions of Node and the gateway. ---
        PRUNE_ROOT="$ROOT/backups/pruned-$(date -u '+%Y%m%d-%H%M%S')"
        # Best effort: the upgrade has succeeded at this point, so a failed move only logs a
        # line and never triggers the rollback of the EXIT trap.
        oases_prune_old_versions() {
          local dir="$1" current entry count=0
          [ -d "$ROOT/$dir" ] || return 0
          current="$(readlink "$ROOT/$dir/current" 2>/dev/null || true)"
          for entry in $(ls -1t "$ROOT/$dir" 2>/dev/null || true); do
            case "$entry" in current|downloads|run.sh|.*) continue ;; esac
            [ -d "$ROOT/$dir/$entry" ] && [ ! -L "$ROOT/$dir/$entry" ] || continue
            [ "$entry" != "$current" ] || continue
            count=$((count + 1))
            if [ "$count" -gt 2 ]; then
              if ! { mkdir -p "$PRUNE_ROOT/$dir" && mv "$ROOT/$dir/$entry" "$PRUNE_ROOT/$dir/$entry"; }; then
                printf '旧版本 %s/%s 未能移入 backups，已保留原处。\\n' "$dir" "$entry" >&2
              fi
            fi
          done
          return 0
        }
        oases_prune_old_versions node || true
        oases_prune_old_versions gateway || true

        if [ -s "$ROOT/secrets/pack-engine-key" ]; then
          if [ "$SHA256_COMMAND" = "shasum" ]; then
            PACK_ENGINE_KEY_SHA256="$(tr -d '\\n' < "$ROOT/secrets/pack-engine-key" | shasum -a 256 | awk '{print $1}')"
          else
            PACK_ENGINE_KEY_SHA256="$(tr -d '\\n' < "$ROOT/secrets/pack-engine-key" | sha256sum | awk '{print $1}')"
          fi
          printf 'OASES_PACK_ENGINE_KEY_SHA256=%s\\n' "$PACK_ENGINE_KEY_SHA256"
        fi
        printf 'OASES_CPA_BACKUP=%s\\n' "$BACKUP_ROOT"
        printf 'OASES_CPA_TOPOLOGY=%s\\n' gateway
        printf 'OASES_CPA_MAINTENANCE_DETAIL=%s\\n' '已升级 CLIProxyAPI、CPA Manager Plus、Node 与 Oases 网关；配置、认证文件和数据保持不变，升级前的版本与网关数据已备份。'
        """
    }

    /// The topology-specific install step after the engine and CPA Manager Plus: Node, the
    /// gateway package, `gateway/run.sh` (following the new versions), private directories and
    /// the idempotent bootstrap; then, for a legacy 0.1.x deployment, the migration.
    private func nativeTopologyStep() -> String {
        """
        UPGRADE_STAGE="node"
        oases_install_node "$ROOT"
        UPGRADE_STAGE="gateway"
        oases_install_gateway "$ROOT"
        oases_write_gateway_run "$ROOT" "$CLI_VERSION_TAG" "$CPAMP_VERSION_TAG" "$GATEWAY_API_PORT" "$GATEWAY_ADMIN_PORT" "$ENGINE_PORT"
        UPGRADE_STAGE="bootstrap"
        oases_secure_private_directories "$ROOT"
        oases_run_bootstrap "$ROOT"
        if [ "$PREVIOUS_TOPOLOGY" = legacy ]; then
          \(legacyMigrationStep())
        fi
        """
    }

    /// The 0.1.x layout to the gateway topology: the engine moves from 8317 to the engine port
    /// (only the line `port: 8317` changes; nothing to change fails closed with 27, L6), gets
    /// `response-compression` like the fresh install, starts alone, and the gateway's internal
    /// key is added to its top-level `api-keys` through the management API (GET, PUT with the
    /// user's keys kept, GET again). The keys reach the inline Node script only through its
    /// environment (`OASES_MANAGEMENT_KEY`, `PACK_ENGINE_KEY`); its text holds none.
    private func legacyMigrationStep() -> String {
        """
        UPGRADE_STAGE="migration-config"
          ENGINE_CONFIG="$ROOT/cli-proxy-api/config.yaml"
          [ -f "$ENGINE_CONFIG" ] || { printf '%s\\n' '旧部署缺少引擎配置 config.yaml，无法迁移。' >&2; exit 27; }
          # Behind the gateway the engine must stay on loopback (18316 would be reachable from
          # the network otherwise): only a loopback host is migrated.
          ENGINE_HOST="$(sed -n 's/^host:[[:space:]]*//p' "$ENGINE_CONFIG" | head -n 1 | sed -e 's/[[:space:]]*$//' -e 's/^"\\(.*\\)"$/\\1/' -e "s/^'\\(.*\\)'$/\\1/")"
          case "$ENGINE_HOST" in
            127.0.0.1|localhost) ;;
            # ::1 is loopback too, but the gateway and CPA Manager Plus dial 127.0.0.1 only.
            *) printf '%s\\n' '引擎配置的 host 不是本机回环地址（127.0.0.1，网关只经 IPv4 回环访问引擎）；为避免把引擎端口暴露到网络或迁移后无法连接，已停止迁移并恢复原版本。' >&2; exit 27 ;;
          esac
          sed "s/^port: $LEGACY_ENGINE_PORT$/port: $ENGINE_PORT/" "$ENGINE_CONFIG" > "$ENGINE_CONFIG.migrate.$$"
          if cmp -s "$ENGINE_CONFIG" "$ENGINE_CONFIG.migrate.$$"; then
            rm -f "$ENGINE_CONFIG.migrate.$$"
            printf '引擎配置中没有 port: %s 这一行，无法安全迁移端口，已停止并恢复原版本。\\n' "$LEGACY_ENGINE_PORT" >&2
            exit 27
          fi
          if ! grep -q '^response-compression:' "$ENGINE_CONFIG.migrate.$$"; then
            printf '\\nresponse-compression:\\n  enabled: false\\n' >> "$ENGINE_CONFIG.migrate.$$"
          fi
          chmod 600 "$ENGINE_CONFIG.migrate.$$"
          mv "$ENGINE_CONFIG.migrate.$$" "$ENGINE_CONFIG"

          UPGRADE_STAGE="migration-engine"
          nohup "$ROOT/cli-proxy-api/run.sh" >> "$ROOT/logs/cli-proxy-api.log" 2>&1 &
          printf '%s\\n' "$!" > "$ROOT/cli-proxy-api.pid"
          MIGRATION_ENGINE_READY=0
          for _ in $(seq 1 "$HEALTH_ATTEMPTS"); do
            if oases_mgmt_curl "$ROOT/secrets/cpa-management-key" -fsS -o /dev/null "http://127.0.0.1:$ENGINE_PORT/v0/management/config" >/dev/null 2>&1; then
              MIGRATION_ENGINE_READY=1
              break
            fi
            sleep 1
          done
          [ "$MIGRATION_ENGINE_READY" -eq 1 ] || { printf '%s\\n' '迁移后的引擎没有在新端口上就绪。' >&2; exit 27; }
          UPGRADE_STAGE="migration-keys"

          # The script has no single quote (checked by a test), so it fits a single-quoted word.
          OASES_API_KEYS_SCRIPT='\(Self.apiKeysMigrationScript)'
          MIGRATION_MANAGEMENT_KEY=""
          MIGRATION_PACK_KEY=""
          IFS= read -r MIGRATION_MANAGEMENT_KEY < "$ROOT/secrets/cpa-management-key" || true
          IFS= read -r MIGRATION_PACK_KEY < "$ROOT/secrets/pack-engine-key" || true
          [ -n "$MIGRATION_MANAGEMENT_KEY" ] && [ -n "$MIGRATION_PACK_KEY" ] || { printf '%s\\n' '迁移缺少管理密钥或内部引擎 Key。' >&2; exit 27; }
          if ! OASES_ENGINE_URL="http://127.0.0.1:$ENGINE_PORT" OASES_MANAGEMENT_KEY="$MIGRATION_MANAGEMENT_KEY" PACK_ENGINE_KEY="$MIGRATION_PACK_KEY" \\
               "$NODE_BIN" -e "$OASES_API_KEYS_SCRIPT" 3>&- 4>&-; then
            MIGRATION_MANAGEMENT_KEY=""
            MIGRATION_PACK_KEY=""
            printf '%s\\n' '无法把内部引擎 Key 加入引擎的 api-keys，已停止并恢复原版本。' >&2
            exit 27
          fi
          MIGRATION_MANAGEMENT_KEY=""
          MIGRATION_PACK_KEY=""
        """
    }

    /// Node 24 (built-in `fetch`): reads `OASES_ENGINE_URL`, `OASES_MANAGEMENT_KEY` and
    /// `PACK_ENGINE_KEY` from its environment, keeps every existing client key, adds the
    /// internal key once, and verifies the result. Exit 27 on any failure; messages never
    /// contain a key. The engine's list API: GET `{"api-keys":[…]}`, PUT a JSON array.
    static let apiKeysMigrationScript = """
    const base = process.env.OASES_ENGINE_URL;
    const managementKey = process.env.OASES_MANAGEMENT_KEY;
    const packKey = process.env.PACK_ENGINE_KEY;
    const url = base + "/v0/management/api-keys";
    const headers = { Authorization: "Bearer " + managementKey };
    async function list() {
      const response = await fetch(url, { headers });
      if (!response.ok) throw new Error("GET api-keys answered " + response.status);
      const body = await response.json();
      const keys = body["api-keys"];
      if (!Array.isArray(keys) || !keys.every((key) => typeof key === "string")) throw new Error("unexpected api-keys shape");
      return keys;
    }
    (async () => {
      if (!base || !managementKey || !packKey) throw new Error("missing environment");
      const before = await list();
      if (!before.includes(packKey)) {
        const response = await fetch(url, {
          method: "PUT",
          headers: { ...headers, "Content-Type": "application/json" },
          body: JSON.stringify([...before, packKey]),
        });
        if (!response.ok) throw new Error("PUT api-keys answered " + response.status);
      }
      const after = await list();
      if (!after.includes(packKey) || !before.every((key) => after.includes(key))) throw new Error("api-keys check failed");
      console.log(JSON.stringify({ ok: true, keys: after.length }));
    })().catch((error) => {
      console.error("api-keys migration failed: " + (error && error.message ? error.message : "unknown error"));
      process.exit(27);
    });
    """

    // MARK: - Native rollback

    private func nativeRollbackScript(installDirectory: String, ports: DeploymentScriptPorts, healthAttempts: Int) -> String {
        """
        set -euo pipefail
        umask 077
        \(rootPrelude(installDirectory: installDirectory))
        \(nativeMaintenanceFunctions(installDirectory: installDirectory, ports: ports, healthAttempts: healthAttempts))

        \(Self.latestBackupSelection())
        [ -n "$BACKUP_ROOT" ] || { printf '%s\\n' '目标目录中还没有可回滚的升级备份。' >&2; exit 19; }
        [ "$BACKUP_INCOMPLETE" -eq 0 ] || { printf '%s\\n' '最新的升级备份不完整（备份过程被中断），已停止回滚，没有改动任何内容；请查看 backups 目录。' >&2; exit 19; }
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
        oases_refuse_if_still_running
        oases_restore_backup "$BACKUP_ROOT" || { printf '%s\\n' '回滚未能完整恢复备份，服务保持停止；请查看 backups 目录。' >&2; exit 19; }
        oases_start_all
        oases_wait_services "$ROLLBACK_TOPOLOGY" "$ROLLBACK_GATEWAY_VERSION" || exit 26
        printf 'OASES_CPA_BACKUP=%s\\n' "$BACKUP_ROOT"
        printf 'OASES_CPA_TOPOLOGY=%s\\n' "$ROLLBACK_TOPOLOGY"
        printf 'OASES_CPA_MAINTENANCE_DETAIL=%s\\n' '已恢复上一版原生运行时、网关数据与密钥；CPA Manager Plus 版本变化时也恢复了它的数据（较新的数据移入备份）；认证文件保持不变。'
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
        BACKUP_READY=0
        # Like the native upgrade: a backup that did not finish is moved to backups/incomplete-*
        # (never deleted), so a rollback still finds the newest COMPLETE backup.
        oases_docker_backup_exit() {
          local status="$?" target
          trap - EXIT
          if [ "$status" -ne 0 ] && [ "$BACKUP_READY" -eq 0 ] && [ -d "$BACKUP_ROOT" ]; then
            target="$ROOT/backups/incomplete-${BACKUP_NAME#upgrade-}"
            if [ -e "$target" ] || [ -L "$target" ]; then target="$target-$(date -u '+%Y%m%dT%H%M%SZ')-$$"; fi
            if mv "$BACKUP_ROOT" "$target"; then
              printf '升级在备份完成前失败；未完成的备份已移到 backups/%s，服务没有改动。\\n' "$(basename "$target")" >&2
            else
              printf '%s\\n' '升级在备份完成前失败；未完成的备份未能移走，它缺少完成标记，回滚不会使用它。' >&2
            fi
          fi
          exit "$status"
        }
        trap oases_docker_backup_exit EXIT
        mkdir -p "$BACKUP_ROOT" "$ROOT/logs"
        : > "$BACKUP_ROOT/backup-started"
        cp -p "$ROOT/compose.yaml" "$BACKUP_ROOT/compose.yaml"
        [ ! -e "$ROOT/.env" ] || cp -p "$ROOT/.env" "$BACKUP_ROOT/.env"
        if [ -f "$ROOT/.oases-cpa-versions" ]; then cp -p "$ROOT/.oases-cpa-versions" "$BACKUP_ROOT/versions.json"; else : > "$BACKUP_ROOT/versions.absent"; fi
        : > "$BACKUP_ROOT/backup-complete"
        BACKUP_READY=1
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
        \(Self.latestBackupSelection())
        [ -n "$BACKUP_ROOT" ] || { printf '%s\\n' '目标目录中还没有可回滚的升级备份。' >&2; exit 19; }
        [ "$BACKUP_INCOMPLETE" -eq 0 ] || { printf '%s\\n' '最新的升级备份不完整（备份过程被中断），已停止回滚，没有改动任何内容；请查看 backups 目录。' >&2; exit 19; }
        [ -f "$BACKUP_ROOT/compose.yaml" ] || { printf '%s\\n' '升级备份缺少 Compose 文件。' >&2; exit 19; }
        # The current compose.yaml and .env (edited since the upgrade, perhaps) are moved into
        # the backup (…after-upgrade) before the backup's copies go back; never overwritten.
        oases_keep_current() {
          local saved="$1" current="$2" kept="$3"
          [ -e "$current" ] || return 0
          ! cmp -s "$saved" "$current" || return 0
          if [ -e "$kept" ] || [ -L "$kept" ]; then kept="$kept-$(date -u '+%Y%m%dT%H%M%SZ')-$$"; fi
          mv "$current" "$kept"
        }
        oases_keep_current "$BACKUP_ROOT/compose.yaml" "$ROOT/compose.yaml" "$BACKUP_ROOT/compose.yaml.after-upgrade"
        cp -p "$BACKUP_ROOT/compose.yaml" "$ROOT/compose.yaml"
        if [ -f "$BACKUP_ROOT/.env" ]; then
          oases_keep_current "$BACKUP_ROOT/.env" "$ROOT/.env" "$BACKUP_ROOT/.env.after-upgrade"
          cp -p "$BACKUP_ROOT/.env" "$ROOT/.env"
        fi
        if [ -f "$BACKUP_ROOT/versions.json" ]; then
          cp -p "$BACKUP_ROOT/versions.json" "$ROOT/.oases-cpa-versions"
        elif [ -f "$BACKUP_ROOT/versions.absent" ] && [ -f "$ROOT/.oases-cpa-versions" ]; then
          # Before that upgrade there was no versions file: the one it wrote goes into the backup.
          VERSIONS_AFTER="$BACKUP_ROOT/versions-after-upgrade.json"
          if [ -e "$VERSIONS_AFTER" ]; then VERSIONS_AFTER="$VERSIONS_AFTER-$(date -u '+%Y%m%dT%H%M%SZ')-$$"; fi
          mv "$ROOT/.oases-cpa-versions" "$VERSIONS_AFTER"
        fi
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

/// A failed native upgrade as the script reports it on stderr: `OASES_UPGRADE_FAILURE
/// stage=<phase> status=<exit>`, `OASES_UPGRADE_OUTCOME changes=<…> running=<…>` and, for a
/// busy port, `OASES_UPGRADE_PORT_BUSY port=<n>`. Only known values are accepted; the message
/// is localized and never repeats raw stderr (paths, package names).
struct UpgradeFailure: Equatable, Sendable {
    enum Changes: String, Sendable {
        case unchanged
        case restored
        case restoreIncomplete = "restore_incomplete"
    }

    enum Running: String, Sendable {
        case yes
        case no
        case stopped
    }

    static let stages: Set<String> = [
        "prepare", "stop", "ports", "backup", "engine", "cpamp", "node", "gateway", "bootstrap",
        "migration-config", "migration-engine", "migration-keys", "cpamp-config", "start", "health", "finalize",
    ]

    let stage: String
    let status: Int32
    let changes: Changes
    let running: Running
    let busyPort: Int?

    init?(standardError: String) {
        func fields(_ prefix: String) -> [String: String]? {
            guard let line = standardError.split(separator: "\n").last(where: { $0.hasPrefix(prefix + " ") }) else { return nil }
            var values: [String: String] = [:]
            for part in line.split(separator: " ").dropFirst() {
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 { values[pair[0]] = pair[1] }
            }
            return values
        }
        guard let failure = fields("OASES_UPGRADE_FAILURE"),
              let stage = failure["stage"], Self.stages.contains(stage),
              let status = failure["status"].flatMap({ Int32($0) }), (1...255).contains(status),
              let outcome = fields("OASES_UPGRADE_OUTCOME"),
              let changes = outcome["changes"].flatMap(Changes.init(rawValue:)),
              let running = outcome["running"].flatMap(Running.init(rawValue:)) else { return nil }
        self.stage = stage
        self.status = status
        self.changes = changes
        self.running = running
        self.busyPort = fields("OASES_UPGRADE_PORT_BUSY")?["port"].flatMap { Int($0) }.flatMap { (1...65535).contains($0) ? $0 : nil }
    }

    private static func componentName(_ stage: String) -> String {
        switch stage {
        case "engine": "CLIProxyAPI"
        case "cpamp": "CPA Manager Plus"
        case "node": "Node"
        default: OasesLocalization.localized("Oases 网关")
        }
    }

    /// Why the upgrade stopped.
    func reason(language: AppLanguage? = nil) -> String {
        switch (stage, status) {
        case ("ports", _):
            return OasesLocalization.localizedFormat("端口 %@ 已被其他程序占用，升级需要这个端口。", language: language, busyPort.map(String.init) ?? "?")
        case ("stop", 28):
            return OasesLocalization.localized("停止后目标目录中仍有 Oases CPA 进程在运行（没有可信的 PID 文件）。", language: language)
        case ("backup", _):
            return OasesLocalization.localized("升级前的备份没有完成（磁盘空间或权限不足）。", language: language)
        case ("engine", 18), ("cpamp", 18), ("node", 18):
            return OasesLocalization.localizedFormat("下载 %@ 失败（网络不通或发布站点不可用）。", language: language, Self.componentName(stage))
        case ("engine", _), ("cpamp", _), ("node", _):
            return OasesLocalization.localizedFormat("%@ 的下载包没有通过固定 SHA-256 校验或包结构检查。", language: language, Self.componentName(stage))
        case ("gateway", _):
            return OasesLocalization.localized("应用内的 Oases 网关包没有通过校验。", language: language)
        case ("bootstrap", _):
            return OasesLocalization.localized("Oases 网关初始化失败（目录权限或密钥文件）。", language: language)
        case ("migration-config", _):
            return OasesLocalization.localized("旧部署的引擎配置无法安全迁移（缺少 config.yaml 或端口行，或 host 不是 127.0.0.1）。", language: language)
        case ("migration-engine", _):
            return OasesLocalization.localized("新版 CLIProxyAPI 没有在新端口上启动。", language: language)
        case ("migration-keys", _):
            return OasesLocalization.localized("无法把 Oases 网关的内部 Key 加入引擎的 api-keys。", language: language)
        case ("start", _), ("health", _):
            return OasesLocalization.localized("升级后的服务没有在规定时间内通过健康检查。", language: language)
        default:
            return OasesLocalization.localizedFormat("升级在“%@”阶段失败（退出码 %@）。", language: language, stage, String(status))
        }
    }

    /// What the target looks like now.
    func outcome(language: AppLanguage? = nil) -> String {
        switch (changes, running) {
        case (.restoreIncomplete, _):
            return OasesLocalization.localized("自动恢复不完整；请使用回滚，并查看目标目录中的 backups。", language: language)
        case (_, .stopped):
            return OasesLocalization.localized("没有做任何改动，服务保持停止；请先结束这些进程再重试。", language: language)
        case (.unchanged, .yes):
            return OasesLocalization.localized("没有做任何改动，原来的服务已重新启动并通过健康检查。", language: language)
        case (.restored, .yes):
            return OasesLocalization.localized("已自动恢复升级前的版本，原来的服务已重新启动并通过健康检查。", language: language)
        case (.unchanged, .no):
            return OasesLocalization.localized("没有做任何改动，但原来的服务重新启动后没有通过健康检查；请查看目标日志，或稍后重试。", language: language)
        case (.restored, .no):
            return OasesLocalization.localized("已恢复升级前的文件，但原来的服务没有通过健康检查；请查看目标日志，或稍后重试。", language: language)
        }
    }

    func message(language: AppLanguage? = nil) -> String {
        OasesLocalization.localizedFormat("升级失败：%@%@", language: language, reason(language: language), outcome(language: language))
    }
}

/// The guard's stderr line `OASES_DOWNGRADE_REFUSED component=<c> installed=<v> target=<v>`;
/// only known components and version-shaped values are accepted.
struct DowngradeRefusal: Equatable, Sendable {
    let component: String
    let installed: String
    let target: String

    init(component: String, installed: String, target: String) {
        self.component = component
        self.installed = installed
        self.target = target
    }

    /// The refusal in `language` (default: the current one), built when it is shown, so it
    /// follows a language switch.
    func message(language: AppLanguage? = nil) -> String {
        OasesLocalization.localizedFormat(
            "目标上的 %@ 是 %@，比本应用要安装的 %@ 新；已拒绝降级，没有停止或修改任何内容。请先更新 Oases CPA 应用。",
            language: language,
            DeploymentExecutionError.componentName(component, language: language), installed, target
        )
    }

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
