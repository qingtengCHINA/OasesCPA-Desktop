import Foundation

struct RuntimeLifecycleService {
    /// Where the health checks look (the engine moves to 18316 behind the gateway). The one
    /// source of endpoints for every check of this value; no call takes its own.
    let endpoints: DeploymentEndpoints
    /// The health checks send the management key and read the engine config: no disk cache
    /// (`SecretBearingURLSession`). Tests inject a stub session to see the requests.
    let session: URLSession

    init(
        session: URLSession = SecretBearingURLSession.shared,
        endpoints: DeploymentEndpoints = DeploymentEndpoints(topology: .legacy)
    ) {
        self.session = session
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

    /// The gateway's unauthenticated `GET /healthz` on the admin port (interfaces §5); nil for
    /// a legacy deployment, which has no gateway.
    var gatewayHealthURL: URL? {
        endpoints.gatewayAdminBaseURL?.appendingPathComponent("healthz")
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
        if await allHealthy(cpaManagementKey: cpaManagementKey) {
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

    /// The 30 s patrol: the engine and CPA Manager Plus, plus the gateway in the gateway
    /// topology (the endpoints of this value decide).
    func checkConnectionHealth(cpaManagementKey: String) async -> Bool {
        await allHealthy(cpaManagementKey: cpaManagementKey)
    }

    private func allHealthy(cpaManagementKey: String) async -> Bool {
        let cpaHealthy = await isHealthy(cpaManagementKey: cpaManagementKey)
        let panelHealthy = await isPanelHealthy()
        guard cpaHealthy, panelHealthy else { return false }
        guard gatewayHealthURL != nil else { return true }
        return await isGatewayHealthy()
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
            if await allHealthy(cpaManagementKey: cpaManagementKey) {
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
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// `GET /healthz` without any credential (never the management key: the route is open, and
    /// the key must not travel where it is not needed). Healthy is 200 with `"ok": true`. A 401
    /// or any other status is simply unhealthy; nothing is retried here.
    private func isGatewayHealthy() async -> Bool {
        guard let url = gatewayHealthURL else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.httpShouldHandleCookies = false
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return object["ok"] as? Bool == true
        } catch {
            return false
        }
    }

    private func isPanelHealthy() async -> Bool {
        var request = URLRequest(url: panelHealthURL)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await session.data(for: request)
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
            \(DeploymentScriptFragments.managedProcessList(topology: .gateway))
            \(DeploymentScriptFragments.managedProcessStop())
            start_if_needed() {
              local script="$1"
              local pid_file="$2"
              local log_file="$3"
              local expected_root="$4"
              if [ -f "$pid_file" ] && oases_pid_owned_by "$(cat "$pid_file" 2>/dev/null || true)" "$expected_root"; then
                return
              fi
              rm -f "$pid_file"
              nohup "$script" >> "$log_file" 2>&1 &
              printf '%s\\n' "$!" > "$pid_file"
            }
            \(nativeStartLines())
            """
        }
    }

    /// One `start_if_needed` per managed process in start order (engine, CPA Manager Plus,
    /// then the gateway, which only starts when `gateway/run.sh` is there: a legacy 0.1.x
    /// deployment has none).
    private func nativeStartLines() -> String {
        DeploymentScriptFragments.managedProcesses(topology: .gateway).map { process in
            let line = "start_if_needed \"$ROOT/\(process.runScript)\" \"$ROOT/\(process.pidFile)\" \"$ROOT/\(process.logFile)\" \"$ROOT/\(process.ownedPath)\""
            guard process.startsOnlyWhenInstalled else { return line }
            return "if [ -x \"$ROOT/\(process.runScript)\" ]; then\n  \(line)\nfi"
        }.joined(separator: "\n")
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
            \(DeploymentScriptFragments.managedProcessList(topology: .gateway))
            \(DeploymentScriptFragments.managedProcessStop())
            # Gateway first (it waits up to 30 s for in-flight requests), then CPA Manager Plus
            # and the engine (5 s each); only processes whose command line is under this root.
            for pid_name in $OASES_MANAGED_STOP_ORDER; do
              pid_file="$ROOT/$pid_name"
              [ -f "$pid_file" ] || continue
              pid="$(cat "$pid_file" 2>/dev/null || true)"
              expected_root="$ROOT/$(oases_managed_owned_path "$pid_name")"
              oases_stop_owned_pid "$pid" "$expected_root" "$pid_name"
              rm -f "$pid_file"
            done
            """
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
