import Foundation

struct DeploymentRecoveryResult: Sendable {
    let backupName: String
}

struct DeploymentRecoveryService {
    func cleanupFailedDeployment(
        request: DeploymentExecutionRequest,
        backupName: String
    ) async throws -> DeploymentRecoveryResult {
        let script = cleanupScript(
            method: request.method,
            installDirectory: request.installDirectory,
            backupName: backupName
        )
        do {
            switch request.target {
            case .local:
                _ = try await BoundedProcessRunner.run(
                    executable: "/bin/bash",
                    arguments: ["-s"],
                    standardInput: script,
                    timeout: 5 * 60
                )
            case .ssh:
                let sshArguments = try SSHConnectionService.connectionArguments(
                    port: request.port,
                    privateKeyPath: request.privateKeyPath
                )
                _ = try await BoundedProcessRunner.run(
                    executable: "/usr/bin/ssh",
                    arguments: sshArguments + [
                        "\(request.user)@\(request.host)",
                        "bash -s"
                    ],
                    standardInput: script,
                    timeout: 5 * 60
                )
            }
        } catch let error as BoundedProcessError {
            throw DeploymentExecutionError.commandFailed(
                BoundedProcessRunner.userFacingMessage(
                    for: error,
                    fallback: OasesLocalization.localized("清理失败部署失败。")
                )
            )
        }
        return DeploymentRecoveryResult(backupName: backupName)
    }

    func scriptForVerification(
        method: DeploymentMethod,
        installDirectory: String,
        backupName: String
    ) -> String {
        cleanupScript(method: method, installDirectory: installDirectory, backupName: backupName)
    }

    private func cleanupScript(
        method: DeploymentMethod,
        installDirectory: String,
        backupName: String
    ) -> String {
        let root = shellQuote(installDirectory)
        let backup = shellQuote(backupName)

        switch method {
        case .native:
            return """
            set -euo pipefail

            ROOT=\(root)
            case "$ROOT" in
              "~") ROOT="$HOME" ;;
              "~/"*) ROOT="$HOME/${ROOT#\\~/}" ;;
            esac
            if [ "$ROOT" != "/" ]; then
              ROOT="${ROOT%/}"
            fi
            ATTEMPT_MARKER="$ROOT/.oases-cpa-installing"
            FAILURE_MARKER="$ROOT/.oases-cpa-failed"
            if [ ! -e "$ATTEMPT_MARKER" ] && [ ! -e "$FAILURE_MARKER" ]; then
              printf '%s\n' '未找到 Oases CPA 的失败部署标记；为保护目标目录，本次清理已停止。' >&2
              exit 18
            fi

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
            for pid_file in "$ROOT/cli-proxy-api.pid" "$ROOT/cpa-manager-plus.pid"; do
              if [ -f "$pid_file" ]; then
                pid="$(cat "$pid_file")"
                case "$pid_file" in
                  *"/cli-proxy-api.pid") expected_root="$ROOT/cli-proxy-api" ;;
                  *"/cpa-manager-plus.pid") expected_root="$ROOT/cpamp" ;;
                  *) expected_root="$ROOT" ;;
                esac
                if managed_process "$pid" "$expected_root"; then
                  kill -TERM "$pid" >/dev/null 2>&1 || true
                  for _ in $(seq 1 25); do
                    managed_process "$pid" "$expected_root" || break
                    sleep 0.2
                  done
                  if managed_process "$pid" "$expected_root"; then
                    kill -KILL "$pid" >/dev/null 2>&1 || true
                  fi
                fi
              fi
            done

            BACKUP_NAME=\(backup)
            BACKUP_ROOT="$ROOT/backups/$BACKUP_NAME"
            mkdir -p "$BACKUP_ROOT"
            move_if_present() {
              local item="$1"
              if [ -e "$ROOT/$item" ]; then
                mv "$ROOT/$item" "$BACKUP_ROOT/$item"
              fi
            }
            move_if_present "cli-proxy-api"
            move_if_present "cpamp"
            move_if_present "logs"
            move_if_present "secrets"
            move_if_present "cli-proxy-api.pid"
            move_if_present "cpa-manager-plus.pid"
            move_if_present ".oases-cpa-installing"
            move_if_present ".oases-cpa-failed"
            move_if_present ".oases-cpa-installed"
            printf 'OASES_CPA_BACKUP=%s\n' "$BACKUP_ROOT"
            """
        case .docker:
            return """
            set -euo pipefail

            ROOT=\(root)
            case "$ROOT" in
              "~") ROOT="$HOME" ;;
              "~/"*) ROOT="$HOME/${ROOT#\\~/}" ;;
            esac
            if [ "$ROOT" != "/" ]; then
              ROOT="${ROOT%/}"
            fi
            ATTEMPT_MARKER="$ROOT/.oases-cpa-installing"
            FAILURE_MARKER="$ROOT/.oases-cpa-failed"
            if [ ! -e "$ATTEMPT_MARKER" ] && [ ! -e "$FAILURE_MARKER" ]; then
              printf '%s\n' '未找到 Oases CPA 的失败部署标记；为保护目标目录，本次清理已停止。' >&2
              exit 18
            fi

            if [ -f "$ROOT/compose.yaml" ] || [ -f "$ROOT/compose.yml" ]; then
              command -v docker >/dev/null 2>&1 || { printf '%s\n' 'Docker CLI 不可用，无法先停止失败的 Compose 服务。' >&2; exit 19; }
              cd "$ROOT"
              docker compose down
            fi

            BACKUP_NAME=\(backup)
            BACKUP_ROOT="$ROOT/backups/$BACKUP_NAME"
            mkdir -p "$BACKUP_ROOT"
            move_if_present() {
              local item="$1"
              if [ -e "$ROOT/$item" ]; then
                mv "$ROOT/$item" "$BACKUP_ROOT/$item"
              fi
            }
            move_if_present ".env"
            move_if_present "compose.yaml"
            move_if_present "compose.yml"
            move_if_present "secrets"
            move_if_present "data"
            move_if_present "logs"
            move_if_present ".oases-cpa-installing"
            move_if_present ".oases-cpa-failed"
            move_if_present ".oases-cpa-installed"
            printf 'OASES_CPA_BACKUP=%s\n' "$BACKUP_ROOT"
            """
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
