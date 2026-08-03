import Foundation

struct DeploymentProbe: Sendable {
    let operatingSystem: String
    let architecture: String
    let shell: String
    let curlPath: String?
    let tarPath: String?
    let opensslPath: String?
    let sha256Path: String?
    let dockerPath: String?
    let dockerComposeAvailable: Bool
    let dockerDaemonAvailable: Bool
    let installWritable: Bool
    let testedInstallDirectory: String
    let hasManagedRoot: Bool
    let hasManagedInstallation: Bool
    let hasRecoverableCredentials: Bool
    let hasNativeRuntime: Bool
    let hasDockerRuntime: Bool

    func canAdopt(method: DeploymentMethod) -> Bool {
        guard hasManagedInstallation, hasRecoverableCredentials else { return false }
        switch method {
        case .native:
            return hasNativeRuntime
        case .docker:
            return hasDockerRuntime
        }
    }

    func missingDependencies(for method: DeploymentMethod) -> [String] {
        var missing: [String] = []

        switch method {
        case .native:
            if curlPath == nil { missing.append("curl") }
            if tarPath == nil { missing.append("tar") }
            if opensslPath == nil { missing.append("openssl") }
            if sha256Path == nil { missing.append("shasum / sha256sum") }
            if !isSupportedNativeOperatingSystem { missing.append(OasesLocalization.localized("支持的系统（macOS 或 Linux）")) }
            if !isSupportedNativeArchitecture { missing.append(OasesLocalization.localized("支持的架构（arm64 或 x86_64）")) }
        case .docker:
            if curlPath == nil { missing.append("curl") }
            if dockerPath == nil { missing.append("Docker CLI") }
            if !dockerComposeAvailable { missing.append("Docker Compose") }
            if !dockerDaemonAvailable { missing.append(OasesLocalization.localized("运行中的 Docker daemon")) }
        }

        if !installWritable {
            missing.append(OasesLocalization.localized("可写的安装目录"))
        }

        return missing
    }

    func dependencySummary(for method: DeploymentMethod) -> String {
        let missing = missingDependencies(for: method)
        if missing.isEmpty {
            return method == .native
                ? OasesLocalization.localized("curl · tar · openssl · SHA-256 · 安装目录均可用")
                : OasesLocalization.localized("curl · Docker CLI · Compose · daemon · 安装目录均可用")
        }
        return OasesLocalization.localized("缺少：") + missing.joined(separator: OasesLocalization.localized("、"))
    }

    var dependencySummary: String {
        OasesLocalization.localizedFormat("curl：%@ · tar：%@ · Docker：%@", curlPath == nil ? OasesLocalization.localized("不可用") : OasesLocalization.localized("可用"), tarPath == nil ? OasesLocalization.localized("不可用") : OasesLocalization.localized("可用"), dockerPath == nil ? OasesLocalization.localized("不可用") : OasesLocalization.localized("可用"))
    }

    private var isSupportedNativeOperatingSystem: Bool {
        ["Darwin", "Linux"].contains(operatingSystem)
    }

    private var isSupportedNativeArchitecture: Bool {
        ["arm64", "aarch64", "x86_64", "amd64"].contains(architecture)
    }
}

enum DeploymentProbeError: LocalizedError {
    case missingHost
    case missingKey
    case invalidPort
    case invalidHost
    case invalidInstallDirectory
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingHost: OasesLocalization.localized("请先填写远程主机名或 IP 地址。")
        case .missingKey: OasesLocalization.localized("远程 SSH 模式需要选择私钥文件。")
        case .invalidPort: OasesLocalization.localized("SSH 端口必须是 1-65535 之间的数字。")
        case .invalidHost: OasesLocalization.localized("远程主机名不能包含空格或换行。")
        case .invalidInstallDirectory: OasesLocalization.localized("安装目录不能为空，也不能直接使用文件系统根目录。")
        case .commandFailed(let message): message
        }
    }
}

