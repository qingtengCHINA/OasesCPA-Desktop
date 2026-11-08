import Foundation

struct DeploymentLogSnapshot: Sendable {
    let source: String
    let text: String
}

struct DeploymentLogService {
    func read(request: DeploymentExecutionRequest) async throws -> DeploymentLogSnapshot {
        let script = logScript(method: request.method, installDirectory: request.installDirectory)
        let output: String

        do {
            switch request.target {
            case .local:
                output = try await BoundedProcessRunner.run(
                    executable: "/bin/bash",
                    arguments: ["-s"],
                    standardInput: script,
                    timeout: 30
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
                    timeout: 30
                ).standardOutput
            }
        } catch let error as BoundedProcessError {
            throw DeploymentExecutionError.commandFailed(
                BoundedProcessRunner.userFacingMessage(
                    for: error,
                    fallback: OasesLocalization.localized("读取目标日志失败。")
                )
            )
        }

        let source = request.method == .native
            ? OasesLocalization.localized("目标目录 logs/deployment.log、CLIProxyAPI、CPAMP 与 Oases 网关运行日志")
            : OasesLocalization.localized("目标目录的部署日志与 docker compose logs")
        return DeploymentLogSnapshot(source: source, text: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func scriptForVerification(method: DeploymentMethod, installDirectory: String) -> String {
        logScript(method: method, installDirectory: installDirectory)
    }

    private func logScript(method: DeploymentMethod, installDirectory: String) -> String {
        let root = shellQuote(installDirectory)

        switch method {
        case .native:
            return """
            set -u

            ROOT=\(root)
            case "$ROOT" in
              "~") ROOT="$HOME" ;;
              "~/"*) ROOT="$HOME/${ROOT#\\~/}" ;;
            esac
            if [ "$ROOT" != "/" ]; then
              ROOT="${ROOT%/}"
            fi

            \(DeploymentScriptFragments.managedProcessList(topology: .gateway))
            found_evidence=no
            for state_file in "$ROOT/.oases-cpa-installing" "$ROOT/.oases-cpa-failed"; do
              if [ -f "$state_file" ]; then
                found_evidence=yes
                printf '\\n===== %s =====\\n' "$state_file"
                cat "$state_file" 2>&1 || true
              fi
            done
            for log_name in logs/deployment.log $OASES_MANAGED_LOG_FILES; do
              log_file="$ROOT/$log_name"
              if [ -f "$log_file" ]; then
                found_evidence=yes
                printf '\\n===== %s =====\\n' "$log_file"
                tail -n 120 "$log_file" 2>&1 || true
              fi
            done
            if [ "$found_evidence" = no ]; then
              printf '%s\\n' '目标目录中尚未找到 Oases CPA 日志。'
            fi
            """
        case .docker:
            return """
            set -u

            ROOT=\(root)
            case "$ROOT" in
              "~") ROOT="$HOME" ;;
              "~/"*) ROOT="$HOME/${ROOT#\\~/}" ;;
            esac
            if [ "$ROOT" != "/" ]; then
              ROOT="${ROOT%/}"
            fi

            found_evidence=no
            for state_file in "$ROOT/.oases-cpa-installing" "$ROOT/.oases-cpa-failed"; do
              if [ -f "$state_file" ]; then
                found_evidence=yes
                printf '\\n===== %s =====\\n' "$state_file"
                cat "$state_file" 2>&1 || true
              fi
            done
            for log_file in "$ROOT/logs/deployment.log" "$ROOT/logs/installer.log" "$ROOT/logs/docker-pull.log" "$ROOT/logs/docker-up.log"; do
              if [ -f "$log_file" ]; then
                found_evidence=yes
                printf '\\n===== %s =====\\n' "$log_file"
                tail -n 120 "$log_file" 2>&1 || true
              fi
            done
            if [ -d "$ROOT" ] && command -v docker >/dev/null 2>&1 && { [ -f "$ROOT/compose.yaml" ] || [ -f "$ROOT/compose.yml" ]; }; then
              found_evidence=yes
              cd "$ROOT" || exit 0
              printf '\\n===== docker compose logs =====\\n'
              docker compose logs --tail 120 --no-color 2>&1 || true
            fi
            if [ "$found_evidence" = no ]; then
              printf '%s\\n' '目标目录中尚未找到 Oases CPA 部署证据或 Compose 日志。'
            fi
            """
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
