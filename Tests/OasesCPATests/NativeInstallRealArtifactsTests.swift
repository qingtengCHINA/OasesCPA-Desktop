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

    /// The 0.1.x → full edition migration with the REAL pinned engine, CPA Manager Plus, Node and
    /// the bundled gateway, on a realistic 0.1.x fixture (`docs/acceptance/legacy-migration-drill.md`):
    /// the legacy marker only, engine v7.2.113 and CPA Manager Plus v1.11.11 as small stubs (no
    /// old packages exist here) that answer the health checks, a legacy `config.yaml` with the
    /// owner's top-level keys (bcrypt `secret-key`, two client keys, one openai-compatibility
    /// provider pointing at a loopback mock upstream), two auth files, and CPA Manager Plus data
    /// with an older `usage_events` schema, rows in the WAL, data.key and an import. Every port is
    /// a random free loopback port, the legacy engine port included; the fixed ports' listeners
    /// must be the same before and after. Upgrade, the checks through the gateway, then rollback
    /// and a byte-for-byte comparison. A masked summary goes to `legacy-drill-summary.md` in the
    /// case directory.
    func testRealLegacyMigrationAndRollback() async throws {
        guard let artifacts = ProcessInfo.processInfo.environment["OASES_E2E_REAL_ARTIFACTS"], !artifacts.isEmpty else {
            throw XCTSkip("set OASES_E2E_REAL_ARTIFACTS to a directory with the pinned packages")
        }
        let fileManager = FileManager.default
        let drill = try RealDrill(artifacts: artifacts)
        let root = drill.root
        var notes: [String] = []
        func note(_ line: String) {
            notes.append(line
                .replacingOccurrences(of: root.path, with: "<install>")
                .replacingOccurrences(of: drill.caseDirectory.path, with: "<scratch>"))
        }
        let fixedBefore = try fixedPortListeners()
        let free = try freePorts(6)
        let ports = DeploymentScriptPorts(gatewayAPI: free[0], gatewayAdmin: free[1], engine: free[2], cpamp: free[3], legacyEngine: free[4])
        let upstreamPort = free[5]
        let pins = try DeploymentPinSet.current.deployable()
        var helpers: [Process] = []
        defer {
            stopAll(under: root)
            for helper in helpers where helper.isRunning { helper.terminate() }
        }

        // Node for the stubs and the mock upstream: the pinned package, unpacked next to the root.
        let stubNodeDirectory = drill.caseDirectory.appendingPathComponent("stub-node", isDirectory: true)
        try fileManager.createDirectory(at: stubNodeDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let nodeAsset = try XCTUnwrap(pins.node.assets[.darwinARM64]?.fileName)
        XCTAssertEqual(try run("/usr/bin/tar", ["-xzf", "\(artifacts)/\(nodeAsset)", "--strip-components", "1", "-C", stubNodeDirectory.path]), "")
        let stubNode = stubNodeDirectory.appendingPathComponent("bin/node").path
        let stubScript = drill.caseDirectory.appendingPathComponent("legacy-stub.cjs")
        try Data(Self.legacyStubScript.utf8).write(to: stubScript)

        // --- The 0.1.x fixture. ---
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        func put(_ text: String, _ relative: String, mode: Int = 0o600) throws {
            let url = root.appendingPathComponent(relative)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(text.utf8).write(to: url)
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        func hex(_ count: Int) -> String {
            (0..<count).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        }
        let managementKey = "cpa_\(hex(32))"
        let userKeys = ["sk-drill-\(hex(12))", "sk-drill-\(hex(12))"]
        try put("", ".oases-cpa-installed", mode: 0o644)
        try put(managementKey + "\n", "secrets/cpa-management-key")
        try put("cpamp_\(hex(32))\n", "secrets/cpamp-admin-key")
        let enginePackage = "cli-proxy-api/runtime/CLIProxyAPI_7.2.113_darwin_aarch64"
        let stubWrapper = { (mode: String) in """
            #!/bin/bash
            # Stub of the 0.1.x \(mode) for the migration drill (no old packages here).
            child=""
            trap 'kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 0' TERM INT
            config=""; previous=""
            for argument in "$@"; do [ "$previous" = "-config" ] && config="$argument"; previous="$argument"; done
            '\(stubNode)' '\(stubScript.path)' \(mode) "${config:-$PWD/config.json}" &
            child=$!
            wait "$child"

            """ }
        try put(stubWrapper("engine"), "\(enginePackage)/cli-proxy-api", mode: 0o755)
        try put("#!/bin/bash\nset -euo pipefail\ncd \"\(root.path)/cli-proxy-api\"\nexec \"\(root.path)/\(enginePackage)/cli-proxy-api\" -config \"\(root.path)/cli-proxy-api/config.yaml\"\n",
                "cli-proxy-api/run.sh", mode: 0o755)
        let bcrypt = try bcryptHash(managementKey)
        note("- `secret-key` in the legacy config: \(bcrypt.hasPrefix("$2") ? "a bcrypt hash (htpasswd -B, as a running 0.1.x engine leaves it)" : "plaintext (htpasswd unavailable)")")
        let legacyConfig = """
        host: "127.0.0.1"
        port: \(ports.legacyEngine)
        remote-management:
          allow-remote: false
          secret-key: "\(bcrypt)"
        auth-dir: "\(root.path)/cli-proxy-api/auths"
        api-keys:
          - "\(userKeys[0])"
          - "\(userKeys[1])"
        usage-statistics-enabled: true
        credential-concurrency: {}
        credential-in-flight: {}
        redis-usage-queue-retention-seconds: 3600
        ws-auth: false
        openai-compatibility:
          - name: "drill-mock"
            base-url: "http://127.0.0.1:\(upstreamPort)/v1"
            api-key-entries:
              - api-key: "sk-upstream-\(hex(8))"
            models:
              - name: "drill-upstream-model"
                alias: "drill-model"

        """
        try put(legacyConfig, "cli-proxy-api/config.yaml")
        let farFuture = "2099-01-01T00:00:00Z"
        try put("{\"type\":\"codex\",\"label\":\"drill-codex\",\"access_token\":\"drill-\(hex(16))\",\"refresh_token\":\"drill-\(hex(16))\",\"expired\":\"\(farFuture)\",\"disabled\":false}\n",
                "cli-proxy-api/auths/codex-drill.json")
        try put("{\"type\":\"claude\",\"label\":\"drill-claude\",\"access_token\":\"drill-\(hex(16))\",\"refresh_token\":\"drill-\(hex(16))\",\"expired\":\"\(farFuture)\",\"disabled\":false}\n",
                "cli-proxy-api/auths/claude-drill.json")
        try put("synthetic stand-in for the 0.1.x engine download\n", "cli-proxy-api/downloads/CLIProxyAPI_7.2.113_darwin_aarch64.tar.gz")
        try fileManager.createDirectory(at: root.appendingPathComponent("cli-proxy-api/logs"), withIntermediateDirectories: true)
        let panelPackage = "cpamp/runtime/cpa-manager-plus_v1.11.11_darwin_arm64"
        try put(stubWrapper("panel"), "\(panelPackage)/cpa-manager-plus", mode: 0o755)
        try put("{\"httpAddr\":\"127.0.0.1:\(ports.cpamp)\",\"cpaUpstreamUrl\":\"http://127.0.0.1:\(ports.legacyEngine)\",\"dataDir\":\"../../data\"}\n",
                "\(panelPackage)/config.json")
        try put("#!/bin/bash\nset -euo pipefail\ncd \"\(root.path)/\(panelPackage)\"\nexec \"\(root.path)/\(panelPackage)/cpa-manager-plus\"\n", "cpamp/run.sh", mode: 0o755)
        try put("synthetic stand-in for the 0.1.x panel download\n", "cpamp/downloads/cpa-manager-plus_v1.11.11_darwin_arm64.tar.gz")
        var keyBytes = [UInt8](repeating: 0, count: 32)
        for index in keyBytes.indices { keyBytes[index] = UInt8.random(in: 0...255) }
        try put(Data(keyBytes).base64EncodedString().replacingOccurrences(of: "=", with: "") + "\n", "cpamp/data/data.key")
        try put("{\"source\":\"drill\",\"rows\":3}\n", "cpamp/data/usage-imports/import-drill.json")
        try makeLegacyUsageDatabase(in: root.appendingPathComponent("cpamp/data"), scratch: drill.caseDirectory)
        for log in ["logs/cli-proxy-api.log", "logs/cpa-manager-plus.log"] { try put("", log, mode: 0o644) }

        // The mock upstream for the openai-compatibility provider.
        let upstream = Process()
        upstream.executableURL = URL(fileURLWithPath: stubNode)
        upstream.arguments = [stubScript.path, "upstream", String(upstreamPort)]
        upstream.environment = drill.environment
        upstream.standardOutput = FileHandle.nullDevice
        upstream.standardError = FileHandle.nullDevice
        try upstream.run()
        helpers.append(upstream)

        // Start the 0.1.x deployment with the app's own start script.
        let start = try drill.run(RuntimeLifecycleService().startScriptForVerification(method: .native, installDirectory: root.path), name: "legacy-start")
        XCTAssertEqual(start.status, 0, start.stderr)
        let legacyModels = try await waitFor("http://127.0.0.1:\(ports.legacyEngine)/v1/models", bearer: userKeys[0])
        XCTAssertEqual(legacyModels.status, 200, "the stub 0.1.x engine answers")

        let configBefore = try Data(contentsOf: root.appendingPathComponent("cli-proxy-api/config.yaml"))
        let authsBefore = try snapshot(root.appendingPathComponent("cli-proxy-api/auths"))
        let panelDataBefore = try snapshot(root.appendingPathComponent("cpamp/data"))
        let secretsBefore = try snapshot(root.appendingPathComponent("secrets"))
        XCTAssertEqual(Set(panelDataBefore.keys), ["data.key", "usage.sqlite", "usage.sqlite-wal", "usage.sqlite-shm", "usage-imports/import-drill.json"])
        note("- fixture: legacy marker only, stubs running (pid files written by the app's start script), `cpamp/data` = \(panelDataBefore.keys.sorted().joined(separator: ", "))")

        // --- Upgrade (the app's native upgrade script, legacy branch). ---
        let maintenance = DeploymentMaintenanceService()
        let started = Date()
        let upgrade = try drill.run(maintenance.upgradeScriptForVerification(
            method: .native, installDirectory: root.path, pins: pins, ports: ports
        ), name: "upgrade")
        note("- upgrade: exit \(upgrade.status) in \(Int(Date().timeIntervalSince(started))) s; result lines: \(upgrade.stdout.split(separator: "\n").filter { $0.hasPrefix("OASES_") }.compactMap { $0.split(separator: "=").first.map(String.init) }.joined(separator: ", "))")
        XCTAssertEqual(upgrade.status, 0, upgrade.stderr)
        guard upgrade.status == 0 else {
            try writeSummary(notes, drill)
            return
        }
        let result = maintenance.parseResultForVerification(upgrade.stdout)
        XCTAssertEqual(result.topology, .gateway)
        let backup = root.appendingPathComponent("backups/\(result.backupName)")
        XCTAssertEqual(try snapshot(backup.appendingPathComponent("cpamp-data")), panelDataBefore, "backup: cpamp/data byte for byte")
        XCTAssertEqual(try snapshot(backup.appendingPathComponent("secrets")), secretsBefore, "backup: secrets")
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("cli-proxy-api-config.yaml")), configBefore, "backup: config.yaml")
        XCTAssertEqual(mode(backup), 0o700)
        let backupItems = try fileManager.contentsOfDirectory(atPath: backup.path).sorted()
        note("- backup `backups/upgrade-<time>/` (mode \(String(mode(backup), radix: 8))): \(backupItems.joined(separator: ", ")); root-files: \(((try? fileManager.contentsOfDirectory(atPath: backup.appendingPathComponent("root-files").path)) ?? []).sorted().joined(separator: ", "))")

        // The config stays in the legacy layout (R14) with the users' keys plus the internal one.
        let config = try String(contentsOf: root.appendingPathComponent("cli-proxy-api/config.yaml"), encoding: .utf8)
        let packKey = try String(contentsOf: root.appendingPathComponent("secrets/pack-engine-key"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(config.contains("\napi-keys:\n"), "top-level api-keys")
        XCTAssertTrue(config.contains("\nopenai-compatibility:\n"), "top-level openai-compatibility")
        XCTAssertTrue(config.contains("port: \(ports.engine)\n"))
        XCTAssertFalse(config.contains("config-version"))
        for key in userKeys { XCTAssertTrue(config.contains(key), "a user key survived") }
        XCTAssertTrue(config.contains(packKey), "the gateway's internal key was added")
        XCTAssertTrue(config.contains("drill-mock"), "the provider survived")
        let topLevel = config.split(separator: "\n").filter { $0.first.map { $0.isLetter } == true }.compactMap { $0.split(separator: ":").first.map(String.init) }
        note("- config.yaml after the upgrade: top-level keys \(topLevel.joined(separator: " ")); both client keys and the internal key under `api-keys`, provider `drill-mock` kept")
        XCTAssertEqual(try snapshot(root.appendingPathComponent("cli-proxy-api/auths")), authsBefore, "auth files byte for byte")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".oases-cpa-managed"), encoding: .utf8), "owned-by=oases-cpa\n")
        note("- `.oases-cpa-managed` written (mode \(String(mode(root.appendingPathComponent(".oases-cpa-managed")), radix: 8))); auth files byte for byte equal")

        // Order of the processes (start times) and their command lines.
        let startTimes = try ["cli-proxy-api.pid", "cpa-manager-plus.pid", "gateway.pid"].map { name -> String in
            let pid = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            return try run("/bin/ps", ["-o", "lstart=", "-p", pid]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        note("- start times engine / CPA Manager Plus / gateway: \(startTimes.joined(separator: " | "))")
        let health = try await get("http://127.0.0.1:\(ports.gatewayAdmin)/healthz")
        XCTAssertEqual(health.status, 200)
        note("- `GET /healthz` (admin port): \(health.status) `\(String(decoding: health.body, as: UTF8.self))`")
        let models = try await get("http://127.0.0.1:\(ports.gatewayAPI)/v1/models", bearer: userKeys[0])
        let modelsText = String(decoding: models.body, as: UTF8.self)
        XCTAssertEqual(models.status, 200, modelsText.prefix(300).description)
        XCTAssertTrue(modelsText.contains("drill-model"), modelsText.prefix(300).description)
        note("- `GET /v1/models` through the gateway with an existing client key: \(models.status), lists `drill-model`: \(modelsText.contains("drill-model"))")
        let chat = try await post("http://127.0.0.1:\(ports.gatewayAPI)/v1/chat/completions", bearer: userKeys[1],
                                  json: #"{"model":"drill-model","messages":[{"role":"user","content":"ping"}]}"#)
        let chatText = String(decoding: chat.body, as: UTF8.self)
        note("- `POST /v1/chat/completions` (model `drill-model`) through the gateway with the second client key: \(chat.status), mock answer present: \(chatText.contains("drill-ok"))")
        let panel = try await get("http://127.0.0.1:\(ports.cpamp)/health")
        XCTAssertEqual(panel.status, 200)
        // CPA Manager Plus v1.14.10 migrated the older usage_events schema and kept the rows.
        let database = root.appendingPathComponent("cpamp/data/usage.sqlite").path
        let rows = try run("/usr/bin/sqlite3", ["-readonly", database, "select count(*) from usage_events where event_hash like 'drill-%';"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let columns = try run("/usr/bin/sqlite3", ["-readonly", database, "select name from pragma_table_info('usage_events');"])
        let tables = try run("/usr/bin/sqlite3", ["-readonly", database, "select count(*) from sqlite_master where type='table';"]).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(rows, "3")
        note("- CPA Manager Plus `/health` \(panel.status); `usage.sqlite` after its start: \(rows) drill rows, `account_snapshot` column added: \(columns.contains("account_snapshot")), tables: \(tables)")

        // --- Rollback. ---
        let rollback = try drill.run(maintenance.rollbackScriptForVerification(method: .native, installDirectory: root.path, ports: ports), name: "rollback")
        note("- rollback: exit \(rollback.status); `OASES_CPA_TOPOLOGY=legacy`: \(rollback.stdout.contains("OASES_CPA_TOPOLOGY=legacy"))")
        XCTAssertEqual(rollback.status, 0, rollback.stderr)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("cli-proxy-api/config.yaml")), configBefore, "config.yaml byte for byte")
        XCTAssertEqual(try snapshot(root.appendingPathComponent("cli-proxy-api/auths")), authsBefore)
        XCTAssertEqual(try snapshot(root.appendingPathComponent("cpamp/data")), panelDataBefore, "cpamp/data byte for byte")
        XCTAssertEqual(try snapshot(root.appendingPathComponent("secrets")), secretsBefore)
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent(".oases-cpa-managed").path))
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent("gateway.pid").path))
        let legacyAgain = try await waitFor("http://127.0.0.1:\(ports.legacyEngine)/v1/models", bearer: userKeys[1])
        XCTAssertEqual(legacyAgain.status, 200)
        let after = try snapshot(backup.appendingPathComponent("cpamp-data-after-upgrade"))
        note("- after the rollback: config.yaml, auths/, cpamp/data/ (\(panelDataBefore.count) files) and secrets/ equal the pre-upgrade bytes; the migrated database is kept in the backup (`cpamp-data-after-upgrade/`, \(after.count) files); no `.oases-cpa-managed`, no gateway.pid; the stub 0.1.x engine answers `/v1/models` \(legacyAgain.status)")

        stopAll(under: root)
        upstream.terminate()
        upstream.waitUntilExit()
        let leftovers = try run("/bin/ps", ["-axww", "-o", "command="]).split(separator: "\n").filter { $0.contains(drill.caseDirectory.path) }
        XCTAssertEqual(leftovers, [], "nothing of the drill runs any more")
        let fixedAfter = try fixedPortListeners()
        XCTAssertEqual(fixedAfter, fixedBefore, "the fixed ports' listeners are unchanged")
        note("- fixed ports 8317/18316/18317/18320: the same listeners before and after (\(fixedBefore.isEmpty ? "none" : "\(fixedBefore.count) other process(es), never touched")); nothing of the drill runs afterwards")
        try writeSummary(notes, drill)
    }

    /// The stubs of the 0.1.x engine and CPA Manager Plus and the mock upstream (Node, no deps).
    private static let legacyStubScript = #"""
    const http = require("http");
    const fs = require("fs");
    const path = require("path");
    const [mode, target] = process.argv.slice(2);
    function send(res, status, body) {
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify(body));
    }
    function bearer(req) {
      const value = req.headers["authorization"] || "";
      return value.startsWith("Bearer ") ? value.slice(7) : "";
    }
    if (mode === "upstream") {
      http.createServer((req, res) => {
        let body = "";
        req.on("data", (chunk) => { body += chunk; });
        req.on("end", () => {
          if (req.url.endsWith("/models")) return send(res, 200, { object: "list", data: [{ id: "drill-upstream-model", object: "model" }] });
          if (req.url.endsWith("/chat/completions")) {
            return send(res, 200, { id: "chatcmpl-drill", object: "chat.completion", created: Math.floor(Date.now() / 1000), model: "drill-upstream-model",
              choices: [{ index: 0, message: { role: "assistant", content: "drill-ok" }, finish_reason: "stop" }],
              usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 } });
          }
          send(res, 404, { error: "not found" });
        });
      }).listen(Number(target), "127.0.0.1");
    } else if (mode === "engine") {
      const text = fs.readFileSync(target, "utf8");
      const port = Number((text.match(/^port:\s*(\d+)\s*$/m) || [])[1]);
      const root = path.dirname(path.dirname(target));
      const managementKey = fs.readFileSync(path.join(root, "secrets", "cpa-management-key"), "utf8").trim();
      const keys = [];
      let inKeys = false;
      for (const line of text.split("\n")) {
        if (/^api-keys:/.test(line)) { inKeys = true; continue; }
        if (inKeys && /^\s+-\s/.test(line)) { keys.push(line.replace(/^\s+-\s*/, "").replace(/^"|"$/g, "")); continue; }
        if (inKeys && /^\S/.test(line)) inKeys = false;
      }
      http.createServer((req, res) => {
        if (req.url.startsWith("/v0/management/")) return bearer(req) === managementKey ? send(res, 200, { stub: "0.1.x" }) : send(res, 401, { error: "unauthorized" });
        if (req.url.startsWith("/v1/models")) return keys.includes(bearer(req)) ? send(res, 200, { object: "list", data: [{ id: "drill-model" }] }) : send(res, 401, { error: "unauthorized" });
        send(res, 404, { error: "not found" });
      }).listen(port, "127.0.0.1");
    } else if (mode === "panel") {
      const config = JSON.parse(fs.readFileSync(target, "utf8"));
      const port = Number(String(config.httpAddr).split(":").pop());
      http.createServer((req, res) => (req.url === "/health" ? send(res, 200, { status: "ok", stub: "0.1.x" }) : send(res, 404, {}))).listen(port, "127.0.0.1");
    }
    process.on("SIGTERM", () => process.exit(0));
    """#

    /// `usage.sqlite` as an older CPA Manager Plus leaves it: `usage_events` without the
    /// account-snapshot columns that v1.14 adds, three rows still in the WAL (copied, with
    /// -wal and -shm, while the writing connection is open).
    private func makeLegacyUsageDatabase(in directory: URL, scratch: URL) throws {
        let work = scratch.appendingPathComponent("sqlite-work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let database = work.appendingPathComponent("usage.sqlite").path
        var rows = ""
        for index in 1...3 {
            let ms = 1_794_000_000_000 + index * 60_000
            rows += "insert into usage_events (request_id, event_hash, timestamp_ms, timestamp, provider, executor_type, model, endpoint, method, path, auth_type, auth_index, source, requested_model, resolved_model, input_tokens, output_tokens, total_tokens, failed, created_at_ms) values ('req-drill-\(index)', 'drill-\(index)', \(ms), '2026-11-08T00:0\(index):00Z', 'openai-compatible-drill-mock', 'OpenAICompatExecutor', 'drill-model', '/v1/chat/completions', 'POST', '/v1/chat/completions', 'api_key', 'drill-\(index)', 'drill-mock', 'drill-model', 'drill-upstream-model', \(10 * index), \(5 * index), \(15 * index), 0, \(ms));\n"
        }
        let sql = """
        pragma journal_mode = WAL;
        pragma wal_autocheckpoint = 0;
        create table usage_events (id integer primary key autoincrement, request_id text, event_hash text not null unique, timestamp_ms integer not null, timestamp text not null, provider text, executor_type text, model text not null, endpoint text, method text, path text, auth_type text, auth_index text, source text, source_hash text, api_key_hash text, requested_model text, resolved_model text, reasoning_effort text, service_tier text, request_service_tier text, response_service_tier text, cache_input_mode text, input_tokens integer not null default 0, output_tokens integer not null default 0, reasoning_tokens integer not null default 0, cached_tokens integer not null default 0, cache_tokens integer not null default 0, cache_read_tokens integer not null default 0, cache_creation_tokens integer not null default 0, normalized_uncached_input_tokens integer, normalized_total_input_tokens integer, normalized_cache_read_tokens integer, normalized_cache_creation_tokens integer, total_tokens integer not null default 0, latency_ms integer, ttft_ms integer, failed integer not null default 0, fail_status_code integer, fail_summary text, response_metadata_json text, header_quota_recover_at_ms integer, header_quota_used_percent real, header_quota_plan_type text, header_error_kind text, header_error_code text, header_trace_id text, fail_body text, raw_json text, created_at_ms integer not null);
        \(rows)
        .system cp '\(database)' '\(database)-wal' '\(database)-shm' '\(directory.path)/'
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(sql.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        for name in ["usage.sqlite", "usage.sqlite-wal", "usage.sqlite-shm"] {
            let url = directory.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), name)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// A bcrypt hash of `secret` from `htpasswd -B` (password on stdin), `$2y$` written as the
    /// equivalent `$2a$`; plaintext when htpasswd is missing.
    private func bcryptHash(_ secret: String) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/htpasswd") else { return secret }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/htpasswd")
        process.arguments = ["-niBC", "10", "drill"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data((secret + "\n").utf8))
        try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard let hash = text.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespacesAndNewlines), hash.hasPrefix("$2") else { return secret }
        return hash.replacingOccurrences(of: "$2y$", with: "$2a$")
    }

    private func snapshot(_ directory: URL) throws -> [String: Data] {
        var files: [String: Data] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: directory.path) {
            var isDirectory: ObjCBool = false
            let url = directory.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            files[path] = try Data(contentsOf: url)
        }
        return files
    }

    private func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// `pid port` lines of whatever listens on the fixed deployment ports (read-only lsof).
    private func fixedPortListeners() throws -> [String] {
        let output = try run("/usr/sbin/lsof", ["-nP", "-iTCP:8317,18316,18317,18320", "-sTCP:LISTEN", "-Fpn"])
        var pid = ""
        var lines: [String] = []
        for line in output.split(separator: "\n") {
            if line.hasPrefix("p") { pid = String(line.dropFirst()) }
            if line.hasPrefix("n") { lines.append("\(pid) \(line.dropFirst())") }
        }
        return lines.sorted()
    }

    private func waitFor(_ url: String, bearer: String) async throws -> (status: Int, body: Data) {
        var last: (status: Int, body: Data) = (-1, Data())
        for _ in 0..<30 {
            if let answer = try? await get(url, bearer: bearer) {
                last = answer
                if answer.status == 200 { return answer }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        return last
    }

    private func post(_ url: String, bearer: String, json: String) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(json.utf8)
        let (data, response) = try await SecretBearingURLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    private func writeSummary(_ notes: [String], _ drill: RealDrill) throws {
        try Data((notes.joined(separator: "\n") + "\n").utf8).write(to: drill.caseDirectory.appendingPathComponent("legacy-drill-summary.md"))
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
