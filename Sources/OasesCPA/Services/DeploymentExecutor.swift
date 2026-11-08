import Foundation

struct DeploymentExecutionRequest: Sendable {
    let target: DeploymentTargetKind
    let method: DeploymentMethod
    let host: String
    let user: String
    let port: String
    let privateKeyPath: String
    let installDirectory: String
}

struct DeploymentExecutionResult: Sendable {
    let cpaManagementKey: String
    let cpampAdminKey: String
}

enum DeploymentExecutionError: LocalizedError {
    case invalidRemotePort
    case invalidRemoteHost
    case missingPrivateKey
    case invalidInstallDirectory
    case commandFailed(String)
    case missingResult
    /// The build carries only the placeholder gateway (`GatewayBundle.placeholderVersion`).
    case placeholderGateway
    /// The gateway package is missing from the app or its SHA-256 differs from the pinned one.
    case gatewayPackageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidRemotePort:
            OasesLocalization.localized("SSH 端口必须是 1-65535 之间的数字。")
        case .invalidRemoteHost:
            OasesLocalization.localized("远程主机名不能包含空格或换行。")
        case .missingPrivateKey:
            OasesLocalization.localized("远程 SSH 模式需要选择私钥文件。")
        case .invalidInstallDirectory:
            OasesLocalization.localized("安装目录不能为空，也不能直接使用文件系统根目录。")
        case .commandFailed(let message):
            message
        case .missingResult:
            OasesLocalization.localized("部署已结束，但没有收到管理凭据结果。请检查目标日志。")
        case .placeholderGateway:
            OasesLocalization.localized("此构建只含占位网关，不能部署；请先放入正式网关包")
        case .gatewayPackageUnavailable:
            OasesLocalization.localized("应用内的网关包缺失或校验失败，已停止部署。请重新安装应用。")
        }
    }
}

struct DeploymentExecutor {
    private static let cpampInstallerURL = "https://raw.githubusercontent.com/seakee/CPA-Manager-Plus/931d771344fdd5d95db5ae0adb87259eca133adc/bin/install-cpamp.sh"
    private static let cpampInstallerSHA256 = "074153b81eebbcb6a9937323a804943508fd99463b746464bd079d8dbb13b289"
    private static let cpampInstallerMaxBytes = 131_072