struct DeploymentProbeService {
    func probe(
        target: DeploymentTargetKind,
        host: String,
        user: String,
        port: String,
        privateKeyPath: String,
        installDirectory: String
    ) async throws -> DeploymentProbe {
        let trimmedInstallDirectory = installDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstallDirectory.isEmpty, trimmedInstallDirectory != "/" else {
            throw DeploymentProbeError.invalidInstallDirectory
        }

        switch target {
        case .local:
            return try await runLocalProbe(installDirectory: installDirectory)
        case .ssh:
            guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DeploymentProbeError.missingHost
            }
            guard !host.contains(where: { $0.isWhitespace || $0 == "\n" || $0 == "\r" }) else {
                throw DeploymentProbeError.invalidHost
            }
            guard let portNumber = Int(port), (1...65_535).contains(portNumber) else {
                throw DeploymentProbeError.invalidPort
            }
            guard !privateKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DeploymentProbeError.missingKey
            }
            guard FileManager.default.isReadableFile(atPath: privateKeyPath) else {
                throw DeploymentProbeError.missingKey
            }
            return try await runRemoteProbe(
                host: host,
                user: user,
                port: port,
                privateKeyPath: privateKeyPath,
                installDirectory: installDirectory
            )
        }
    }

    private func runLocalProbe(installDirectory: String) async throws -> DeploymentProbe {
        let command = probeCommand(installDirectory: installDirectory)
        let output = try await runProcess(executable: "/bin/zsh", arguments: ["-lc", command])
        return parse(output, installDirectory: installDirectory)
    }

    private func runRemoteProbe(
        host: String,
        user: String,
        port: String,
        privateKeyPath: String,
        installDirectory: String
    ) async throws -> DeploymentProbe {
        let command = probeCommand(installDirectory: installDirectory)
        let arguments = try SSHConnectionService.connectionArguments(
            port: port,
            privateKeyPath: privateKeyPath
        ) + ["\(user.isEmpty ? "root" : user)@\(host)", command]
        let output = try await runProcess(executable: "/usr/bin/ssh", arguments: arguments)
        return parse(output, installDirectory: installDirectory)
    }

    func parseForVerification(_ output: String, installDirectory: String) -> DeploymentProbe {
        parse(output, installDirectory: installDirectory)
    }

    func commandForVerification(installDirectory: String) -> String {
        probeCommand(installDirectory: installDirectory)
    }

    private func probeCommand(installDirectory: String) -> String {
        let root = shellQuote(installDirectory)

        return """
        set -u

        INSTALL_DIR=\(root)
        case "$INSTALL_DIR" in
          "~") INSTALL_DIR="$HOME" ;;
          "~/"*) INSTALL_DIR="$HOME/${INSTALL_DIR#\\~/}" ;;
        esac

        printf 'os=%s\\n' "$(uname -s 2>/dev/null || printf '%s' unknown)"
        printf 'arch=%s\\n' "$(uname -m 2>/dev/null || printf '%s' unknown)"
        printf 'shell=%s\\n' "${SHELL:-unknown}"
        printf 'curl=%s\\n' "$(command -v curl 2>/dev/null || true)"
        printf 'tar=%s\\n' "$(command -v tar 2>/dev/null || true)"
        printf 'openssl=%s\\n' "$(command -v openssl 2>/dev/null || true)"
        if command -v shasum >/dev/null 2>&1; then
          printf 'sha256=%s\\n' "$(command -v shasum)"
        elif command -v sha256sum >/dev/null 2>&1; then
          printf 'sha256=%s\\n' "$(command -v sha256sum)"
        else
          printf 'sha256=\\n'
        fi
        printf 'docker=%s\\n' "$(command -v docker 2>/dev/null || true)"

        if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
          printf 'docker_compose=yes\\n'
        else
          printf 'docker_compose=no\\n'
        fi

        if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
          printf 'docker_daemon=yes\\n'
        else
          printf 'docker_daemon=no\\n'
        fi

        WRITABLE_PROBE="$INSTALL_DIR"
        while [ ! -e "$WRITABLE_PROBE" ] && [ "$WRITABLE_PROBE" != "/" ] && [ "$WRITABLE_PROBE" != "." ]; do
          NEXT_PROBE="$(dirname "$WRITABLE_PROBE")"
          [ "$NEXT_PROBE" = "$WRITABLE_PROBE" ] && break
          WRITABLE_PROBE="$NEXT_PROBE"
        done
        if [ -d "$WRITABLE_PROBE" ] && [ -w "$WRITABLE_PROBE" ]; then
          printf 'install_writable=yes\\n'
        else
          printf 'install_writable=no\\n'
        fi
        if [ -f "$INSTALL_DIR/.oases-cpa-installed" ] && [ ! -L "$INSTALL_DIR/.oases-cpa-installed" ]; then
          printf 'managed_install=yes\\n'
        else
          printf 'managed_install=no\\n'
        fi
        if [ -f "$INSTALL_DIR/.oases-cpa-managed" ] && [ ! -L "$INSTALL_DIR/.oases-cpa-managed" ] && \
           grep -qx 'owned-by=oases-cpa' "$INSTALL_DIR/.oases-cpa-managed" 2>/dev/null; then
          printf 'managed_root=yes\\n'
        else
          printf 'managed_root=no\\n'
        fi
        if [ -s "$INSTALL_DIR/secrets/cpa-management-key" ] && [ ! -L "$INSTALL_DIR/secrets/cpa-management-key" ] && \
           [ -s "$INSTALL_DIR/secrets/cpamp-admin-key" ] && [ ! -L "$INSTALL_DIR/secrets/cpamp-admin-key" ]; then
          printf 'managed_credentials=yes\\n'
        else
          printf 'managed_credentials=no\\n'
        fi
        if [ -x "$INSTALL_DIR/cli-proxy-api/run.sh" ] && [ -x "$INSTALL_DIR/cpamp/run.sh" ]; then
          printf 'managed_native_runtime=yes\\n'
        else
          printf 'managed_native_runtime=no\\n'
        fi
        if [ -f "$INSTALL_DIR/compose.yaml" ] || [ -f "$INSTALL_DIR/compose.yml" ] || [ -f "$INSTALL_DIR/docker-compose.yml" ] || [ -f "$INSTALL_DIR/docker-compose.yaml" ]; then
          printf 'managed_docker_runtime=yes\\n'
        else
          printf 'managed_docker_runtime=no\\n'
        fi
        """
    }

    private func runProcess(executable: String, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                throw DeploymentProbeError.commandFailed(error.localizedDescription)
            }

            process.waitUntilExit()

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw DeploymentProbeError.commandFailed(
                    SSHConnectionService.userFacingError(errorOutput, fallback: OasesLocalization.localized("目标终端命令执行失败。"))
                )
            }

            return output
        }.value
    }

    private func parse(_ output: String, installDirectory: String) -> DeploymentProbe {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return DeploymentProbe(
            operatingSystem: values["os"] ?? "unknown",
            architecture: values["arch"] ?? "unknown",
            shell: values["shell"] ?? "unknown",
            curlPath: values["curl"].flatMap { $0.isEmpty ? nil : $0 },
            tarPath: values["tar"].flatMap { $0.isEmpty ? nil : $0 },
            opensslPath: values["openssl"].flatMap { $0.isEmpty ? nil : $0 },
            sha256Path: values["sha256"].flatMap { $0.isEmpty ? nil : $0 },
            dockerPath: values["docker"].flatMap { $0.isEmpty ? nil : $0 },
            dockerComposeAvailable: Self.parseBoolean(values["docker_compose"]),
            dockerDaemonAvailable: Self.parseBoolean(values["docker_daemon"]),
            installWritable: Self.parseBoolean(values["install_writable"]),
            testedInstallDirectory: installDirectory,
            hasManagedRoot: Self.parseBoolean(values["managed_root"]),
            hasManagedInstallation: Self.parseBoolean(values["managed_install"]),
            hasRecoverableCredentials: Self.parseBoolean(values["managed_credentials"]),
            hasNativeRuntime: Self.parseBoolean(values["managed_native_runtime"]),
            hasDockerRuntime: Self.parseBoolean(values["managed_docker_runtime"])
        )
    }

    private static func parseBoolean(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["yes", "true", "1"].contains(value.lowercased())
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
