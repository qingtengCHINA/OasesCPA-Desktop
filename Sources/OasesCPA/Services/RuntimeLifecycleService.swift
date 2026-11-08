import Foundation

struct RuntimeLifecycleService {
    /// Where the health checks look (the engine moves to 18316 behind the gateway).
    let endpoints: DeploymentEndpoints

    init(endpoints: DeploymentEndpoints = DeploymentEndpoints(topology: .legacy)) {
        self.endpoints = endpoints
    }

    /// The engine management endpoint the health check reads (needs the management key).
    var engineHealthURL: URL {
        endpoints.engineBaseURL.appendingPathComponent("v0/management/config")
    }

    /// The CPA Manager Plus health endpoint (no key).
    var panelHealthURL: URL {
        endpoints.cpampBaseURL.appendingPathComponent("health")
    }

    func startScriptForVerification(method: DeploymentMethod, installDirectory: String) -> String {
        startScript(method: method, installDirectory: installDirectory)
    }

    func stopScriptForVerification(method: DeploymentMethod, installDirectory: String) -> String {
        stopScript(method: method, installDirectory: installDirectory)
    }

    func ensureRunning(
        target: DeploymentTargetKind,
        method: DeploymentMethod,
        host: String,
        user: String,
        port: String,
        privateKeyPath: String,
        installDirectory: String,
        cpaManagementKey: String
    ) async throws {
        let cpaHealthy = await isHealthy(cpaManagementKey: cpaManagementKey)
        let panelHealthy = await isPanelHealthy()
        if cpaHealthy && panelHealthy {
            return
        }

        let script = startScript(method: method, installDirectory: installDirectory)
        do {
            switch target {
            case .local:
                _ = try await BoundedProcessRunner.run(
                    executable: "/bin/bash",
                    arguments: ["-s"],
                    standardInput: script,
                    timeout: 5 * 60
                )
            case .ssh:
                let sshArguments = try SSHConnectionService.connectionArguments(
                    port: port,
                    privateKeyPath: privateKeyPath
                )
                _ = try await BoundedProcessRunner.run(
                    executable: "/usr/bin/ssh",
                    arguments: sshArguments + [
                        "\(user.isEmpty ? "root" : user)@\(host)",
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
                    fallback: OasesLocalization.localized("生命周期命令执行失败。")
                )
            )
        }

        try await waitForHealth(cpaManagementKey: cpaManagementKey)
    }

    func waitForConnectionHealth(cpaManagementKey: String) async throws {
        try await waitForHealth(cpaManagementKey: cpaManagementKey)
    }

    func checkConnectionHealth(cpaManagementKey: String) async -> Bool {
        let cpaHealthy = await isHealthy(cpaManagementKey: cpaManagementKey)
        let panelHealthy = await isPanelHealthy()
        return cpaHealthy && panelHealthy
    }

    func stop(
        target: DeploymentTargetKind,
        method: DeploymentMethod,
        host: String,
        user: String,
        port: String,
        privateKeyPath: String,
        installDirectory: String
    ) async throws {
        let script = stopScript(method: method, installDirectory: installDirectory)
        do {
            switch target {
            case .local:
                _ = try await BoundedProcessRunner.run(
                    executable: "/bin/bash",
                    arguments: ["-s"],
                    standardInput: script,
                    timeout: 5 * 60
                )
            case .ssh:
                let sshArguments = try SSHConnectionService.connectionArguments(
                    port: port,
                    privateKeyPath: privateKeyPath
                )
                _ = try await BoundedProcessRunner.run(
                    executable: "/usr/bin/ssh",
                    arguments: sshArguments + [
                        "\(user.isEmpty ? "root" : user)@\(host)",
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
                    fallback: OasesLocalization.localized("生命周期命令执行失败。")
                )
            )
        }
    }

    private func waitForHealth(cpaManagementKey: String) async throws {
        for _ in 0..<45 {
            let cpaHealthy = await isHealthy(cpaManagementKey: cpaManagementKey)
            let panelHealthy = await isPanelHealthy()
            if cpaHealthy && panelHealthy {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw DeploymentExecutionError.commandFailed(OasesLocalization.localized("服务已启动，但健康检查未在 45 秒内通过。"))
    }

    private func isHealthy(cpaManagementKey: String) async -> Bool {
        var request = URLRequest(url: engineHealthURL)
        request.timeoutInterval = 2
        request.setValue("Bearer \(cpaManagementKey)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func isPanelHealthy() async -> Bool {
        var request = URLRequest(url: panelHealthURL)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func startScript(method: DeploymentMethod, installDirectory: String) -> String {
        let root = shellQuote(installDirectory)
        switch method {
        case .docker:
            return """
            set -euo pipefail
            ROOT=\(root)
            case "$ROOT" in
              "~") ROOT="$HOME" ;;
              "~/"*) ROOT="$HOME/${ROOT#\\~/}" ;;
            esac
            cd "$ROOT"
            docker compose up -d
            """
        case .native:
            return """
            set -euo pipefail
            ROOT=\(root)
            case "$ROOT" in
              "~") ROOT="$HOME" ;;
              "~/"*) ROOT="$HOME/${ROOT#\\~/}" ;;
            esac
            mkdir -p "$ROOT/logs"
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
            start_if_needed() {
              local script="$1"
              local pid_file="$2"
              local log_file="$3"
              local expected_root="$4"
              if [ -f "$pid_file" ] && managed_process "$(cat "$pid_file")" "$expected_root"; then
                return
              fi
              rm -f "$pid_file"
              nohup "$script" >> "$log_file" 2>&1 &
              printf '%s\n' "$!" > "$pid_file"
            }
            start_if_needed "$ROOT/cli-proxy-api/run.sh" "$ROOT/cli-proxy-api.pid" "$ROOT/logs/cli-proxy-api.log" "$ROOT/cli-proxy-api"
            start_if_needed "$ROOT/cpamp/run.sh" "$ROOT/cpa-manager-plus.pid" "$ROOT/logs/cpa-manager-plus.log" "$ROOT/cpamp"
            """
        }
    }

    private func stopScript(method: DeploymentMethod, installDirectory: String) -> String {
        let root = shellQuote(installDirectory)
        switch method {
        case .docker:
            return """
            set -euo pipefail
            ROOT=\(root)
            case "$ROOT" in
              "~") ROOT="$HOME" ;;
              "~/"*) ROOT="$HOME/${ROOT#\\~/}" ;;
            esac
            cd "$ROOT"
            docker compose stop
            """
        case .native:
            return """
            set -euo pipefail
            ROOT=\(root)
            case "$ROOT" in
              "~") ROOT="$HOME" ;;
              "~/"*) ROOT="$HOME/${ROOT#\\~/}" ;;
            esac
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
                rm -f "$pid_file"
              fi
            done
            """
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