    func execute(
        request: DeploymentExecutionRequest,
        controlToken: String = UUID().uuidString.lowercased()
    ) async throws -> DeploymentExecutionResult {
        try validate(request)
        try validateControlToken(controlToken)

        let script = request.method == .docker
            ? dockerScript(installDirectory: request.installDirectory, controlToken: controlToken)
            : nativeScript(installDirectory: request.installDirectory, controlToken: controlToken)

        let output: String
        do {
            switch request.target {
            case .local:
                output = try await BoundedProcessRunner.run(
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
                output = try await BoundedProcessRunner.run(
                    executable: "/usr/bin/ssh",
                    arguments: sshArguments + [
                        "\(request.user)@\(request.host)",
                        "bash -s"
                    ],
                    standardInput: script,
                    timeout: 45 * 60
                ).standardOutput
            }
        } catch let error as BoundedProcessError {
            throw DeploymentExecutionError.commandFailed(
                BoundedProcessRunner.userFacingMessage(
                    for: error,
                    fallback: OasesLocalization.localized("目标终端部署命令失败。")
                )
            )
        }

        return try parseResult(output)
    }

    func scriptForVerification(
        method: DeploymentMethod,
        installDirectory: String,
        controlToken: String = "verification-token",
        dockerInstallerURL: String? = nil,
        dockerInstallerSHA256: String? = nil,
        dockerInstallerMaxBytes: Int? = nil
    ) -> String {
        method == .docker
            ? dockerScript(
                installDirectory: installDirectory,
                controlToken: controlToken,
                installerURL: dockerInstallerURL ?? Self.cpampInstallerURL,
                installerSHA256: dockerInstallerSHA256 ?? Self.cpampInstallerSHA256,
                installerMaxBytes: dockerInstallerMaxBytes ?? Self.cpampInstallerMaxBytes
            )
            : nativeScript(installDirectory: installDirectory, controlToken: controlToken)
    }

    private func validateControlToken(_ token: String) throws {
        guard !token.isEmpty,
              token.count <= 128,
              token.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57) ||
                  (scalar.value >= 65 && scalar.value <= 90) ||
                  (scalar.value >= 97 && scalar.value <= 122) ||
                  scalar.value == 45
              })
        else {
            throw DeploymentExecutionError.commandFailed(
                OasesLocalization.localized("部署控制令牌无效，已停止执行。")
            )
        }
    }

    private func validate(_ request: DeploymentExecutionRequest) throws {
        let trimmedInstallDirectory = request.installDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstallDirectory.isEmpty, trimmedInstallDirectory != "/" else {
            throw DeploymentExecutionError.invalidInstallDirectory
        }
        guard !request.installDirectory.contains("\n"), !request.installDirectory.contains("\r") else {
            throw DeploymentExecutionError.invalidInstallDirectory
        }

        guard request.target == .local || !request.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeploymentExecutionError.invalidRemoteHost
        }

        guard request.target == .local || !request.host.contains(where: { $0.isWhitespace || $0 == "\n" || $0 == "\r" }) else {
            throw DeploymentExecutionError.invalidRemoteHost
        }

        if request.target == .ssh {
            guard let port = Int(request.port), (1...65_535).contains(port) else {
                throw DeploymentExecutionError.invalidRemotePort
            }
            guard !request.privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DeploymentExecutionError.missingPrivateKey
            }
        }
    }

    private func parseResult(_ output: String) throws -> DeploymentExecutionResult {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard
            let cpaManagementKey = values["OASES_CPA_MANAGEMENT_KEY"],
            !cpaManagementKey.isEmpty,
            let cpampAdminKey = values["OASES_CPAMP_ADMIN_KEY"],
            !cpampAdminKey.isEmpty
        else {
            throw DeploymentExecutionError.missingResult
        }

        return DeploymentExecutionResult(
            cpaManagementKey: cpaManagementKey,
            cpampAdminKey: cpampAdminKey
        )
    }

    private func nativeScript(installDirectory: String, controlToken: String) -> String {
        let root = shellQuote(installDirectory)
        let token = shellQuote(controlToken)

        return """
        set -euo pipefail

        INSTALL_ROOT=\(root)
        CONTROL_TOKEN=\(token)
        case "$INSTALL_ROOT" in
          "~") INSTALL_ROOT="$HOME" ;;
          "~/"*) INSTALL_ROOT="$HOME/${INSTALL_ROOT#\\~/}" ;;
        esac
        if [ "$INSTALL_ROOT" != "/" ]; then
          INSTALL_ROOT="${INSTALL_ROOT%/}"
        fi

        mkdir -p "$INSTALL_ROOT"
        LOCK_DIR="$INSTALL_ROOT/.oases-cpa-deployment-lock"
        release_deployment_lock() {
          rm -f "$LOCK_DIR/pid" >/dev/null 2>&1 || true
          rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
        }
        if [ -d "$LOCK_DIR" ]; then
          LOCK_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
          if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" >/dev/null 2>&1; then
            printf '%s\n' '另一个 Oases CPA 部署正在进行，请等待完成后再试。' >&2
            exit 11
          fi
          release_deployment_lock
        fi
        mkdir "$LOCK_DIR" 2>/dev/null || {
          printf '%s\n' '无法获取目标目录的部署锁，请稍后重试。' >&2
          exit 11
        }
        printf '%s\n' "$$" > "$LOCK_DIR/pid"

        MANAGED_ROOT_MARKER="$INSTALL_ROOT/.oases-cpa-managed"

        if [ -e "$INSTALL_ROOT/.oases-cpa-installed" ]; then
          release_deployment_lock
          printf '%s\n' '检测到目标目录中已有成功部署，已阻止重复安装。请连接对应的已保存目标；如需新建，请选择空目录。' >&2
          exit 12
        fi

        RECOVERY_NOTE=""
        LEGACY_OWNERSHIP_MARKER_PRESENT=0
        if [ -e "$INSTALL_ROOT/.oases-cpa-installing" ] || [ -e "$INSTALL_ROOT/.oases-cpa-failed" ]; then
          LEGACY_OWNERSHIP_MARKER_PRESENT=1
        fi
        if [ -e "$INSTALL_ROOT/.oases-cpa-installing" ] || \
           [ -e "$INSTALL_ROOT/.oases-cpa-failed" ] || \
           { [ -e "$MANAGED_ROOT_MARKER" ] && [ ! -e "$INSTALL_ROOT/.oases-cpa-installed" ]; }; then
          AUTO_BACKUP_NAME="auto-recovery-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
          AUTO_BACKUP_ROOT="$INSTALL_ROOT/backups/$AUTO_BACKUP_NAME"
          recover_stale_attempt() {
            managed_process() {
              local pid="$1"
              local expected_root="$2"
              kill -0 "$pid" >/dev/null 2>&1 || return 1
              local command
              command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
              case "$command" in
                *"$expected_root"*) return 0 ;;
                *) return 1 ;;
              esac
            }
            for pid_file in "$INSTALL_ROOT/cli-proxy-api.pid" "$INSTALL_ROOT/cpa-manager-plus.pid"; do
              if [ -f "$pid_file" ]; then
                pid="$(cat "$pid_file" 2>/dev/null || true)"
                case "$pid_file" in
                  *"/cli-proxy-api.pid") expected_root="$INSTALL_ROOT/cli-proxy-api" ;;
                  *) expected_root="$INSTALL_ROOT/cpamp" ;;
                esac
                if [ -n "$pid" ] && managed_process "$pid" "$expected_root"; then
                  kill "$pid" >/dev/null 2>&1 || true
                fi
              fi
            done

            mkdir -p "$AUTO_BACKUP_ROOT" || return 1
            move_recovery_item() {
              local item="$1"
              if [ -e "$INSTALL_ROOT/$item" ]; then
                mv "$INSTALL_ROOT/$item" "$AUTO_BACKUP_ROOT/$item" || return 1
              fi
              return 0
            }
            move_recovery_item "cli-proxy-api" || return 1
            move_recovery_item "cpamp" || return 1
            move_recovery_item "logs" || return 1
            move_recovery_item "secrets" || return 1
            move_recovery_item "cli-proxy-api.pid" || return 1
            move_recovery_item "cpa-manager-plus.pid" || return 1
            move_recovery_item ".oases-cpa-installing" || return 1
            move_recovery_item ".oases-cpa-failed" || return 1
            return 0
          }
          if ! recover_stale_attempt; then
            release_deployment_lock
            printf '%s\n' '上次失败部署无法安全备份，本次重试已停止，原文件保持不变。' >&2
            exit 19
          fi
          RECOVERY_NOTE="已自动备份上次未完成部署到 backups/${AUTO_BACKUP_NAME}，现在重新开始。"
        fi

        if [ ! -e "$MANAGED_ROOT_MARKER" ] && [ "$LEGACY_OWNERSHIP_MARKER_PRESENT" -ne 1 ]; then
          FIRST_UNMANAGED_ENTRY="$(find "$INSTALL_ROOT" -mindepth 1 -maxdepth 1 \
            ! -name '.oases-cpa-deployment-lock' \
            ! -name 'backups' \
            ! -name '.DS_Store' \
            -print -quit)"
          if [ -n "$FIRST_UNMANAGED_ENTRY" ]; then
            release_deployment_lock
            printf '%s\n' '目标目录并非空目录，且没有 Oases CPA 受管标记。为保护已有数据，请换用空目录。' >&2
            exit 12
          fi
        fi
        if [ ! -e "$MANAGED_ROOT_MARKER" ]; then
          printf 'owned-by=oases-cpa\n' > "$MANAGED_ROOT_MARKER"
          chmod 600 "$MANAGED_ROOT_MARKER"
        fi

        mkdir -p "$INSTALL_ROOT/logs" "$INSTALL_ROOT/secrets"
        DEPLOYMENT_LOG="$INSTALL_ROOT/logs/deployment.log"
        exec 3>&1 4>&2
        exec >> "$DEPLOYMENT_LOG" 2>&1
        ATTEMPT_MARKER="$INSTALL_ROOT/.oases-cpa-installing"
        FAILURE_MARKER="$INSTALL_ROOT/.oases-cpa-failed"
        PAUSE_MARKER="$INSTALL_ROOT/.oases-cpa-paused"
        CURRENT_STAGE="prepare"
        set_stage() {
          CURRENT_STAGE="$1"
          local marker_part="${ATTEMPT_MARKER}.part.$$"
          printf 'timestamp=%s\nmethod=native\nstage=%s\npid=%s\ncontrol_token=%s\n' \
            "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$CURRENT_STAGE" "$$" "$CONTROL_TOKEN" > "$marker_part"
          mv "$marker_part" "$ATTEMPT_MARKER"
          printf '[%s] 部署阶段：%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$CURRENT_STAGE"
        }
        deployment_exit_status() {
          local status="$?"
          set +e
          if [ "$status" -eq 0 ]; then
            rm -f "$ATTEMPT_MARKER" "$FAILURE_MARKER" "$PAUSE_MARKER"
          else
            printf 'timestamp=%s\nmethod=native\nstage=%s\nexit_status=%s\n' \
              "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$CURRENT_STAGE" "$status" > "$FAILURE_MARKER"
            printf '[%s] 部署在阶段 %s 失败（退出码 %s）。\n' \
              "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$CURRENT_STAGE" "$status"
            tail -n 120 "$DEPLOYMENT_LOG" >&4 2>/dev/null || true
          fi
          release_deployment_lock
          trap - EXIT
          exit "$status"
        }
        deployment_cancelled() {
          CURRENT_STAGE="cancelled"
          exit 130
        }
        trap deployment_exit_status EXIT
        trap deployment_cancelled TERM INT
        set_stage "prepare"
        printf '\n[%s] Oases CPA 原生部署开始。\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        if [ -n "$RECOVERY_NOTE" ]; then
          printf '%s\n' "$RECOVERY_NOTE"
        fi

        command -v curl >/dev/null 2>&1 || { printf '%s\n' '目标环境缺少 curl。' >&2; exit 13; }
        command -v tar >/dev/null 2>&1 || { printf '%s\n' '目标环境缺少 tar。' >&2; exit 13; }
        command -v openssl >/dev/null 2>&1 || { printf '%s\n' '目标环境缺少 openssl。' >&2; exit 13; }
        if command -v shasum >/dev/null 2>&1; then
          SHA256_COMMAND="shasum"
        elif command -v sha256sum >/dev/null 2>&1; then
          SHA256_COMMAND="sha256sum"
        else
          printf '%s\n' '目标环境缺少 shasum 或 sha256sum。' >&2
          exit 13
        fi

        case "$(uname -s)" in
          Darwin) RELEASE_OS="darwin" ;;
          Linux) RELEASE_OS="linux" ;;
          *) printf '%s\n' '原生部署目前支持 macOS 和 Linux。' >&2; exit 14 ;;
        esac

        case "$(uname -m)" in
          arm64|aarch64) ARCH="arm64" ;;
          x86_64|amd64) ARCH="amd64" ;;
          *) printf '%s\n' '目标架构不在官方原生包支持范围内。' >&2; exit 14 ;;
        esac

        \(DeploymentPinSet.current.nativeSelectionScript())

        umask 077
        MANAGEMENT_KEY="cpa_$(openssl rand -hex 32)"
        ADMIN_KEY="cpamp_$(openssl rand -hex 32)"
        printf '%s\n' "$MANAGEMENT_KEY" > "$INSTALL_ROOT/secrets/cpa-management-key"
        printf '%s\n' "$ADMIN_KEY" > "$INSTALL_ROOT/secrets/cpamp-admin-key"

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
          local expected="$1"
          local archive_name="$2"
          local archive_path="$3"
          local actual
          case "$expected" in
            ''|*[!0-9a-fA-F]*) printf '%s\n' '固定发布摘要格式无效。' >&2; return 17 ;;
          esac
          [ "${#expected}" -eq 64 ] || { printf '%s\n' '固定发布摘要长度无效。' >&2; return 17; }
          if [ "$SHA256_COMMAND" = "shasum" ]; then
            actual="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
          else
            actual="$(sha256sum "$archive_path" | awk '{print $1}')"
          fi
          [ "$actual" = "$expected" ] || { printf '固定 SHA-256 校验失败：%s。\n' "$archive_name" >&2; return 17; }
        }

        yaml_escape() {
          printf '%s' "$1" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g'
        }

        set_stage "resolve-cli-version"
        CLI_DIR="$INSTALL_ROOT/cli-proxy-api"
        CLI_RUNTIME="$CLI_DIR/runtime/$CLI_PACKAGE"
        CLI_ARCHIVE="$CLI_DIR/downloads/$CLI_PACKAGE.tar.gz"
        CLI_ARCHIVE_PART="${CLI_ARCHIVE}.part"
        mkdir -p "$CLI_RUNTIME" "$CLI_DIR/downloads" "$CLI_DIR/auths" "$CLI_DIR/logs"
        rm -f "$CLI_ARCHIVE_PART"
        set_stage "download-cli"
        if ! curl_retry --fail --silent --show-error --location --max-redirs 3 --proto '=https' --proto-redir '=https' --max-filesize \(DeploymentPinSet.nativeArchiveMaxBytes) "https://github.com/router-for-me/CLIProxyAPI/releases/download/$CLI_VERSION_TAG/$CLI_ASSET" -o "$CLI_ARCHIVE_PART"; then
          rm -f "$CLI_ARCHIVE_PART"
          exit 18
        fi
        set_stage "verify-cli"
        if ! verify_fixed_archive "$CLI_EXPECTED_SHA256" "$CLI_PACKAGE.tar.gz" "$CLI_ARCHIVE_PART"; then
          rm -f "$CLI_ARCHIVE_PART"
          exit 17
        fi
        if ! tar -tzf "$CLI_ARCHIVE_PART" >/dev/null; then
          printf '%s\n' 'CLIProxyAPI 下载包不完整或不是有效的 tar.gz。' >&2
          rm -f "$CLI_ARCHIVE_PART"
          exit 17
        fi
        mv "$CLI_ARCHIVE_PART" "$CLI_ARCHIVE"
        set_stage "install-cli"
        tar -xzf "$CLI_ARCHIVE" -C "$CLI_RUNTIME"
        CLI_BINARY="$CLI_RUNTIME/cli-proxy-api"
        [ -f "$CLI_BINARY" ] || { printf '%s\n' 'CLIProxyAPI 原生包中没有找到 cli-proxy-api。' >&2; exit 15; }
        chmod 755 "$CLI_BINARY"

        AUTH_DIR_YAML="$(yaml_escape "$CLI_DIR/auths")"
        cat > "$CLI_DIR/config.yaml" <<EOF
        host: "127.0.0.1"
        port: 8317

        remote-management:
          allow-remote: false
          secret-key: "$MANAGEMENT_KEY"
          disable-control-panel: false
          disable-auto-update-panel: true
          panel-github-repository: "https://github.com/seakee/CPA-Manager-Plus"

        auth-dir: "$AUTH_DIR_YAML"
        api-keys: []
        usage-statistics-enabled: true
        EOF

        cat > "$CLI_DIR/run.sh" <<EOF
        #!/bin/bash
        set -euo pipefail
        exec 3>&- 4>&-
        cd "$CLI_DIR"
        exec "$CLI_BINARY" -config "$CLI_DIR/config.yaml"
        EOF
        chmod 755 "$CLI_DIR/run.sh"

        set_stage "resolve-cpamp-version"
        CPAMP_DIR="$INSTALL_ROOT/cpamp"
        CPAMP_RUNTIME="$CPAMP_DIR/runtime"
        CPAMP_BINARY_DIR="$CPAMP_RUNTIME/$CPAMP_PACKAGE"
        CPAMP_ARCHIVE="$CPAMP_DIR/downloads/$CPAMP_PACKAGE.tar.gz"
        CPAMP_ARCHIVE_PART="${CPAMP_ARCHIVE}.part"
        mkdir -p "$CPAMP_RUNTIME" "$CPAMP_DIR/downloads" "$CPAMP_DIR/data"
        rm -f "$CPAMP_ARCHIVE_PART"
        set_stage "download-cpamp"
        if ! curl_retry --fail --silent --show-error --location --max-redirs 3 --proto '=https' --proto-redir '=https' --max-filesize \(DeploymentPinSet.nativeArchiveMaxBytes) "https://github.com/seakee/CPA-Manager-Plus/releases/download/$CPAMP_VERSION_TAG/$CPAMP_ASSET" -o "$CPAMP_ARCHIVE_PART"; then
          rm -f "$CPAMP_ARCHIVE_PART"
          exit 18
        fi
        set_stage "verify-cpamp"
        if ! verify_fixed_archive "$CPAMP_EXPECTED_SHA256" "$CPAMP_PACKAGE.tar.gz" "$CPAMP_ARCHIVE_PART"; then
          rm -f "$CPAMP_ARCHIVE_PART"
          exit 17
        fi
        if ! tar -tzf "$CPAMP_ARCHIVE_PART" >/dev/null; then
          printf '%s\n' 'CPA Manager Plus 下载包不完整或不是有效的 tar.gz。' >&2
          rm -f "$CPAMP_ARCHIVE_PART"
          exit 17
        fi
        mv "$CPAMP_ARCHIVE_PART" "$CPAMP_ARCHIVE"
        set_stage "install-cpamp"
        tar -xzf "$CPAMP_ARCHIVE" -C "$CPAMP_RUNTIME"
        CPAMP_BINARY="$CPAMP_BINARY_DIR/cpa-manager-plus"
        [ -f "$CPAMP_BINARY" ] || { printf '%s\n' 'CPA Manager Plus 原生包中没有找到 cpa-manager-plus。' >&2; exit 16; }
        chmod 755 "$CPAMP_BINARY"

        cat > "$CPAMP_BINARY_DIR/config.json" <<EOF
        {
          "httpAddr": "127.0.0.1:18317",
          "dataDir": "../../data",
          "adminKeyFile": "../../../secrets/cpamp-admin-key",
          "dataKeyPath": "../../data/data.key",
          "cpaUpstreamUrl": "http://127.0.0.1:8317",
          "managementKeyFile": "../../../secrets/cpa-management-key",
          "collectorMode": "auto",
          "queue": "usage",
          "popSide": "right",
          "batchSize": 100,
          "pollIntervalMs": 500,
          "queryLimit": 50000
        }
        EOF

        cat > "$CPAMP_DIR/run.sh" <<EOF
        #!/bin/bash
        set -euo pipefail
        exec 3>&- 4>&-
        cd "$CPAMP_BINARY_DIR"
        exec "$CPAMP_BINARY"
        EOF
        chmod 755 "$CPAMP_DIR/run.sh"

        set_stage "start-cli"
        nohup "$CLI_DIR/run.sh" >> "$INSTALL_ROOT/logs/cli-proxy-api.log" 2>&1 &
        printf '%s\n' "$!" > "$INSTALL_ROOT/cli-proxy-api.pid"

        set_stage "wait-cli"
        for _ in $(seq 1 45); do
          if curl -fsS -H "Authorization: Bearer $MANAGEMENT_KEY" http://127.0.0.1:8317/v0/management/config >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done
        curl -fsS -H "Authorization: Bearer $MANAGEMENT_KEY" http://127.0.0.1:8317/v0/management/config >/dev/null

        set_stage "start-cpamp"
        nohup "$CPAMP_DIR/run.sh" >> "$INSTALL_ROOT/logs/cpa-manager-plus.log" 2>&1 &
        printf '%s\n' "$!" > "$INSTALL_ROOT/cpa-manager-plus.pid"

        set_stage "wait-cpamp"
        for _ in $(seq 1 45); do
          if curl -fsS http://127.0.0.1:18317/health >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done
        curl -fsS http://127.0.0.1:18317/health >/dev/null

        set_stage "finalize"
        touch "$INSTALL_ROOT/.oases-cpa-installed"
        printf '[%s] Oases CPA 原生部署完成。\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'OASES_CPA_MANAGEMENT_KEY=%s\n' "$(cat "$INSTALL_ROOT/secrets/cpa-management-key")" >&3
        printf 'OASES_CPAMP_ADMIN_KEY=%s\n' "$(cat "$INSTALL_ROOT/secrets/cpamp-admin-key")" >&3
        """
    }

    private func dockerScript(
        installDirectory: String,
        controlToken: String,
        installerURL: String = Self.cpampInstallerURL,
        installerSHA256: String = Self.cpampInstallerSHA256,
        installerMaxBytes: Int = Self.cpampInstallerMaxBytes
    ) -> String {
        let root = shellQuote(installDirectory)
        let token = shellQuote(controlToken)

        return """
        set -euo pipefail

        INSTALL_ROOT=\(root)
        CONTROL_TOKEN=\(token)
        case "$INSTALL_ROOT" in
          "~") INSTALL_ROOT="$HOME" ;;
          "~/"*) INSTALL_ROOT="$HOME/${INSTALL_ROOT#\\~/}" ;;
        esac
        if [ "$INSTALL_ROOT" != "/" ]; then
          INSTALL_ROOT="${INSTALL_ROOT%/}"
        fi

        mkdir -p "$INSTALL_ROOT"
        LOCK_DIR="$INSTALL_ROOT/.oases-cpa-deployment-lock"
        release_deployment_lock() {
          rm -f "$LOCK_DIR/pid" >/dev/null 2>&1 || true
          rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
        }
        if [ -d "$LOCK_DIR" ]; then
          LOCK_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
          if [ -n "$LOCK_PID" ] && kill -0 "$LOCK_PID" >/dev/null 2>&1; then
            printf '%s\n' '另一个 Oases CPA 部署正在进行，请等待完成后再试。' >&2
            exit 11
          fi
          release_deployment_lock
        fi
        mkdir "$LOCK_DIR" 2>/dev/null || {
          printf '%s\n' '无法获取目标目录的部署锁，请稍后重试。' >&2
          exit 11
        }
        printf '%s\n' "$$" > "$LOCK_DIR/pid"

        MANAGED_ROOT_MARKER="$INSTALL_ROOT/.oases-cpa-managed"

        if [ -e "$INSTALL_ROOT/.oases-cpa-installed" ]; then
          release_deployment_lock
          printf '%s\n' '检测到目标目录中已有成功部署，已阻止重复安装。请连接对应的已保存目标；如需新建，请选择空目录。' >&2
          exit 12
        fi

        RECOVERY_NOTE=""
        LEGACY_OWNERSHIP_MARKER_PRESENT=0
        if [ -e "$INSTALL_ROOT/.oases-cpa-installing" ] || [ -e "$INSTALL_ROOT/.oases-cpa-failed" ]; then
          LEGACY_OWNERSHIP_MARKER_PRESENT=1
        fi
        if [ -e "$INSTALL_ROOT/.oases-cpa-installing" ] || \
           [ -e "$INSTALL_ROOT/.oases-cpa-failed" ] || \
           { [ -e "$MANAGED_ROOT_MARKER" ] && [ ! -e "$INSTALL_ROOT/.oases-cpa-installed" ]; }; then
          AUTO_BACKUP_NAME="auto-recovery-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
          AUTO_BACKUP_ROOT="$INSTALL_ROOT/backups/$AUTO_BACKUP_NAME"
          recover_stale_attempt() {
            if [ -f "$INSTALL_ROOT/compose.yaml" ] || [ -f "$INSTALL_ROOT/compose.yml" ]; then
              command -v docker >/dev/null 2>&1 || return 1
              docker compose version >/dev/null 2>&1 || return 1
              (cd "$INSTALL_ROOT" && docker compose down) || return 1
            fi
            mkdir -p "$AUTO_BACKUP_ROOT" || return 1
            move_recovery_item() {
              local item="$1"
              if [ -e "$INSTALL_ROOT/$item" ]; then
                mv "$INSTALL_ROOT/$item" "$AUTO_BACKUP_ROOT/$item" || return 1
              fi
              return 0
            }
            move_recovery_item ".env" || return 1
            move_recovery_item "compose.yaml" || return 1
            move_recovery_item "compose.yml" || return 1
            move_recovery_item "secrets" || return 1
            move_recovery_item "data" || return 1
            move_recovery_item "logs" || return 1
            move_recovery_item ".oases-cpa-installing" || return 1
            move_recovery_item ".oases-cpa-failed" || return 1
            return 0
          }
          if ! recover_stale_attempt; then
            release_deployment_lock
            printf '%s\n' '上次 Docker 失败部署无法安全停止并备份，本次重试已停止。' >&2
            exit 19
          fi
          RECOVERY_NOTE="已自动备份上次未完成的 Docker 部署到 backups/${AUTO_BACKUP_NAME}，现在重新开始。"
        fi

        if [ ! -e "$MANAGED_ROOT_MARKER" ] && [ "$LEGACY_OWNERSHIP_MARKER_PRESENT" -ne 1 ]; then
          FIRST_UNMANAGED_ENTRY="$(find "$INSTALL_ROOT" -mindepth 1 -maxdepth 1 \
            ! -name '.oases-cpa-deployment-lock' \
            ! -name 'backups' \
            ! -name '.DS_Store' \
            -print -quit)"
          if [ -n "$FIRST_UNMANAGED_ENTRY" ]; then
            release_deployment_lock
            printf '%s\n' '目标目录并非空目录，且没有 Oases CPA 受管标记。为保护已有数据，请换用空目录。' >&2
            exit 12
          fi
        fi
        if [ ! -e "$MANAGED_ROOT_MARKER" ]; then
          printf 'owned-by=oases-cpa\n' > "$MANAGED_ROOT_MARKER"
          chmod 600 "$MANAGED_ROOT_MARKER"
        fi

        mkdir -p "$INSTALL_ROOT/logs"
        DEPLOYMENT_LOG="$INSTALL_ROOT/logs/deployment.log"
        exec 3>&1 4>&2
        exec >> "$DEPLOYMENT_LOG" 2>&1
        ATTEMPT_MARKER="$INSTALL_ROOT/.oases-cpa-installing"
        FAILURE_MARKER="$INSTALL_ROOT/.oases-cpa-failed"
        PAUSE_MARKER="$INSTALL_ROOT/.oases-cpa-paused"
        INSTALLER=""
        INSTALLER_URL_RESULT=""
        CPAMP_INSTALLER_URL=\(shellQuote(installerURL))
        INSTALLER_EXPECTED_SHA256=\(shellQuote(installerSHA256))
        INSTALLER_MAX_BYTES=\(installerMaxBytes)
        \(DeploymentPinSet.current.dockerImageEnvironmentScript())
        cleanup_installer() {
          if [ -n "${INSTALLER:-}" ]; then
            rm -f "$INSTALLER" || true
          fi
          if [ -n "${INSTALLER_URL_RESULT:-}" ]; then
            rm -f "$INSTALLER_URL_RESULT" || true
          fi
        }
        CURRENT_STAGE="prepare"
        set_stage() {
          CURRENT_STAGE="$1"
          local marker_part="${ATTEMPT_MARKER}.part.$$"
          printf 'timestamp=%s\nmethod=docker\nstage=%s\npid=%s\ncontrol_token=%s\n' \
            "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$CURRENT_STAGE" "$$" "$CONTROL_TOKEN" > "$marker_part"
          mv "$marker_part" "$ATTEMPT_MARKER"
          printf '[%s] Docker 部署阶段：%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$CURRENT_STAGE"
        }
        deployment_exit_status() {
          local status="$?"
          set +e
          cleanup_installer
          if [ "$status" -eq 0 ]; then
            rm -f "$ATTEMPT_MARKER" "$FAILURE_MARKER" "$PAUSE_MARKER"
          else
            printf 'timestamp=%s\nmethod=docker\nstage=%s\nexit_status=%s\n' \
              "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$CURRENT_STAGE" "$status" > "$FAILURE_MARKER"
            printf '[%s] Docker 部署在阶段 %s 失败（退出码 %s）。\n' \
              "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$CURRENT_STAGE" "$status"
            tail -n 120 "$DEPLOYMENT_LOG" >&4 2>/dev/null || true
          fi
          release_deployment_lock
          trap - EXIT
          exit "$status"
        }
        deployment_cancelled() {
          CURRENT_STAGE="cancelled"
          exit 130
        }
        trap deployment_exit_status EXIT
        trap deployment_cancelled TERM INT
        set_stage "prepare"
        printf '\n[%s] Oases CPA Docker 部署开始。\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        if [ -n "$RECOVERY_NOTE" ]; then
          printf '%s\n' "$RECOVERY_NOTE"
        fi

        command -v curl >/dev/null 2>&1 || { printf '%s\n' '目标环境缺少 curl。' >&2; exit 13; }
        command -v docker >/dev/null 2>&1 || { printf '%s\n' '目标环境缺少 Docker。' >&2; exit 13; }
        docker compose version >/dev/null 2>&1 || { printf '%s\n' '目标环境缺少 Docker Compose。' >&2; exit 13; }
        docker info >/dev/null 2>&1 || { printf '%s\n' 'Docker daemon 不可用，请先启动 Docker。' >&2; exit 13; }
        if command -v shasum >/dev/null 2>&1; then
          SHA256_COMMAND="shasum"
        elif command -v sha256sum >/dev/null 2>&1; then
          SHA256_COMMAND="sha256sum"
        else
          printf '%s\n' '目标环境缺少 shasum 或 sha256sum。' >&2
          exit 13
        fi

        constant_time_hex_equal() {
          local expected="$1"
          local actual="$2"
          local diff=0
          local i left right
          [ "${#expected}" -eq "${#actual}" ] || return 1
          for ((i = 0; i < ${#expected}; i++)); do
            printf -v left '%d' "'${expected:i:1}"
            printf -v right '%d' "'${actual:i:1}"
            diff=$((diff | (left ^ right)))
          done
          [ "$diff" -eq 0 ]
        }
        verify_installer() {
          local installer_size actual
          installer_size="$(wc -c < "$INSTALLER" | tr -d '[:space:]')"
          case "$installer_size" in
            ''|*[!0-9]*) printf '%s\n' '安装脚本大小无法验证。' >&2; return 1 ;;
          esac
          if [ "$installer_size" -gt "$INSTALLER_MAX_BYTES" ]; then
            printf '安装脚本超过大小上限（%s bytes）。\n' "$INSTALLER_MAX_BYTES" >&2
            return 1
          fi
          if [ "$SHA256_COMMAND" = "shasum" ]; then
            actual="$(shasum -a 256 "$INSTALLER" | awk '{print $1}')"
          else
            actual="$(sha256sum "$INSTALLER" | awk '{print $1}')"
          fi
          case "$actual" in
            ''|*[!0-9a-fA-F]*) printf '%s\n' '安装脚本 SHA-256 格式无效。' >&2; return 1 ;;
          esac
          [ "${#actual}" -eq 64 ] || {
            printf '%s\n' '安装脚本 SHA-256 长度无效。' >&2
            return 1
          }
          if ! constant_time_hex_equal "$INSTALLER_EXPECTED_SHA256" "$actual"; then
            printf '%s\n' '安装脚本 SHA-256 校验失败。' >&2
            return 1
          fi
        }
        download_installer() {
          local attempt final_url
          for attempt in 1 2 3 4; do
            : > "$INSTALLER"
            : > "$INSTALLER_URL_RESULT"
            if curl \
              --connect-timeout 20 \
              --speed-limit 1024 \
              --speed-time 60 \
              --max-time 1800 \
              --fail --silent --show-error \
              --location \
              --proto '=https' \
              --proto-redir '=https' \
              --max-redirs 0 \
              --max-filesize "$INSTALLER_MAX_BYTES" \
              --write-out '%{url_effective}\n' \
              "$CPAMP_INSTALLER_URL" \
              -o "$INSTALLER" > "$INSTALLER_URL_RESULT"; then
              final_url="$(cat "$INSTALLER_URL_RESULT")"
              if [ "$final_url" != "$CPAMP_INSTALLER_URL" ]; then
                printf '%s\n' '安装脚本 URL 发生了非 allowlist 重定向。' >&2
                return 17
              fi
              return 0
            fi
            [ "$attempt" -lt 4 ] || return 1
            sleep $((attempt * 2))
          done
        }

        set_stage "download-installer"
        INSTALLER="$(mktemp -t oases-cpa-installer.XXXXXX)"
        INSTALLER_URL_RESULT="$(mktemp -t oases-cpa-installer-url.XXXXXX)"
        chmod 600 "$INSTALLER" "$INSTALLER_URL_RESULT"
        if ! download_installer; then
          cleanup_installer
          exit 18
        fi
        set_stage "verify-installer"
        if ! verify_installer; then
          cleanup_installer
          exit 17
        fi
        chmod 755 "$INSTALLER"

        set_stage "run-installer"
        if ! CPAMP_NON_INTERACTIVE=1 \
          CPAMP_CONFIRM=1 \
          CPAMP_LANG=en-US \
          CPAMP_INSTALL_MODE=stack \
          CPAMP_DEPLOY_METHOD=docker \
          CPAMP_INSTALL_DIR="$INSTALL_ROOT" \
          CPAMP_PROJECT_NAME=oasescpa \
          CPAMP_PORT=18317 \
          CPAMP_CPA_PORT=8317 \
          CPAMP_IMAGE="$CPAMP_DOCKER_IMAGE" \
          CPAMP_CPA_IMAGE="$CLI_DOCKER_IMAGE" \
          CPAMP_SKIP_EXECUTE=1 \
          bash "$INSTALLER" > "$INSTALL_ROOT/logs/installer.log" 2>&1; then
          tail -n 120 "$INSTALL_ROOT/logs/installer.log" || true
          exit 15
        fi

        set_stage "secure-loopback-ports"
        sed -i.bak \
          -e 's|- "${CPAMP_PORT}:18317"|- "127.0.0.1:${CPAMP_PORT}:18317"|' \
          -e 's|- "${CPAMP_CPA_PORT}:8317"|- "127.0.0.1:${CPAMP_CPA_PORT}:8317"|' \
          "$INSTALL_ROOT/compose.yaml"
        rm -f "$INSTALL_ROOT/compose.yaml.bak"

        set_stage "pull-containers"
        if ! (cd "$INSTALL_ROOT" && CPAMP_IMAGE="$CPAMP_DOCKER_IMAGE" CPA_IMAGE="$CLI_DOCKER_IMAGE" docker compose pull > "$INSTALL_ROOT/logs/docker-pull.log" 2>&1); then
          tail -n 120 "$INSTALL_ROOT/logs/docker-pull.log" || true
          exit 16
        fi
        set_stage "start-containers"
        if ! (cd "$INSTALL_ROOT" && CPAMP_IMAGE="$CPAMP_DOCKER_IMAGE" CPA_IMAGE="$CLI_DOCKER_IMAGE" docker compose up -d > "$INSTALL_ROOT/logs/docker-up.log" 2>&1); then
          tail -n 120 "$INSTALL_ROOT/logs/docker-up.log" || true
          exit 16
        fi

        set_stage "wait-cpamp"
        for _ in $(seq 1 60); do
          if curl -fsS http://127.0.0.1:18317/health >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done
        curl -fsS http://127.0.0.1:18317/health >/dev/null

        set_stage "verify-cli"
        CPA_KEY="$(cat "$INSTALL_ROOT/secrets/cpa-management-key")"
        curl -fsS -H "Authorization: Bearer $CPA_KEY" http://127.0.0.1:8317/v0/management/config >/dev/null

        set_stage "finalize"
        touch "$INSTALL_ROOT/.oases-cpa-installed"
        printf '[%s] Oases CPA Docker 部署完成。\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'OASES_CPA_MANAGEMENT_KEY=%s\n' "$CPA_KEY" >&3
        printf 'OASES_CPAMP_ADMIN_KEY=%s\n' "$(cat "$INSTALL_ROOT/secrets/cpamp-admin-key")" >&3
        """
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
