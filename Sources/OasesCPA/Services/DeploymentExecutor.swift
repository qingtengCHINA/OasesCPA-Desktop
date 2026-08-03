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
        }
    }
}

struct DeploymentExecutor {
    private static let cpampInstallerURL = "https://raw.githubusercontent.com/seakee/CPA-Manager-Plus/main/bin/install-cpamp.sh"

    func execute(request: DeploymentExecutionRequest) async throws -> DeploymentExecutionResult {
        try validate(request)

        let script = request.method == .docker
            ? dockerScript(installDirectory: request.installDirectory)
            : nativeScript(installDirectory: request.installDirectory)

        let output: String
        switch request.target {
        case .local:
            output = try await runProcess(
                executable: "/bin/bash",
                arguments: ["-s"],
                standardInput: script
            )
        case .ssh:
            let sshArguments = try SSHConnectionService.connectionArguments(
                port: request.port,
                privateKeyPath: request.privateKeyPath
            )
            output = try await runProcess(
                executable: "/usr/bin/ssh",
                arguments: sshArguments + [
                    "\(request.user)@\(request.host)",
                    "bash -s"
                ],
                standardInput: script
            )
        }

        return try parseResult(output)
    }

    func scriptForVerification(method: DeploymentMethod, installDirectory: String) -> String {
        method == .docker
            ? dockerScript(installDirectory: installDirectory)
            : nativeScript(installDirectory: installDirectory)
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

    private func runProcess(
        executable: String,
        arguments: [String],
        standardInput: String
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            let inputPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                inputPipe.fileHandleForWriting.write(Data(standardInput.utf8))
                inputPipe.fileHandleForWriting.closeFile()
            } catch {
                throw DeploymentExecutionError.commandFailed(error.localizedDescription)
            }

            process.waitUntilExit()

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw DeploymentExecutionError.commandFailed(
                    SSHConnectionService.userFacingError(errorOutput, fallback: OasesLocalization.localized("目标终端部署命令失败。"))
                )
            }

