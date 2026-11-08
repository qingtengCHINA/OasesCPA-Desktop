import Foundation

struct DeploymentMaintenanceResult: Sendable {
    let backupName: String
    let detail: String
}

struct DeploymentMaintenanceService {
    func upgrade(request: DeploymentExecutionRequest) async throws -> DeploymentMaintenanceResult {
        let output = try await execute(
            request: request,
            script: upgradeScript(method: request.method, installDirectory: request.installDirectory)
        )
        return parseResult(output)
    }

    func rollback(request: DeploymentExecutionRequest) async throws -> DeploymentMaintenanceResult {
        let output = try await execute(
            request: request,
            script: rollbackScript(method: request.method, installDirectory: request.installDirectory)
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

    func upgradeScriptForVerification(method: DeploymentMethod, installDirectory: String) -> String {
        upgradeScript(method: method, installDirectory: installDirectory)
    }

    func rollbackScriptForVerification(method: DeploymentMethod, installDirectory: String) -> String {
        rollbackScript(method: method, installDirectory: installDirectory)
    }

    func latestBackupScriptForVerification(installDirectory: String) -> String {
        latestBackupScript(installDirectory: installDirectory)
    }

    private func parseResult(_ output: String) -> DeploymentMaintenanceResult {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let backupPath = values["OASES_CPA_BACKUP"] ?? ""
        return DeploymentMaintenanceResult(
            backupName: URL(fileURLWithPath: backupPath).lastPathComponent,
            detail: values["OASES_CPA_MAINTENANCE_DETAIL"] ?? OasesLocalization.localized("目标服务已完成维护操作。")
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
            throw DeploymentExecutionError.commandFailed(
                BoundedProcessRunner.userFacingMessage(
                    for: error,
                    fallback: OasesLocalization.localized("目标终端维护命令失败。")
                )
            )
        }
    }

    private func upgradeScript(method: DeploymentMethod, installDirectory: String) -> String {
        switch method {
        case .native:
            nativeUpgradeScript(installDirectory: installDirectory)
        case .docker:
            dockerUpgradeScript(installDirectory: installDirectory)
        }
    }

    private func rollbackScript(method: DeploymentMethod, installDirectory: String) -> String {
        switch method {
        case .native:
            nativeRollbackScript(installDirectory: installDirectory)
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
        if [ -n "$BACKUP_ROOT" ]; then printf 'OASES_CPA_BACKUP=%s\n' "$BACKUP_ROOT"; fi
        """
    }

    private func nativeUpgradeScript(installDirectory: String) -> String {
        let root = shellQuote(installDirectory)
        let stopScript = RuntimeLifecycleService().stopScriptForVerification(
            method: .native,
            installDirectory: installDirectory
        )
        let startScript = RuntimeLifecycleService().startScriptForVerification(
            method: .native,
            installDirectory: installDirectory
        )

        return """
        set -euo pipefail

        ROOT=\(root)
        case "$ROOT" in
          "~") ROOT="$HOME" ;;
          "~/"*) ROOT="$HOME/$(printf '%s' "$ROOT" | cut -c 3-)" ;;
        esac
        ROOT="$(printf '%s' "$ROOT" | sed 's#/$##')"
        [ "$ROOT" != "" ] && [ "$ROOT" != "/" ] || { printf '%s\n' '升级目录无效，为保护文件系统已停止。' >&2; exit 18; }
        [ -f "$ROOT/.oases-cpa-installed" ] || { printf '%s\n' '未找到已安装的 Oases CPA 部署。' >&2; exit 18; }
        command -v curl >/dev/null 2>&1 || { printf '%s\n' '目标环境缺少 curl。' >&2; exit 13; }
        command -v tar >/dev/null 2>&1 || { printf '%s\n' '目标环境缺少 tar。' >&2; exit 13; }
        command -v openssl >/dev/null 2>&1 || { printf '%s\n' '目标环境缺少 openssl。' >&2; exit 13; }
        if command -v shasum >/dev/null 2>&1; then SHA256_COMMAND="shasum"; elif command -v sha256sum >/dev/null 2>&1; then SHA256_COMMAND="sha256sum"; else printf '%s\n' '目标环境缺少 shasum 或 sha256sum。' >&2; exit 13; fi

        BACKUP_NAME="upgrade-$(date -u '+%Y%m%d-%H%M%S')"
        BACKUP_ROOT="$ROOT/backups/$BACKUP_NAME"
        TEMP_ROOT="$ROOT/.oases-cpa-upgrade-$BACKUP_NAME"
        mkdir -p "$BACKUP_ROOT/cli-proxy-api-runtime" "$BACKUP_ROOT/cpamp-runtime" "$TEMP_ROOT"
        [ -f "$ROOT/cli-proxy-api/run.sh" ] && cp -p "$ROOT/cli-proxy-api/run.sh" "$BACKUP_ROOT/cli-proxy-api-run.sh"
        [ -f "$ROOT/cpamp/run.sh" ] && cp -p "$ROOT/cpamp/run.sh" "$BACKUP_ROOT/cpamp-run.sh"
        [ -f "$ROOT/cli-proxy-api/config.yaml" ] && cp -p "$ROOT/cli-proxy-api/config.yaml" "$BACKUP_ROOT/cli-proxy-api-config.yaml"

        restore_previous() {
          set +e
          [ -f "$BACKUP_ROOT/cli-proxy-api-run.sh" ] && cp -p "$BACKUP_ROOT/cli-proxy-api-run.sh" "$ROOT/cli-proxy-api/run.sh"
          [ -f "$BACKUP_ROOT/cpamp-run.sh" ] && cp -p "$BACKUP_ROOT/cpamp-run.sh" "$ROOT/cpamp/run.sh"
          for package in "$BACKUP_ROOT/cli-proxy-api-runtime"/*; do
            [ -e "$package" ] || continue
            package_name="$(basename "$package")"
            rm -rf "$ROOT/cli-proxy-api/runtime/$package_name"
            mv "$package" "$ROOT/cli-proxy-api/runtime/$package_name"
          done
          for package in "$BACKUP_ROOT/cpamp-runtime"/*; do
            [ -e "$package" ] || continue
            package_name="$(basename "$package")"
            rm -rf "$ROOT/cpamp/runtime/$package_name"
            mv "$package" "$ROOT/cpamp/runtime/$package_name"
          done
        }

        upgrade_exit() {
          status="$?"
          trap - EXIT
          if [ "$status" -ne 0 ]; then
            (
            \(stopScript)
            ) >/dev/null 2>&1 || true
            restore_previous
            (
            \(startScript)
            ) >/dev/null 2>&1 || true
          fi
          rm -rf "$TEMP_ROOT" || true
          exit "$status"
        }
        trap upgrade_exit EXIT

        (
        \(stopScript)
        )

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

        verify_fixed_archive() {
          expected="$1"
          archive_name="$2"
          archive_path="$3"
          case "$expected" in
            ''|*[!0-9a-fA-F]*) printf '%s\n' '固定发布摘要格式无效。' >&2; return 17 ;;
          esac
          [ "${#expected}" -eq 64 ] || { printf '%s\n' '固定发布摘要长度无效。' >&2; return 17; }
          if [ "$SHA256_COMMAND" = "shasum" ]; then actual="$(shasum -a 256 "$archive_path" | awk '{print $1}')"; else actual="$(sha256sum "$archive_path" | awk '{print $1}')"; fi
          [ "$actual" = "$expected" ] || { printf '固定 SHA-256 校验失败：%s。\n' "$archive_name" >&2; return 17; }
        }

        case "$(uname -s)" in
          Darwin) RELEASE_OS="darwin" ;;
          Linux) RELEASE_OS="linux" ;;
          *) printf '%s\n' '目标系统不是支持的 macOS 或 Linux。' >&2; exit 14 ;;
        esac
        case "$(uname -m)" in
          arm64|aarch64) CLI_ARCH="aarch64"; CPAMP_ARCH="arm64"; ARCH="arm64" ;;
          x86_64|amd64) CLI_ARCH="amd64"; CPAMP_ARCH="amd64"; ARCH="amd64" ;;
          *) printf '%s\n' '目标架构不在官方原生包支持范围内。' >&2; exit 14 ;;
        esac

        \(DeploymentPinSet.current.nativeSelectionScript())

        CLI_VERSION="$(printf '%s' "$CLI_VERSION_TAG" | sed 's/^v//')"
        CLI_PACKAGE="CLIProxyAPI_${CLI_VERSION}_${RELEASE_OS}_${CLI_ARCH}"
        CLI_TEMP_DIR="$TEMP_ROOT/cli-proxy-api/runtime/$CLI_PACKAGE"
        CLI_ARCHIVE="$TEMP_ROOT/cli-proxy-api/$CLI_PACKAGE.tar.gz"
        mkdir -p "$CLI_TEMP_DIR" "$TEMP_ROOT/cli-proxy-api"
        curl_retry --fail --silent --show-error --location --max-redirs 3 --proto '=https' --proto-redir '=https' --max-filesize \(DeploymentPinSet.nativeArchiveMaxBytes) "https://github.com/router-for-me/CLIProxyAPI/releases/download/$CLI_VERSION_TAG/$CLI_PACKAGE.tar.gz" -o "$CLI_ARCHIVE"
        verify_fixed_archive "$CLI_EXPECTED_SHA256" "$CLI_PACKAGE.tar.gz" "$CLI_ARCHIVE"
        tar -xzf "$CLI_ARCHIVE" -C "$CLI_TEMP_DIR"
        [ -f "$CLI_TEMP_DIR/cli-proxy-api" ] || { printf '%s\n' 'CLIProxyAPI 升级包中没有找到 cli-proxy-api。' >&2; exit 15; }
        chmod 755 "$CLI_TEMP_DIR/cli-proxy-api"
        if [ -e "$ROOT/cli-proxy-api/runtime/$CLI_PACKAGE" ]; then mv "$ROOT/cli-proxy-api/runtime/$CLI_PACKAGE" "$BACKUP_ROOT/cli-proxy-api-runtime/$CLI_PACKAGE"; fi
        mkdir -p "$ROOT/cli-proxy-api/runtime"
        mv "$CLI_TEMP_DIR" "$ROOT/cli-proxy-api/runtime/$CLI_PACKAGE"
        CLI_BINARY="$ROOT/cli-proxy-api/runtime/$CLI_PACKAGE/cli-proxy-api"
        cat > "$ROOT/cli-proxy-api/run.sh" <<EOF
        #!/bin/bash
        set -euo pipefail
        cd "$ROOT/cli-proxy-api"
        exec "$CLI_BINARY" -config "$ROOT/cli-proxy-api/config.yaml"
        EOF
        chmod 755 "$ROOT/cli-proxy-api/run.sh"

        CPAMP_PACKAGE="cpa-manager-plus_${CPAMP_VERSION_TAG}_${RELEASE_OS}_${CPAMP_ARCH}"
        CPAMP_TEMP_DIR="$TEMP_ROOT/cpamp/runtime"
        CPAMP_ARCHIVE="$TEMP_ROOT/cpamp/$CPAMP_PACKAGE.tar.gz"
        mkdir -p "$CPAMP_TEMP_DIR" "$TEMP_ROOT/cpamp"
        curl_retry --fail --silent --show-error --location --max-redirs 3 --proto '=https' --proto-redir '=https' --max-filesize \(DeploymentPinSet.nativeArchiveMaxBytes) "https://github.com/seakee/CPA-Manager-Plus/releases/download/$CPAMP_VERSION_TAG/$CPAMP_PACKAGE.tar.gz" -o "$CPAMP_ARCHIVE"
        verify_fixed_archive "$CPAMP_EXPECTED_SHA256" "$CPAMP_PACKAGE.tar.gz" "$CPAMP_ARCHIVE"
        tar -xzf "$CPAMP_ARCHIVE" -C "$CPAMP_TEMP_DIR"
        [ -f "$CPAMP_TEMP_DIR/$CPAMP_PACKAGE/cpa-manager-plus" ] || { printf '%s\n' 'CPA Manager Plus 升级包中没有找到 cpa-manager-plus。' >&2; exit 16; }
        chmod 755 "$CPAMP_TEMP_DIR/$CPAMP_PACKAGE/cpa-manager-plus"
        if [ -e "$ROOT/cpamp/runtime/$CPAMP_PACKAGE" ]; then mv "$ROOT/cpamp/runtime/$CPAMP_PACKAGE" "$BACKUP_ROOT/cpamp-runtime/$CPAMP_PACKAGE"; fi
        mkdir -p "$ROOT/cpamp/runtime"
        mv "$CPAMP_TEMP_DIR/$CPAMP_PACKAGE" "$ROOT/cpamp/runtime/$CPAMP_PACKAGE"
        CPAMP_BINARY_DIR="$ROOT/cpamp/runtime/$CPAMP_PACKAGE"
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
        cat > "$ROOT/cpamp/run.sh" <<EOF
        #!/bin/bash
        set -euo pipefail
        cd "$CPAMP_BINARY_DIR"
        exec "$CPAMP_BINARY_DIR/cpa-manager-plus"
        EOF
        chmod 755 "$ROOT/cpamp/run.sh"

        (
        \(startScript)
        )
        CPA_KEY="$(cat "$ROOT/secrets/cpa-management-key")"
        for _ in $(seq 1 45); do
          if curl -fsS -H "Authorization: Bearer $CPA_KEY" http://127.0.0.1:8317/v0/management/config >/dev/null 2>&1 && curl -fsS http://127.0.0.1:18317/health >/dev/null 2>&1; then break; fi
          sleep 1
        done
        curl -fsS -H "Authorization: Bearer $CPA_KEY" http://127.0.0.1:8317/v0/management/config >/dev/null
        curl -fsS http://127.0.0.1:18317/health >/dev/null
        printf 'OASES_CPA_BACKUP=%s\n' "$BACKUP_ROOT"
        printf 'OASES_CPA_MAINTENANCE_DETAIL=%s\n' '已升级 CLIProxyAPI 与 CPA Manager Plus；原配置、认证文件和 CPAMP 数据保持不变。'
        """
    }

    private func nativeRollbackScript(installDirectory: String) -> String {
        let root = shellQuote(installDirectory)
        let stopScript = RuntimeLifecycleService().stopScriptForVerification(
            method: .native,
            installDirectory: installDirectory
        )
        let startScript = RuntimeLifecycleService().startScriptForVerification(
            method: .native,
            installDirectory: installDirectory
        )

        return """
        set -euo pipefail
        ROOT=\(root)
        case "$ROOT" in
          "~") ROOT="$HOME" ;;
          "~/"*) ROOT="$HOME/$(printf '%s' "$ROOT" | cut -c 3-)" ;;
        esac
        ROOT="$(printf '%s' "$ROOT" | sed 's#/$##')"
        [ -f "$ROOT/.oases-cpa-installed" ] || { printf '%s\n' '未找到已安装的 Oases CPA 部署。' >&2; exit 18; }
        BACKUP_ROOT=""
        if [ -d "$ROOT/backups" ]; then
          BACKUP_ROOT="$(find "$ROOT/backups" -mindepth 1 -maxdepth 1 -type d -name 'upgrade-*' -print 2>/dev/null | sort | tail -n 1 || true)"
        fi
        [ -n "$BACKUP_ROOT" ] || { printf '%s\n' '目标目录中还没有可回滚的升级备份。' >&2; exit 19; }
        [ -f "$BACKUP_ROOT/cli-proxy-api-run.sh" ] || { printf '%s\n' '升级备份缺少 CLIProxyAPI 启动脚本。' >&2; exit 19; }
        [ -f "$BACKUP_ROOT/cpamp-run.sh" ] || { printf '%s\n' '升级备份缺少 CPAMP 启动脚本。' >&2; exit 19; }
        (
        \(stopScript)
        )
        cp -p "$BACKUP_ROOT/cli-proxy-api-run.sh" "$ROOT/cli-proxy-api/run.sh"
        cp -p "$BACKUP_ROOT/cpamp-run.sh" "$ROOT/cpamp/run.sh"
        [ ! -f "$BACKUP_ROOT/cli-proxy-api-config.yaml" ] || cp -p "$BACKUP_ROOT/cli-proxy-api-config.yaml" "$ROOT/cli-proxy-api/config.yaml"
        for package in "$BACKUP_ROOT/cli-proxy-api-runtime"/*; do
          [ -e "$package" ] || continue
          package_name="$(basename "$package")"
          rm -rf "$ROOT/cli-proxy-api/runtime/$package_name"
          mv "$package" "$ROOT/cli-proxy-api/runtime/$package_name"
        done
        for package in "$BACKUP_ROOT/cpamp-runtime"/*; do
          [ -e "$package" ] || continue
          package_name="$(basename "$package")"
          rm -rf "$ROOT/cpamp/runtime/$package_name"
          mv "$package" "$ROOT/cpamp/runtime/$package_name"
        done
        (
        \(startScript)
        )
        CPA_KEY="$(cat "$ROOT/secrets/cpa-management-key")"
        for _ in $(seq 1 45); do
          if curl -fsS -H "Authorization: Bearer $CPA_KEY" http://127.0.0.1:8317/v0/management/config >/dev/null 2>&1 && curl -fsS http://127.0.0.1:18317/health >/dev/null 2>&1; then break; fi
          sleep 1
        done
        curl -fsS -H "Authorization: Bearer $CPA_KEY" http://127.0.0.1:8317/v0/management/config >/dev/null
        curl -fsS http://127.0.0.1:18317/health >/dev/null
        printf 'OASES_CPA_BACKUP=%s\n' "$BACKUP_ROOT"
        printf 'OASES_CPA_MAINTENANCE_DETAIL=%s\n' '已恢复上一版原生运行时；配置、认证文件和 CPAMP 数据保持不变。'
        """
    }

    private func dockerUpgradeScript(installDirectory: String) -> String {
        let root = shellQuote(installDirectory)
        return """
        set -euo pipefail
        ROOT=\(root)
        case "$ROOT" in
          "~") ROOT="$HOME" ;;
          "~/"*) ROOT="$HOME/$(printf '%s' "$ROOT" | cut -c 3-)" ;;
        esac
        ROOT="$(printf '%s' "$ROOT" | sed 's#/$##')"
        [ -f "$ROOT/.oases-cpa-installed" ] || { printf '%s\n' '未找到已安装的 Oases CPA 部署。' >&2; exit 18; }
        command -v docker >/dev/null 2>&1 || { printf '%s\n' '目标环境缺少 Docker。' >&2; exit 13; }
        docker compose version >/dev/null 2>&1 || { printf '%s\n' '目标环境缺少 Docker Compose。' >&2; exit 13; }
        docker info >/dev/null 2>&1 || { printf '%s\n' 'Docker daemon 不可用，请先启动 Docker。' >&2; exit 13; }
        \(DeploymentPinSet.current.dockerImageEnvironmentScript())
        BACKUP_NAME="upgrade-$(date -u '+%Y%m%d-%H%M%S')"
        BACKUP_ROOT="$ROOT/backups/$BACKUP_NAME"
        mkdir -p "$BACKUP_ROOT" "$ROOT/logs"
        cp -p "$ROOT/compose.yaml" "$BACKUP_ROOT/compose.yaml"
        [ ! -e "$ROOT/.env" ] || cp -p "$ROOT/.env" "$BACKUP_ROOT/.env"
        cd "$ROOT"
        CPAMP_IMAGE="$CPAMP_DOCKER_IMAGE" CPA_IMAGE="$CLI_DOCKER_IMAGE" docker compose pull > "$ROOT/logs/docker-upgrade-pull.log" 2>&1
        CPAMP_IMAGE="$CPAMP_DOCKER_IMAGE" CPA_IMAGE="$CLI_DOCKER_IMAGE" docker compose up -d > "$ROOT/logs/docker-upgrade-up.log" 2>&1
        for _ in $(seq 1 60); do
          if curl -fsS http://127.0.0.1:18317/health >/dev/null 2>&1; then break; fi
          sleep 1
        done
        curl -fsS http://127.0.0.1:18317/health >/dev/null
        printf 'OASES_CPA_BACKUP=%s\n' "$BACKUP_ROOT"
        printf 'OASES_CPA_MAINTENANCE_DETAIL=%s\n' '已拉取并重启 Docker Compose 服务；当前 Docker 镜像版本由 Compose 文件决定。'
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
        [ -f "$ROOT/compose.yaml" ] || { printf '%s\n' '未找到 Docker Compose 部署。' >&2; exit 18; }
        command -v docker >/dev/null 2>&1 || { printf '%s\n' '目标环境缺少 Docker。' >&2; exit 13; }
        docker compose version >/dev/null 2>&1 || { printf '%s\n' '目标环境缺少 Docker Compose。' >&2; exit 13; }
        docker info >/dev/null 2>&1 || { printf '%s\n' 'Docker daemon 不可用，请先启动 Docker。' >&2; exit 13; }
        \(DeploymentPinSet.current.dockerImageEnvironmentScript())
        BACKUP_ROOT=""
        if [ -d "$ROOT/backups" ]; then
          BACKUP_ROOT="$(find "$ROOT/backups" -mindepth 1 -maxdepth 1 -type d -name 'upgrade-*' -print 2>/dev/null | sort | tail -n 1 || true)"
        fi
        [ -n "$BACKUP_ROOT" ] || { printf '%s\n' '目标目录中还没有可回滚的升级备份。' >&2; exit 19; }
        [ -f "$BACKUP_ROOT/compose.yaml" ] || { printf '%s\n' '升级备份缺少 Compose 文件。' >&2; exit 19; }
        cp -p "$BACKUP_ROOT/compose.yaml" "$ROOT/compose.yaml"
        if [ -f "$BACKUP_ROOT/.env" ]; then cp -p "$BACKUP_ROOT/.env" "$ROOT/.env"; fi
        cd "$ROOT"
        CPAMP_IMAGE="$CPAMP_DOCKER_IMAGE" CPA_IMAGE="$CLI_DOCKER_IMAGE" docker compose up -d > "$ROOT/logs/docker-rollback-up.log" 2>&1
        for _ in $(seq 1 60); do
          if curl -fsS http://127.0.0.1:18317/health >/dev/null 2>&1; then break; fi
          sleep 1
        done
        curl -fsS http://127.0.0.1:18317/health >/dev/null
        printf 'OASES_CPA_BACKUP=%s\n' "$BACKUP_ROOT"
        printf 'OASES_CPA_MAINTENANCE_DETAIL=%s\n' '已恢复上一版 Compose 配置；Docker 镜像是否可回退取决于备份中的镜像标签。'
        """
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
