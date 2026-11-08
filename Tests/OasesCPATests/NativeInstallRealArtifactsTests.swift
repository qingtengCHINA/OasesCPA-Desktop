import Foundation
import XCTest
@testable import OasesCPA

/// Opt-in end-to-end drill of the fresh native install with the REAL pinned packages (engine,
/// CPA Manager Plus, Node for this Mac) and the real bundled gateway, in a scratch install root
/// with random free loopback ports and a scratch HOME. Skipped unless
/// `OASES_E2E_REAL_ARTIFACTS` names a directory that holds the three pinned darwin/arm64 (or
/// darwin/amd64) packages under their release file names. Nothing is downloaded: a curl shim
/// serves the release URLs from that directory and hands every other call to /usr/bin/curl.
/// Egress of the started programs is refused through a closed loopback proxy, and the gateway's
/// model catalog fetch is off. Everything the drill starts is stopped at the end.
final class NativeInstallRealArtifactsTests: XCTestCase {
    func testRealPackagesInstallBootstrapAndAnswerHealthChecks() async throws {
        guard let artifacts = ProcessInfo.processInfo.environment["OASES_E2E_REAL_ARTIFACTS"], !artifacts.isEmpty else {
            throw XCTSkip("set OASES_E2E_REAL_ARTIFACTS to a directory with the pinned packages")
        }
        let fileManager = FileManager.default
        let caseDirectory = FakeArtifacts.scratchRoot.appendingPathComponent("real-e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fileManager.createDirectory(at: caseDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bin = caseDirectory.appendingPathComponent("bin")
        let home = caseDirectory.appendingPathComponent("home")
        for directory in [bin, home] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let root = caseDirectory.appendingPathComponent("root")
        let argvLog = caseDirectory.appendingPathComponent("curl-argv.log")
        fileManager.createFile(atPath: argvLog.path, contents: Data())
        try Data(#"""
        #!/bin/bash
        { printf 'curl'; for arg in "$@"; do printf ' %s' "$arg"; done; printf '\n'; } >> "$E2E_ARGV_LOG"
        url=""; out=""; prev=""
        for arg in "$@"; do
          if [ "$prev" = "-o" ]; then out="$arg"; fi
          case "$arg" in https://*) url="$arg" ;; esac
          prev="$arg"
        done
        case "$url" in
          https://github.com/*/releases/download/*|https://nodejs.org/dist/*)
            exec cp "$E2E_ARTIFACTS/$(basename "$url")" "$out" ;;
          https://*) echo "e2e: refused $url" >&2; exit 7 ;;
        esac
        exec /usr/bin/curl "$@"
        """#.utf8).write(to: bin.appendingPathComponent("curl"))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("curl").path)

        let ports = try freePorts(4)
        let scriptPorts = DeploymentScriptPorts(gatewayAPI: ports[0], gatewayAdmin: ports[1], engine: ports[2], cpamp: ports[3])
        let script = DeploymentExecutor().scriptForVerification(
            method: .native,
            installDirectory: root.path,
            pins: try DeploymentPinSet.current.deployable(),
            ports: scriptPorts
        )
        let scriptURL = caseDirectory.appendingPathComponent("install.sh")
        try Data(script.utf8).write(to: scriptURL)

        let stdoutURL = caseDirectory.appendingPathComponent("stdout.txt")
        let stderrURL = caseDirectory.appendingPathComponent("stderr.txt")
        fileManager.createFile(atPath: stdoutURL.path, contents: Data())
        fileManager.createFile(atPath: stderrURL.path, contents: Data())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.environment = [
            "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path,
            "TMPDIR": caseDirectory.path,
            "LC_ALL": "C",
            "E2E_ARGV_LOG": argvLog.path,
            "E2E_ARTIFACTS": artifacts,
            // A closed loopback port as proxy: every outbound HTTP(S) request of the engine and
            // the panel fails at once; loopback stays direct.
            "HTTPS_PROXY": "http://127.0.0.1:9",
            "HTTP_PROXY": "http://127.0.0.1:9",
            "https_proxy": "http://127.0.0.1:9",
            "http_proxy": "http://127.0.0.1:9",
            "NO_PROXY": "127.0.0.1,localhost",
            "no_proxy": "127.0.0.1,localhost",
            "MODEL_CATALOG_URL": "off",
        ]
        process.currentDirectoryURL = caseDirectory
        process.standardInput = FileHandle.nullDevice
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        try process.run()
        process.waitUntilExit()
        try stdoutHandle.close()
        try stderrHandle.close()
        defer { stopAll(under: root) }

        let stdout = try String(contentsOf: stdoutURL, encoding: .utf8)
        let stderr = try String(contentsOf: stderrURL, encoding: .utf8)
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        guard process.terminationStatus == 0 else { return }

        let result = try DeploymentExecutor().parseResult(stdout)
        XCTAssertNotNil(result.packEngineKeyFingerprint)

        // The gateway answers /healthz on its admin port with the bundled version.
        let health = try await get("http://127.0.0.1:\(ports[1])/healthz")
        XCTAssertEqual(health.status, 200)
        let healthJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: health.body) as? [String: Any])
        XCTAssertEqual(healthJSON["ok"] as? Bool, true)
        XCTAssertEqual(healthJSON["version"] as? String, GatewayBundle.bundled.version)
        // Split mode: the API port serves /v1 only.
        let apiHealth = try await get("http://127.0.0.1:\(ports[0])/healthz")
        XCTAssertEqual(apiHealth.status, 404)
        // The admin API accepts the management key; host status shows the pinned versions.
        let status = try await get("http://127.0.0.1:\(ports[1])/cpa-admin/host/status", managementKey: result.cpaManagementKey)
        XCTAssertEqual(status.status, 200)
        let statusText = String(decoding: status.body, as: UTF8.self)
        XCTAssertTrue(statusText.contains(DeploymentPinSet.current.engine.tag), statusText.prefix(300).description)
        XCTAssertTrue(statusText.contains(DeploymentPinSet.current.cpamp.tag))
        // The engine on its own port with the same key; CPA Manager Plus is healthy.
        let engine = try await get("http://127.0.0.1:\(ports[2])/v0/management/config", bearer: result.cpaManagementKey)
        XCTAssertEqual(engine.status, 200)
        let panel = try await get("http://127.0.0.1:\(ports[3])/health")
        XCTAssertEqual(panel.status, 200)

        // Bootstrap really ran: the gateway data directory and both pack keys, all private.
        for path in ["gateway-data/permissions.json", "secrets/pack-engine-key", "secrets/pack-store-key"] {
            let attributes = try fileManager.attributesOfItem(atPath: root.appendingPathComponent(path).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, path)
        }
        // No generated key in any process argument (ps), in the deployment log or in curl's argv.
        let keys = try ["cpa-management-key", "cpamp-admin-key", "pack-engine-key", "pack-store-key"].map {
            try String(contentsOf: root.appendingPathComponent("secrets/\($0)"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let processList = try run("/bin/ps", ["-axww", "-o", "command="])
        let log = try String(contentsOf: root.appendingPathComponent("logs/deployment.log"), encoding: .utf8)
        let argv = try String(contentsOf: argvLog, encoding: .utf8)
        for (index, key) in keys.enumerated() {
            XCTAssertFalse(processList.contains(key), "ps shows key #\(index)")
            XCTAssertFalse(log.contains(key), "deployment.log holds key #\(index)")
            XCTAssertFalse(argv.contains(key), "curl argv holds key #\(index)")
        }
        // The three processes run from the install root (ownership check of the scripts).
        let rootPath = root.path
        XCTAssertTrue(processList.contains("\(rootPath)/node/current/bin/node \(rootPath)/gateway/current/server.mjs"))
        XCTAssertTrue(processList.contains("\(rootPath)/cli-proxy-api/runtime/"))
        XCTAssertTrue(processList.contains("\(rootPath)/cpamp/runtime/"))
    }

    /// The same real packages: install, then the app's real upgrade (same pins, so the guard
    /// lets it through) and rollback, plus the migration's inline api-keys script against the
    /// real engine and the real Node 24 (`fetch`, GET/PUT/GET of `/v0/management/api-keys`).
    func testRealUpgradeRollbackAndApiKeysScript() async throws {
        guard let artifacts = ProcessInfo.processInfo.environment["OASES_E2E_REAL_ARTIFACTS"], !artifacts.isEmpty else {
            throw XCTSkip("set OASES_E2E_REAL_ARTIFACTS to a directory with the pinned packages")
        }
        let drill = try RealDrill(artifacts: artifacts)
        let ports = try freePorts(4)
        let scriptPorts = DeploymentScriptPorts(gatewayAPI: ports[0], gatewayAdmin: ports[1], engine: ports[2], cpamp: ports[3])
        let pins = try DeploymentPinSet.current.deployable()
        defer { stopAll(under: drill.root) }

        let install = try drill.run(DeploymentExecutor().scriptForVerification(
            method: .native, installDirectory: drill.root.path, pins: pins, ports: scriptPorts
        ), name: "install")
        XCTAssertEqual(install.status, 0, install.stderr)
        guard install.status == 0 else { return }
        let managementKey = try DeploymentExecutor().parseResult(install.stdout).cpaManagementKey
        let permissionsBefore = try Data(contentsOf: drill.root.appendingPathComponent("gateway-data/permissions.json"))

        // Upgrade with the same pins: stop, back up (gateway-data included), reinstall, restart.
        let maintenance = DeploymentMaintenanceService()
        let upgrade = try drill.run(maintenance.upgradeScriptForVerification(
            method: .native, installDirectory: drill.root.path, pins: pins, ports: scriptPorts
        ), name: "upgrade")
        XCTAssertEqual(upgrade.status, 0, upgrade.stderr)
        XCTAssertTrue(upgrade.stdout.contains("OASES_CPA_TOPOLOGY=gateway"), upgrade.stdout)
        let backup = maintenance.parseResultForVerification(upgrade.stdout).backupName
        XCTAssertTrue(backup.hasPrefix("upgrade-"))
        XCTAssertEqual(try Data(contentsOf: drill.root.appendingPathComponent("backups/\(backup)/gateway-data/permissions.json")), permissionsBefore)
        let health = try await get("http://127.0.0.1:\(ports[1])/healthz")
        XCTAssertEqual(health.status, 200)
        XCTAssertTrue(String(decoding: health.body, as: UTF8.self).contains("\"version\":\"\(GatewayBundle.bundled.version)\""))

        // The migration's api-keys script with a synthetic extra key, against the real engine.
        let drillKey = "oases-int-drill-\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
        let node = Process()
        node.executableURL = drill.root.appendingPathComponent("node/current/bin/node")
        node.arguments = ["-e", DeploymentMaintenanceService.apiKeysMigrationScript]
        node.environment = drill.environment.merging([
            "OASES_ENGINE_URL": "http://127.0.0.1:\(ports[2])",
            "OASES_MANAGEMENT_KEY": managementKey,
            "PACK_ENGINE_KEY": drillKey,
        ]) { $1 }
        let nodeOutput = Pipe()
        node.standardOutput = nodeOutput
        node.standardError = nodeOutput
        try node.run()
        let nodeText = String(decoding: nodeOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        node.waitUntilExit()
        XCTAssertEqual(node.terminationStatus, 0, nodeText)
        XCTAssertFalse(nodeText.contains(managementKey))
        XCTAssertFalse(nodeText.contains(drillKey))
        let keys = try await get("http://127.0.0.1:\(ports[2])/v0/management/api-keys", bearer: managementKey)
        XCTAssertEqual(keys.status, 200)
        let list = try XCTUnwrap((JSONSerialization.jsonObject(with: keys.body) as? [String: Any])?["api-keys"] as? [String])
        let packKey = try String(contentsOf: drill.root.appendingPathComponent("secrets/pack-engine-key"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(list.contains(drillKey))
        XCTAssertTrue(list.contains(packKey), "the existing key was kept")
        let config = try String(contentsOf: drill.root.appendingPathComponent("cli-proxy-api/config.yaml"), encoding: .utf8)
        XCTAssertTrue(config.contains("\napi-keys:\n"), "the engine kept the top-level api-keys layout (R14)")
        XCTAssertTrue(config.contains(drillKey), "the engine persisted the PUT")

        // Rollback: config.yaml (without the drill key) and gateway-data come back from the backup.
        let rollback = try drill.run(maintenance.rollbackScriptForVerification(
            method: .native, installDirectory: drill.root.path, ports: scriptPorts
        ), name: "rollback")
        XCTAssertEqual(rollback.status, 0, rollback.stderr)
        XCTAssertTrue(rollback.stdout.contains("OASES_CPA_TOPOLOGY=gateway"))
        XCTAssertEqual(try Data(contentsOf: drill.root.appendingPathComponent("gateway-data/permissions.json")), permissionsBefore)
        let restoredConfig = try Data(contentsOf: drill.root.appendingPathComponent("cli-proxy-api/config.yaml"))
        XCTAssertFalse(String(decoding: restoredConfig, as: UTF8.self).contains(drillKey))
        let healthAfter = try await get("http://127.0.0.1:\(ports[1])/healthz")
        XCTAssertEqual(healthAfter.status, 200)
        let engine = try await get("http://127.0.0.1:\(ports[2])/v0/management/config", bearer: managementKey)
        XCTAssertEqual(engine.status, 200)

        let processList = try run("/bin/ps", ["-axww", "-o", "command="])
        for name in ["cpa-management-key", "cpamp-admin-key", "pack-engine-key", "pack-store-key"] {
            let key = try String(contentsOf: drill.root.appendingPathComponent("secrets/\(name)"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(processList.contains(key), "ps shows \(name)")
            XCTAssertFalse(drill.argv().contains(key), "curl argv holds \(name)")
        }
    }

    /// A scratch case for the real drills: install root, HOME, the curl shim, no egress.
    private struct RealDrill {
        let caseDirectory: URL
        let root: URL
        let argvLog: URL
        let environment: [String: String]

        init(artifacts: String) throws {
            let fileManager = FileManager.default
            caseDirectory = FakeArtifacts.scratchRoot.appendingPathComponent("real-upgrade-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try fileManager.createDirectory(at: caseDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let bin = caseDirectory.appendingPathComponent("bin")
            let home = caseDirectory.appendingPathComponent("home")
            for directory in [bin, home] {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            root = caseDirectory.appendingPathComponent("root")
            argvLog = caseDirectory.appendingPathComponent("curl-argv.log")
            fileManager.createFile(atPath: argvLog.path, contents: Data())
            try Data(#"""
            #!/bin/bash
            line='curl'; for arg in "$@"; do line="$line $arg"; done
            printf '%s\n' "$line" >> "$E2E_ARGV_LOG"
            url=""; out=""; prev=""
            for arg in "$@"; do
              if [ "$prev" = "-o" ]; then out="$arg"; fi
              case "$arg" in https://*) url="$arg" ;; esac
              prev="$arg"
            done
            case "$url" in
              https://github.com/*/releases/download/*|https://nodejs.org/dist/*)
                exec cp "$E2E_ARTIFACTS/$(basename "$url")" "$out" ;;
              https://*) echo "e2e: refused $url" >&2; exit 7 ;;
            esac
            exec /usr/bin/curl "$@"
            """#.utf8).write(to: bin.appendingPathComponent("curl"))
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("curl").path)
            environment = [
                "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": home.path,
                "TMPDIR": caseDirectory.path,
                "LC_ALL": "C",
                "E2E_ARGV_LOG": argvLog.path,
                "E2E_ARTIFACTS": artifacts,
                "HTTPS_PROXY": "http://127.0.0.1:9",
                "HTTP_PROXY": "http://127.0.0.1:9",
                "https_proxy": "http://127.0.0.1:9",
                "http_proxy": "http://127.0.0.1:9",
                "NO_PROXY": "127.0.0.1,localhost",
                "no_proxy": "127.0.0.1,localhost",
                "MODEL_CATALOG_URL": "off",
            ]
        }

        func run(_ script: String, name: String) throws -> (status: Int32, stdout: String, stderr: String) {
            let scriptURL = caseDirectory.appendingPathComponent("\(name).sh")
            let stdoutURL = caseDirectory.appendingPathComponent("\(name).stdout")
            let stderrURL = caseDirectory.appendingPathComponent("\(name).stderr")
            try Data(script.utf8).write(to: scriptURL)
            FileManager.default.createFile(atPath: stdoutURL.path, contents: Data())
            FileManager.default.createFile(atPath: stderrURL.path, contents: Data())
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [scriptURL.path]
            process.environment = environment
            process.currentDirectoryURL = caseDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            try process.run()
            process.waitUntilExit()
            try stdoutHandle.close()
            try stderrHandle.close()
            return (process.terminationStatus,
                    (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "",
                    (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "")
        }

        func argv() -> String {
            (try? String(contentsOf: argvLog, encoding: .utf8)) ?? ""
        }
    }

    // MARK: - Helpers

    private func stopAll(under root: URL) {
        var pids: [Int32] = []
        for name in DeploymentScriptFragments.managedProcesses(topology: .gateway).reversed().map(\.pidFile) {
            if let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 {
                pids.append(pid)
                kill(pid, SIGTERM)
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, pids.contains(where: { kill($0, 0) == 0 }) { usleep(100_000) }
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    private func freePorts(_ count: Int) throws -> [Int] {
        var ports: [Int] = []
        var sockets: [Int32] = []
        defer { sockets.forEach { close($0) } }
        while ports.count < count {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw NSError(domain: "e2e", code: 1) }
            sockets.append(fd)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
            }
            guard bound == 0 else { throw NSError(domain: "e2e", code: 2) }
            _ = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            let port = Int(UInt16(bigEndian: address.sin_port))
            if !ports.contains(port), ![8317, 18316, 18317, 18320].contains(port) { ports.append(port) }
        }
        return ports
    }

    private func get(_ url: String, managementKey: String? = nil, bearer: String? = nil) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        if let managementKey { request.setValue(managementKey, forHTTPHeaderField: "x-management-key") }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await SecretBearingURLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