            return output
        }.value
    }

    private func nativeScript(installDirectory: String) -> String {
        let root = shellQuote(installDirectory)

        return """
        set -euo pipefail

        INSTALL_ROOT=\(root)
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

        if [ -e "$INSTALL_ROOT/.oases-cpa-installed" ]; then
          release_deployment_lock
          printf '%s\n' '检测到目标目录中已有成功部署，已阻止重复安装。请连接对应的已保存目标；如需新建，请选择空目录。' >&2
          exit 12
        fi

        RECOVERY_NOTE=""
        if [ -e "$INSTALL_ROOT/.oases-cpa-installing" ] || [ -e "$INSTALL_ROOT/.oases-cpa-failed" ]; then
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

        if [ -e "$INSTALL_ROOT/cli-proxy-api" ] || [ -e "$INSTALL_ROOT/cpamp" ]; then
          release_deployment_lock
          printf '%s\n' '目标目录包含非当前部署生成的 CLIProxyAPI 或 CPAMP 文件。为保护已有数据，请换用空目录。' >&2
          exit 12
        fi

        mkdir -p "$INSTALL_ROOT/logs" "$INSTALL_ROOT/secrets"
        DEPLOYMENT_LOG="$INSTALL_ROOT/logs/deployment.log"
        exec 3>&1 4>&2
        exec >> "$DEPLOYMENT_LOG" 2>&1
        CURRENT_STAGE="prepare"
        ATTEMPT_MARKER="$INSTALL_ROOT/.oases-cpa-installing"
        FAILURE_MARKER="$INSTALL_ROOT/.oases-cpa-failed"
        printf 'timestamp=%s\nmethod=native\nstage=%s\npid=%s\n' \
          "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$CURRENT_STAGE" "$$" > "$ATTEMPT_MARKER"
        deployment_exit_status() {
          local status="$?"
          set +e
          if [ "$status" -eq 0 ]; then
            rm -f "$ATTEMPT_MARKER" "$FAILURE_MARKER"
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
        trap deployment_exit_status EXIT
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
          arm64|aarch64) CLI_ARCH="aarch64"; CPAMP_ARCH="arm64" ;;
          x86_64|amd64) CLI_ARCH="amd64"; CPAMP_ARCH="amd64" ;;
          *) printf '%s\n' '目标架构不在官方原生包支持范围内。' >&2; exit 14 ;;
        esac

        umask 077
        MANAGEMENT_KEY="cpa_$(openssl rand -hex 32)"
        ADMIN_KEY="cpamp_$(openssl rand -hex 32)"
        printf '%s\n' "$MANAGEMENT_KEY" > "$INSTALL_ROOT/secrets/cpa-management-key"
        printf '%s\n' "$ADMIN_KEY" > "$INSTALL_ROOT/secrets/cpamp-admin-key"

        curl_retry() {
          local attempt
          for attempt in 1 2 3 4; do
            if curl --connect-timeout 20 "$@"; then
              return 0
            fi
            [ "$attempt" -lt 4 ] || return 1
            sleep $((attempt * 2))
          done
        }

        latest_tag() {
          local location
          location="$(curl_retry -fsSLI -o /dev/null -w '%{url_effective}' "$1")" || return 1
          [ -n "$location" ] || return 1
          printf '%s\n' "${location##*/}"
        }

        verify_archive() {
          local repository="$1"
          local version_tag="$2"
          local archive_name="$3"
          local archive_path="$4"
          local checksums expected actual

          checksums="$(curl_retry -fsSL "https://github.com/$repository/releases/download/$version_tag/checksums.txt")"
          expected="$(printf '%s\n' "$checksums" | awk -v file="$archive_name" '{name=$NF; sub(/^\\.\\//, "", name); if (name == file) {print $1; exit}}')"
          [ -n "$expected" ] || { printf 'checksums.txt 中没有找到 %s。\n' "$archive_name" >&2; exit 17; }
          if [ "$SHA256_COMMAND" = "shasum" ]; then
            actual="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
          else
            actual="$(sha256sum "$archive_path" | awk '{print $1}')"
          fi
          [ "$actual" = "$expected" ] || { printf 'SHA-256 校验失败：%s。\n' "$archive_name" >&2; exit 17; }
        }

        yaml_escape() {
          printf '%s' "$1" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g'
        }

        CURRENT_STAGE="resolve-cli-version"
        CLI_VERSION_TAG="$(latest_tag 'https://github.com/router-for-me/CLIProxyAPI/releases/latest')"
        CLI_VERSION="${CLI_VERSION_TAG#v}"
        CLI_PACKAGE="CLIProxyAPI_${CLI_VERSION}_${RELEASE_OS}_${CLI_ARCH}"
        CLI_DIR="$INSTALL_ROOT/cli-proxy-api"
        CLI_RUNTIME="$CLI_DIR/runtime/$CLI_PACKAGE"
        CLI_ARCHIVE="$CLI_DIR/downloads/$CLI_PACKAGE.tar.gz"
        mkdir -p "$CLI_RUNTIME" "$CLI_DIR/downloads" "$CLI_DIR/auths" "$CLI_DIR/logs"
        CURRENT_STAGE="download-cli"
        curl_retry -fsSL "https://github.com/router-for-me/CLIProxyAPI/releases/download/$CLI_VERSION_TAG/$CLI_PACKAGE.tar.gz" -o "$CLI_ARCHIVE"
        CURRENT_STAGE="verify-cli"
        verify_archive "router-for-me/CLIProxyAPI" "$CLI_VERSION_TAG" "$CLI_PACKAGE.tar.gz" "$CLI_ARCHIVE"
        CURRENT_STAGE="install-cli"
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
        cd "$CLI_DIR"
        exec "$CLI_BINARY" -config "$CLI_DIR/config.yaml"
        EOF
        chmod 755 "$CLI_DIR/run.sh"

        CURRENT_STAGE="resolve-cpamp-version"
        CPAMP_VERSION_TAG="$(latest_tag 'https://github.com/seakee/CPA-Manager-Plus/releases/latest')"
        CPAMP_PACKAGE="cpa-manager-plus_${CPAMP_VERSION_TAG}_${RELEASE_OS}_${CPAMP_ARCH}"
        CPAMP_DIR="$INSTALL_ROOT/cpamp"
        CPAMP_RUNTIME="$CPAMP_DIR/runtime"
        CPAMP_BINARY_DIR="$CPAMP_RUNTIME/$CPAMP_PACKAGE"
        CPAMP_ARCHIVE="$CPAMP_DIR/downloads/$CPAMP_PACKAGE.tar.gz"
        mkdir -p "$CPAMP_RUNTIME" "$CPAMP_DIR/downloads" "$CPAMP_DIR/data"
        CURRENT_STAGE="download-cpamp"
        curl_retry -fsSL "https://github.com/seakee/CPA-Manager-Plus/releases/download/$CPAMP_VERSION_TAG/$CPAMP_PACKAGE.tar.gz" -o "$CPAMP_ARCHIVE"
        CURRENT_STAGE="verify-cpamp"
        verify_archive "seakee/CPA-Manager-Plus" "$CPAMP_VERSION_TAG" "$CPAMP_PACKAGE.tar.gz" "$CPAMP_ARCHIVE"
        CURRENT_STAGE="install-cpamp"
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
        cd "$CPAMP_BINARY_DIR"
        exec "$CPAMP_BINARY"
        EOF
        chmod 755 "$CPAMP_DIR/run.sh"

        CURRENT_STAGE="start-cli"
        nohup "$CLI_DIR/run.sh" >> "$INSTALL_ROOT/logs/cli-proxy-api.log" 2>&1 &
        printf '%s\n' "$!" > "$INSTALL_ROOT/cli-proxy-api.pid"

        CURRENT_STAGE="wait-cli"
        for _ in $(seq 1 45); do
          if curl -fsS -H "Authorization: Bearer $MANAGEMENT_KEY" http://127.0.0.1:8317/v0/management/config >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done
        curl -fsS -H "Authorization: Bearer $MANAGEMENT_KEY" http://127.0.0.1:8317/v0/management/config >/dev/null

        CURRENT_STAGE="start-cpamp"
        nohup "$CPAMP_DIR/run.sh" >> "$INSTALL_ROOT/logs/cpa-manager-plus.log" 2>&1 &
        printf '%s\n' "$!" > "$INSTALL_ROOT/cpa-manager-plus.pid"

        CURRENT_STAGE="wait-cpamp"
        for _ in $(seq 1 45); do
          if curl -fsS http://127.0.0.1:18317/health >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done
        curl -fsS http://127.0.0.1:18317/health >/dev/null

        CURRENT_STAGE="finalize"
        touch "$INSTALL_ROOT/.oases-cpa-installed"
        printf '[%s] Oases CPA 原生部署完成。\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'OASES_CPA_MANAGEMENT_KEY=%s\n' "$(cat "$INSTALL_ROOT/secrets/cpa-management-key")" >&3
        printf 'OASES_CPAMP_ADMIN_KEY=%s\n' "$(cat "$INSTALL_ROOT/secrets/cpamp-admin-key")" >&3
        """
    }

    private func dockerScript(installDirectory: String) -> String {
        let root = shellQuote(installDirectory)

        return """
        set -euo pipefail

        INSTALL_ROOT=\(root)
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

        if [ -e "$INSTALL_ROOT/.oases-cpa-installed" ]; then
          release_deployment_lock
          printf '%s\n' '检测到目标目录中已有成功部署，已阻止重复安装。请连接对应的已保存目标；如需新建，请选择空目录。' >&2
          exit 12
        fi

        RECOVERY_NOTE=""
        if [ -e "$INSTALL_ROOT/.oases-cpa-installing" ] || [ -e "$INSTALL_ROOT/.oases-cpa-failed" ]; then
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

        if [ -e "$INSTALL_ROOT/.env" ] || [ -e "$INSTALL_ROOT/compose.yaml" ] || [ -e "$INSTALL_ROOT/compose.yml" ]; then
          release_deployment_lock
          printf '%s\n' '目标目录包含非当前部署生成的 Compose 文件。为保护已有数据，请换用空目录。' >&2
          exit 12
        fi

        mkdir -p "$INSTALL_ROOT/logs"
        DEPLOYMENT_LOG="$INSTALL_ROOT/logs/deployment.log"
        exec 3>&1 4>&2
        exec >> "$DEPLOYMENT_LOG" 2>&1
        CURRENT_STAGE="prepare"
        ATTEMPT_MARKER="$INSTALL_ROOT/.oases-cpa-installing"
        FAILURE_MARKER="$INSTALL_ROOT/.oases-cpa-failed"
        printf 'timestamp=%s\nmethod=docker\nstage=%s\npid=%s\n' \
          "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$CURRENT_STAGE" "$$" > "$ATTEMPT_MARKER"
        deployment_exit_status() {
          local status="$?"
          set +e
          rm -f "${INSTALLER:-}" || true
          if [ "$status" -eq 0 ]; then
            rm -f "$ATTEMPT_MARKER" "$FAILURE_MARKER"
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
        trap deployment_exit_status EXIT
        printf '\n[%s] Oases CPA Docker 部署开始。\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        if [ -n "$RECOVERY_NOTE" ]; then
          printf '%s\n' "$RECOVERY_NOTE"
        fi

        command -v curl >/dev/null 2>&1 || { printf '%s\n' '目标环境缺少 curl。' >&2; exit 13; }
        command -v docker >/dev/null 2>&1 || { printf '%s\n' '目标环境缺少 Docker。' >&2; exit 13; }
        docker compose version >/dev/null 2>&1 || { printf '%s\n' '目标环境缺少 Docker Compose。' >&2; exit 13; }
        docker info >/dev/null 2>&1 || { printf '%s\n' 'Docker daemon 不可用，请先启动 Docker。' >&2; exit 13; }

        curl_retry() {
          local attempt
          for attempt in 1 2 3 4; do
            if curl --connect-timeout 20 "$@"; then
              return 0
            fi
            [ "$attempt" -lt 4 ] || return 1
            sleep $((attempt * 2))
          done
        }

        CURRENT_STAGE="download-installer"
        INSTALLER="$(mktemp -t oases-cpa-installer.XXXXXX)"
        curl_retry -fsSL "\(Self.cpampInstallerURL)" -o "$INSTALLER"
        chmod 755 "$INSTALLER"

        CURRENT_STAGE="run-installer"
        if ! CPAMP_NON_INTERACTIVE=1 \
          CPAMP_CONFIRM=1 \
          CPAMP_LANG=en-US \
          CPAMP_INSTALL_MODE=stack \
          CPAMP_DEPLOY_METHOD=docker \
          CPAMP_INSTALL_DIR="$INSTALL_ROOT" \
          CPAMP_PROJECT_NAME=oasescpa \
          CPAMP_PORT=18317 \
          CPAMP_CPA_PORT=8317 \
          CPAMP_SKIP_EXECUTE=1 \
          bash "$INSTALLER" > "$INSTALL_ROOT/logs/installer.log" 2>&1; then
          tail -n 120 "$INSTALL_ROOT/logs/installer.log" || true
          exit 15
        fi

        CURRENT_STAGE="secure-loopback-ports"
        sed -i.bak \
          -e 's|- "${CPAMP_PORT}:18317"|- "127.0.0.1:${CPAMP_PORT}:18317"|' \
          -e 's|- "${CPAMP_CPA_PORT}:8317"|- "127.0.0.1:${CPAMP_CPA_PORT}:8317"|' \
          "$INSTALL_ROOT/compose.yaml"
        rm -f "$INSTALL_ROOT/compose.yaml.bak"

        CURRENT_STAGE="pull-containers"
        if ! (cd "$INSTALL_ROOT" && docker compose pull > "$INSTALL_ROOT/logs/docker-pull.log" 2>&1); then
          tail -n 120 "$INSTALL_ROOT/logs/docker-pull.log" || true
          exit 16
        fi
        CURRENT_STAGE="start-containers"
        if ! (cd "$INSTALL_ROOT" && docker compose up -d > "$INSTALL_ROOT/logs/docker-up.log" 2>&1); then
          tail -n 120 "$INSTALL_ROOT/logs/docker-up.log" || true
          exit 16
        fi

        CURRENT_STAGE="wait-cpamp"
        for _ in $(seq 1 60); do
          if curl -fsS http://127.0.0.1:18317/health >/dev/null 2>&1; then
            break
          fi
          sleep 1
        done
        curl -fsS http://127.0.0.1:18317/health >/dev/null

        CURRENT_STAGE="verify-cli"
        CPA_KEY="$(cat "$INSTALL_ROOT/secrets/cpa-management-key")"
        curl -fsS -H "Authorization: Bearer $CPA_KEY" http://127.0.0.1:8317/v0/management/config >/dev/null

        CURRENT_STAGE="finalize"
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
