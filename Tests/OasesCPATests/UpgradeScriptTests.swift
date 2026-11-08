import XCTest
@testable import OasesCPA

/// The native and Docker upgrade and rollback scripts, run for real with `/bin/bash` against
/// deployments under `$OASES_SCRATCH` laid out by the real install script (or by hand, for the
/// app 0.1.x layout) with fake packages and fake tools (`FakeArtifacts`): no network, no real
/// binaries, no listening sockets, a scratch HOME.
final class UpgradeScriptTests: XCTestCase {
    private var startedRoots: [(FakeArtifacts, URL)] = []

    override func tearDown() {
        for (fake, root) in startedRoots { fake.stopProcesses(under: root) }
        startedRoots.removeAll()
        super.tearDown()
    }

    // MARK: - Helpers

    private let maintenance = DeploymentMaintenanceService()

    /// A gateway deployment installed and started by the real install script.
    private func installed(_ caseName: String, extraEnvironment: [String: String] = [:]) throws -> (FakeArtifacts, URL) {
        let fake = try FakeArtifacts.make(caseName: caseName)
        let root = fake.caseDirectory.appendingPathComponent("root", isDirectory: true)
        startedRoots.append((fake, root))
        let result = try fake.run(DeploymentExecutor().scriptForVerification(
            method: .native, installDirectory: root.path, pins: fake.pins, gatewayPayloadBase64: fake.gatewayPayloadBase64
        ), extraEnvironment: extraEnvironment)
        XCTAssertEqual(result.status, 0, result.stderr)
        return (fake, root)
    }

    private func upgrade(_ fake: FakeArtifacts, _ root: URL, prelude: String = "", extraEnvironment: [String: String] = [:]) throws -> FakeArtifacts.RunResult {
        try fake.run(maintenance.upgradeScriptForVerification(
            method: .native, installDirectory: root.path, pins: fake.pins,
            gatewayPayloadBase64: fake.gatewayPayloadBase64, healthAttempts: 3
        ), prelude: prelude, extraEnvironment: extraEnvironment)
    }

    private func rollback(_ fake: FakeArtifacts, _ root: URL, extraEnvironment: [String: String] = [:]) throws -> FakeArtifacts.RunResult {
        try fake.run(maintenance.rollbackScriptForVerification(method: .native, installDirectory: root.path, healthAttempts: 3),
                     extraEnvironment: extraEnvironment)
    }

    private func data(_ root: URL, _ relative: String) -> Data? {
        try? Data(contentsOf: root.appendingPathComponent(relative))
    }

    private func text(_ root: URL, _ relative: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)) ?? ""
    }

    private func write(_ text: String, _ root: URL, _ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func versions(_ root: URL) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(data(root, ".oases-cpa-versions"))) as? [String: String])
    }

    private func setVersion(_ component: String, _ value: String, _ root: URL) throws {
        var current = try versions(root)
        current[component] = value
        let body = ["engine", "cpamp", "node", "gateway"].compactMap { key in current[key].map { "  \"\(key)\": \"\($0)\"" } }
        try write("{\n" + body.joined(separator: ",\n") + "\n}\n", root, ".oases-cpa-versions")
    }

    private func link(_ root: URL, _ relative: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent(relative).path)
    }

    private func upgradeBackups(_ root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("backups").path)) ?? [])
            .filter { $0.hasPrefix("upgrade-") }.sorted()
    }

    private func pid(_ root: URL, _ name: String) -> Int32? {
        Int32(text(root, name).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The variables `gateway/run.sh` exports (only its `export` lines, in an empty environment).
    private func exportedEnvironment(_ root: URL) throws -> [String: String] {
        let lines = text(root, "gateway/run.sh").split(separator: "\n").filter { $0.hasPrefix("export ") }.joined(separator: "\n")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", lines + "\nenv"]
        process.environment = [:]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var values: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        for automatic in ["PWD", "SHLVL", "_", "OLDPWD"] { values[automatic] = nil }
        return values
    }

    /// The app 0.1.x layout: engine on 8317 with its config.yaml and a user's client key, CPA
    /// Manager Plus with its config.json inside the versioned runtime directory, no versions
    /// file, no Node, no gateway.
    private func legacyLayout(_ fake: FakeArtifacts, mode: Int = 0o700) throws -> URL {
        let root = fake.caseDirectory.appendingPathComponent("root", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: mode])
        try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: root.path)
        startedRoots.append((fake, root))
        try write("owned-by=oases-cpa\n", root, ".oases-cpa-managed")
        try write("", root, ".oases-cpa-installed")
        try write("cpa_\(String(repeating: "1f", count: 32))\n", root, "secrets/cpa-management-key")
        try write("cpamp_\(String(repeating: "2e", count: 32))\n", root, "secrets/cpamp-admin-key")
        try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: root.appendingPathComponent("secrets").path)
        let engine = root.appendingPathComponent("cli-proxy-api/runtime/CLIProxyAPI_7.2.141_darwin_aarch64/cli-proxy-api")
        try write(FakeArtifacts.fakeService(name: "cli-proxy-api"), root, "cli-proxy-api/runtime/CLIProxyAPI_7.2.141_darwin_aarch64/cli-proxy-api")
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: engine.path)
        try write("#!/bin/bash\nset -euo pipefail\ncd \"\(root.path)/cli-proxy-api\"\nexec \"\(engine.path)\" -config \"\(root.path)/cli-proxy-api/config.yaml\"\n",
                  root, "cli-proxy-api/run.sh")
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("cli-proxy-api/run.sh").path)
        try write(Self.legacyConfig(root: root), root, "cli-proxy-api/config.yaml")
        let panelDirectory = "cpamp/runtime/cpa-manager-plus_v1.11.10_darwin_arm64"
        let panel = root.appendingPathComponent("\(panelDirectory)/cpa-manager-plus")
        try write(FakeArtifacts.fakeService(name: "cpa-manager-plus"), root, "\(panelDirectory)/cpa-manager-plus")
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: panel.path)
        try write("{\"httpAddr\":\"127.0.0.1:18317\",\"cpaUpstreamUrl\":\"http://127.0.0.1:8317\",\"dataDir\":\"../../data\"}\n", root, "\(panelDirectory)/config.json")
        try write("#!/bin/bash\nset -euo pipefail\ncd \"\(root.path)/\(panelDirectory)\"\nexec \"\(panel.path)\"\n", root, "cpamp/run.sh")
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("cpamp/run.sh").path)
        try write("usage\n", root, "cpamp/data/usage.db")
        try fileManager.createDirectory(at: root.appendingPathComponent("logs"), withIntermediateDirectories: true)
        return root
    }

    static let legacyUserKey = "sk-user-legacy-0001"

    static func legacyConfig(root: URL) -> String {
        """
        host: "127.0.0.1"
        port: 8317

        remote-management:
          allow-remote: false
          secret-key: "cpa_\(String(repeating: "1f", count: 32))"

        auth-dir: "\(root.path)/cli-proxy-api/auths"
        api-keys:
          - "\(legacyUserKey)"
        usage-statistics-enabled: true

        """
    }

    // MARK: - No downgrade (10a)

    func testHigherInstalledComponentRefusesWithExit22BeforeStopping() throws {
        let (fake, root) = try installed("downgrade-engine")
        try setVersion("engine", "v9.0.0", root)
        let runScript = data(root, "cli-proxy-api/run.sh")
        let config = data(root, "cli-proxy-api/config.yaml")
        let pids = DeploymentScriptFragments.managedProcesses(topology: .gateway).compactMap { pid(root, $0.pidFile) }
        XCTAssertEqual(pids.count, 3)

        let result = try upgrade(fake, root)
        XCTAssertEqual(result.status, 22, result.stderr)
        XCTAssertTrue(result.stderr.contains("OASES_DOWNGRADE_REFUSED component=engine installed=v9.0.0 target=\(FakeArtifacts.engineTag)"), result.stderr)
        for pid in pids { XCTAssertEqual(kill(pid, 0), 0, "\(pid) still runs") }
        XCTAssertEqual(data(root, "cli-proxy-api/run.sh"), runScript)
        XCTAssertEqual(data(root, "cli-proxy-api/config.yaml"), config)
        XCTAssertEqual(upgradeBackups(root), [], "no backup was made")
        XCTAssertFalse(result.stdout.contains("OASES_CPA_BACKUP"))
    }

    func testEachComponentIsGuarded() throws {
        let (fake, root) = try installed("downgrade-each")
        let original = try XCTUnwrap(data(root, ".oases-cpa-versions"))
        for (component, higher) in [("cpamp", "v9.0.0"), ("node", "v99.0.0"), ("gateway", "9.0.0")] {
            try original.write(to: root.appendingPathComponent(".oases-cpa-versions"))
            try setVersion(component, higher, root)
            let result = try upgrade(fake, root)
            XCTAssertEqual(result.status, 22, "\(component): \(result.stderr)")
            XCTAssertTrue(result.stderr.contains("OASES_DOWNGRADE_REFUSED component=\(component) installed=\(higher) target="), result.stderr)
        }
        XCTAssertEqual(upgradeBackups(root), [])
    }

    func testExit22MapsToReadableError() {
        let stderr = "noise from /some/target/path\nOASES_DOWNGRADE_REFUSED component=engine installed=v9.0.0 target=v8.0.51\n目标上的组件版本高于本应用要安装的版本。\n"
        let error = DeploymentMaintenanceService.mapError(.nonZero(status: 22, standardOutput: "", standardError: stderr))
        guard case .downgradeRefused(let component, let installed, let target) = error else {
            return XCTFail("\(error)")
        }
        XCTAssertEqual([component, installed, target], ["engine", "v9.0.0", "v8.0.51"])
        for language in [AppLanguage.simplifiedChinese, .english] {
            let description = OasesLocalization.localizedFormat(
                "目标上的 %@ 是 %@，比本应用要安装的 %@ 新；已拒绝降级，没有停止或修改任何内容。请先更新 Oases CPA 应用。",
                language: language, "CLIProxyAPI", installed, target
            )
            XCTAssertTrue(description.contains("CLIProxyAPI") && description.contains("v9.0.0") && description.contains("v8.0.51"), description)
        }
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("CLIProxyAPI"), description)
        XCTAssertTrue(description.contains("v9.0.0") && description.contains("v8.0.51"), description)
        XCTAssertFalse(description.contains("/some/target/path"), "no raw stderr")
        XCTAssertFalse(description.contains("OASES_DOWNGRADE_REFUSED"))
        XCTAssertEqual(DeploymentExecutionError.componentName("gateway"), OasesLocalization.localized("Oases 网关"))

        // A malformed line or another status keeps the general mapping.
        for other in [BoundedProcessError.nonZero(status: 22, standardOutput: "", standardError: "OASES_DOWNGRADE_REFUSED component=x installed=$(id) target=1"),
                      .nonZero(status: 26, standardOutput: "", standardError: stderr)] {
            guard case .commandFailed = DeploymentMaintenanceService.mapError(other) else { return XCTFail("\(other)") }
        }
    }

    // MARK: - Backup, restore, rollback (10a)

    func testFailedGatewayHealthRestoresEverythingIncludingData() throws {
        let (fake, root) = try installed("restore-on-failure")
        try write("{\"schema_version\":2,\"keys\":{\"k\":{\"label\":\"before\"}}}\n", root, "gateway-data/permissions.json")
        let before = [".oases-cpa-versions", "gateway/run.sh", "cli-proxy-api/run.sh", "cli-proxy-api/config.yaml",
                      "cpamp/run.sh", "cpamp/config.json", "gateway-data/permissions.json"].map { ($0, data(root, $0)) }
        let gatewayLink = link(root, "gateway/current")
        let nodeLink = link(root, "node/current")

        let next = try fake.withGateway(version: "0.9.1-test")
        let result = try upgrade(next, root, extraEnvironment: ["FAKE_GATEWAY_EXIT": "1"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Oases 网关没有通过健康检查"), result.stderr)
        for (path, bytes) in before {
            XCTAssertNotNil(bytes, path)
            XCTAssertEqual(data(root, path), bytes, "\(path) is back byte for byte")
        }
        XCTAssertEqual(link(root, "gateway/current"), gatewayLink)
        XCTAssertEqual(link(root, "node/current"), nodeLink)
        let backup = try XCTUnwrap(upgradeBackups(root).last)
        for item in ["versions.json", "gateway-run.sh", "gateway-current", "node-current", "cpamp-config.json",
                     "cli-proxy-api-config.yaml", "cli-proxy-api-run.sh", "cpamp-run.sh", "gateway-data/permissions.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups/\(backup)/\(item)").path), item)
        }
        XCTAssertEqual(text(root, "backups/\(backup)/gateway-current").trimmingCharacters(in: .whitespacesAndNewlines), fake.gatewayVersion)
    }

    func testRollbackRestoresGatewayDataAndVersions() throws {
        let (fake, root) = try installed("rollback-data")
        try write("{\"packs\":[\"before\"]}\n", root, "gateway-data/packs.json")
        let versionsBefore = data(root, ".oases-cpa-versions")
        let next = try fake.withGateway(version: "0.9.1-test")
        let upgraded = try upgrade(next, root)
        XCTAssertEqual(upgraded.status, 0, upgraded.stderr)
        XCTAssertTrue(upgraded.stdout.contains("OASES_CPA_TOPOLOGY=gateway"))
        XCTAssertEqual(try versions(root)["gateway"], "0.9.1-test")
        XCTAssertEqual(link(root, "gateway/current"), "0.9.1-test")
        let result = maintenance.parseResultForVerification(upgraded.stdout)
        XCTAssertEqual(result.topology, .gateway)
        XCTAssertNotNil(result.packEngineKeyFingerprint)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("gateway/\(fake.gatewayVersion)").path), "the previous version stays")

        // The newer gateway rewrites its data.
        try write("{\"packs\":[\"after\"]}\n", root, "gateway-data/packs.json")
        try write("{}\n", root, "gateway-data/only-after-upgrade.json")

        let rolledBack = try rollback(fake, root)
        XCTAssertEqual(rolledBack.status, 0, rolledBack.stderr)
        XCTAssertTrue(rolledBack.stdout.contains("OASES_CPA_TOPOLOGY=gateway"))
        XCTAssertEqual(text(root, "gateway-data/packs.json"), "{\"packs\":[\"before\"]}\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gateway-data/only-after-upgrade.json").path))
        let backup = try XCTUnwrap(upgradeBackups(root).last)
        XCTAssertEqual(text(root, "backups/\(backup)/gateway-data-after-upgrade/only-after-upgrade.json"), "{}\n", "moved, not deleted")
        XCTAssertEqual(text(root, "backups/\(backup)/gateway-data-after-upgrade/packs.json"), "{\"packs\":[\"after\"]}\n")
        XCTAssertEqual(data(root, ".oases-cpa-versions"), versionsBefore)
        XCTAssertEqual(link(root, "gateway/current"), fake.gatewayVersion)
        XCTAssertNotNil(pid(root, "gateway.pid"), "the rolled-back gateway runs")
    }

    func testRunScriptFollowsVersionsAfterUpgradeAndRollback() throws {
        let (fake, root) = try installed("run-script-versions")
        // An older engine recorded before the upgrade.
        try setVersion("engine", "v8.0.50", root)
        let oldRun = text(root, "gateway/run.sh").replacingOccurrences(
            of: "HOST_STATUS_ENGINE_VERSION=\(FakeArtifacts.engineTag)", with: "HOST_STATUS_ENGINE_VERSION=v8.0.50")
        try write(oldRun, root, "gateway/run.sh")
        XCTAssertEqual(try exportedEnvironment(root)["HOST_STATUS_ENGINE_VERSION"], "v8.0.50")

        let upgraded = try upgrade(try fake.withGateway(version: "0.9.1-test"), root)
        XCTAssertEqual(upgraded.status, 0, upgraded.stderr)
        let after = try exportedEnvironment(root)
        XCTAssertEqual(Set(after.keys), ["PORT", "BIND_HOST", "ADMIN_LISTEN_PORT", "GO_BACKEND_URL", "CONFIG_PATH", "KEY_FILE_PATH",
                                         "PACK_ENGINE_KEY_PATH", "PACK_STORE_KEY_FILE", "OASES_DATA_DIR",
                                         "HOST_STATUS_ENGINE_VERSION", "HOST_STATUS_PANEL_VERSION"])
        XCTAssertEqual(after["HOST_STATUS_ENGINE_VERSION"], try versions(root)["engine"])
        XCTAssertEqual(after["HOST_STATUS_PANEL_VERSION"], try versions(root)["cpamp"])
        XCTAssertEqual(after["HOST_STATUS_ENGINE_VERSION"], FakeArtifacts.engineTag)

        let rolledBack = try rollback(fake, root)
        XCTAssertEqual(rolledBack.status, 0, rolledBack.stderr)
        let restored = try exportedEnvironment(root)
        XCTAssertEqual(restored["HOST_STATUS_ENGINE_VERSION"], "v8.0.50")
        XCTAssertEqual(restored["HOST_STATUS_ENGINE_VERSION"], try versions(root)["engine"])
        XCTAssertEqual(restored["HOST_STATUS_PANEL_VERSION"], try versions(root)["cpamp"])
    }

    /// A backup written by app 0.1.4 has only the two run scripts, the engine config and the
    /// runtime directories: no versions.json, no versions.absent, no gateway-data/.
    func testRollbackOfAppV014BackupIsTreatedAsLegacy() throws {
        let fake = try FakeArtifacts.make(caseName: "rollback-014")
        let root = try legacyLayout(fake)
        let backup = "backups/upgrade-20261101-000000"
        try write(text(root, "cli-proxy-api/run.sh"), root, "\(backup)/cli-proxy-api-run.sh")
        try write(text(root, "cpamp/run.sh"), root, "\(backup)/cpamp-run.sh")
        try write(text(root, "cli-proxy-api/config.yaml"), root, "\(backup)/cli-proxy-api-config.yaml")
        for directory in ["cli-proxy-api-runtime", "cpamp-runtime"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("\(backup)/\(directory)"), withIntermediateDirectories: true)
        }
        // After that 0.1.4 upgrade the run script pointed somewhere else.
        let originalRun = text(root, "cli-proxy-api/run.sh")
        try write(originalRun + "# changed by the upgrade\n", root, "cli-proxy-api/run.sh")

        let result = try rollback(fake, root)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("OASES_CPA_TOPOLOGY=legacy"), result.stdout)
        XCTAssertEqual(maintenance.parseResultForVerification(result.stdout).topology, .legacy)
        XCTAssertEqual(text(root, "cli-proxy-api/run.sh"), originalRun)
        XCTAssertTrue(text(root, "cli-proxy-api/config.yaml").contains("port: 8317"))
        XCTAssertNil(pid(root, "gateway.pid"))
    }

    // MARK: - Legacy migration (10b)

    private func startLegacy(_ fake: FakeArtifacts, _ root: URL) throws {
        let start = try fake.run(RuntimeLifecycleService().startScriptForVerification(method: .native, installDirectory: root.path))
        XCTAssertEqual(start.status, 0, start.stderr)
        XCTAssertNotNil(pid(root, "cli-proxy-api.pid"))
        XCTAssertNil(pid(root, "gateway.pid"), "a 0.1.x deployment has no gateway")
    }

    private func migrationEnvironment(_ root: URL) -> [String: String] {
        ["FAKE_ENGINE_CONFIG": root.appendingPathComponent("cli-proxy-api/config.yaml").path]
    }

    func testLegacyMigrationMovesEngineAndInstallsGateway() throws {
        let fake = try FakeArtifacts.make(caseName: "migrate")
        let root = try legacyLayout(fake)
        try startLegacy(fake, root)
        let originalConfig = text(root, "cli-proxy-api/config.yaml")

        let result = try upgrade(fake, root, extraEnvironment: migrationEnvironment(root))
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("OASES_CPA_TOPOLOGY=gateway"), result.stdout)
        let config = text(root, "cli-proxy-api/config.yaml")
        XCTAssertTrue(config.contains("\nport: 18316\n"), config)
        XCTAssertFalse(config.contains("port: 8317"))
        XCTAssertTrue(config.contains("response-compression:\n  enabled: false"), config)
        let packKey = text(root, "secrets/pack-engine-key").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(packKey.isEmpty)
        XCTAssertTrue(config.contains("  - \"\(Self.legacyUserKey)\""), "the user's key stays")
        XCTAssertTrue(config.contains("  - \"\(packKey)\""), "the internal key was added")
        XCTAssertTrue(config.contains("api-keys:\n"), "top-level api-keys (legacy layout, R14)")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("gateway/run.sh").path))
        XCTAssertEqual(try versions(root), ["engine": FakeArtifacts.engineTag, "cpamp": FakeArtifacts.cpampTag,
                                             "node": FakeArtifacts.nodeTag, "gateway": fake.gatewayVersion])
        XCTAssertTrue(text(root, "cpamp/config.json").contains("\"cpaUpstreamUrl\": \"http://127.0.0.1:18316\""))
        XCTAssertTrue(text(root, "cpamp/run.sh").contains("export CPA_MANAGER_CONFIG=\(root.path)/cpamp/config.json"))
        XCTAssertEqual(text(root, "cpamp/data/usage.db"), "usage\n", "CPA Manager Plus data untouched")
        XCTAssertNotNil(pid(root, "gateway.pid"))
        let backup = try XCTUnwrap(upgradeBackups(root).last)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups/\(backup)/versions.absent").path))
        XCTAssertEqual(text(root, "backups/\(backup)/cli-proxy-api-config.yaml"), originalConfig)
        XCTAssertEqual(text(root, "backups/\(backup)/topology"), "legacy\n")
        XCTAssertNotNil(maintenance.parseResultForVerification(result.stdout).packEngineKeyFingerprint)
    }

    /// L6: a config without the line `port: 8317` is not guessed at; the upgrade fails closed
    /// with 27 and puts everything back.
    func testLegacyMigrationWithoutPort8317FailsClosedWith27() throws {
        let fake = try FakeArtifacts.make(caseName: "migrate-no-port")
        let root = try legacyLayout(fake)
        let edited = Self.legacyConfig(root: root).replacingOccurrences(of: "port: 8317", with: "port: 9999")
        try write(edited, root, "cli-proxy-api/config.yaml")
        let result = try upgrade(fake, root, extraEnvironment: migrationEnvironment(root))
        XCTAssertEqual(result.status, 27, result.stderr)
        XCTAssertTrue(result.stderr.contains("port: 8317"), result.stderr)
        XCTAssertEqual(text(root, "cli-proxy-api/config.yaml"), edited)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gateway/run.sh").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".oases-cpa-versions").path))
    }

    func testRollbackToLegacyBackupReturnsLegacyTopology() throws {
        let fake = try FakeArtifacts.make(caseName: "rollback-legacy")
        let root = try legacyLayout(fake)
        let originalConfig = text(root, "cli-proxy-api/config.yaml")
        let originalPanelRun = text(root, "cpamp/run.sh")
        let upgraded = try upgrade(fake, root, extraEnvironment: migrationEnvironment(root))
        XCTAssertEqual(upgraded.status, 0, upgraded.stderr)
        XCTAssertNotNil(pid(root, "gateway.pid"))

        let result = try rollback(fake, root)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("OASES_CPA_TOPOLOGY=legacy"), result.stdout)
        XCTAssertEqual(text(root, "cli-proxy-api/config.yaml"), originalConfig, "engine back on 8317 without the internal key")
        XCTAssertEqual(text(root, "cpamp/run.sh"), originalPanelRun)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gateway/run.sh").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".oases-cpa-versions").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gateway-data").path))
        let backup = try XCTUnwrap(upgradeBackups(root).last)
        for moved in ["gateway-run.sh.after-upgrade", "versions-after-upgrade.json", "gateway-data-after-upgrade", "cpamp-config.json.after-upgrade"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups/\(backup)/\(moved)").path), moved)
        }
        XCTAssertNil(pid(root, "gateway.pid"), "no gateway runs in the legacy layout")
        XCTAssertNotNil(pid(root, "cli-proxy-api.pid"))
    }

    func testUpgradeRollbackAndMigrationNeverPassKeysInArgv() throws {
        let fake = try FakeArtifacts.make(caseName: "maintenance-argv")
        let root = try legacyLayout(fake)
        try startLegacy(fake, root)
        XCTAssertEqual(try upgrade(fake, root, extraEnvironment: migrationEnvironment(root)).status, 0)
        XCTAssertEqual(try rollback(fake, root).status, 0)
        let argv = fake.argv()
        XCTAssertTrue(argv.contains("curl -K - -fsS -o /dev/null http://127.0.0.1:18316/v0/management/config"), "keyed curl through -K -")
        XCTAssertTrue(argv.contains("node -e "), "the inline api-keys script ran")
        for name in ["cpa-management-key", "cpamp-admin-key", "pack-engine-key", "pack-store-key"] {
            let key = text(root, "secrets/\(name)").trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(key.isEmpty, name)
            XCTAssertFalse(argv.contains(key), "\(name) appears in a process argument")
        }
        let script = maintenance.upgradeScriptForVerification(method: .native, installDirectory: "/x", gatewayPayloadBase64: "")
        XCTAssertFalse(script.contains("-H \"Authorization"), "no key in a curl argument")
        XCTAssertFalse(maintenance.rollbackScriptForVerification(method: .native, installDirectory: "/x").contains("-H \"Authorization"))
        XCTAssertFalse(DeploymentMaintenanceService.apiKeysMigrationScript.contains("\'"), "fits a single-quoted shell word")
        XCTAssertTrue(DeploymentMaintenanceService.apiKeysMigrationScript.contains("process.env.OASES_MANAGEMENT_KEY"))
        XCTAssertTrue(DeploymentMaintenanceService.apiKeysMigrationScript.contains("process.env.PACK_ENGINE_KEY"))
    }

    func testLegacyMigrationSucceedsUnderUmask002() throws {
        let fake = try FakeArtifacts.make(caseName: "migrate-umask")
        let root = try legacyLayout(fake, mode: 0o775)
        let mode = { (relative: String) -> Int in
            ((try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(relative).path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        XCTAssertEqual(mode("secrets"), 0o775)
        let result = try upgrade(fake, root, prelude: "umask 002", extraEnvironment: migrationEnvironment(root))
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(mode("secrets"), 0o700)
        XCTAssertEqual(mode("gateway-data"), 0o700)
        XCTAssertEqual(mode("") & 0o022, 0, "the root lost group/other write")
        XCTAssertEqual(mode("secrets/pack-engine-key"), 0o600)
    }

    // MARK: - Tunnel after maintenance (10b)

    func testTopologyChangeAfterUpgradeRestartsTunnel() {
        XCTAssertEqual(DeploymentStore.tunnelAction(previous: .legacy, result: .gateway, target: .ssh), .restart(.gateway))
        XCTAssertEqual(DeploymentStore.tunnelAction(previous: .gateway, result: .legacy, target: .ssh), .restart(.legacy))
        XCTAssertEqual(DeploymentStore.tunnelAction(previous: .gateway, result: .gateway, target: .ssh), .none)
        XCTAssertEqual(DeploymentStore.tunnelAction(previous: .legacy, result: .gateway, target: .local), .none, "no tunnel on this Mac")
    }

    func testLegacyNativeUpgradeIsOfferedAsTheFullEditionAndDockerGetsTheNotice() {
        XCTAssertEqual(MaintenanceLabels.upgradeButtonTitle(method: .native, topology: .legacy, language: .simplifiedChinese), "升级到完整版（加入 Oases 网关）")
        XCTAssertEqual(MaintenanceLabels.upgradeButtonTitle(method: .native, topology: .legacy, language: .english), "Upgrade to the full edition (adds the Oases gateway)")
        XCTAssertEqual(MaintenanceLabels.upgradeButtonTitle(method: .native, topology: .gateway, language: .simplifiedChinese), "升级运行时")
        XCTAssertEqual(MaintenanceLabels.upgradeButtonTitle(method: .docker, topology: .legacy, language: .simplifiedChinese), "升级运行时")
        let migration = MaintenanceLabels.upgradeConfirmationMessage(method: .native, topology: .legacy, language: .simplifiedChinese)
        for fact in ["8317", "18316", "18320", "SSH 隧道"] { XCTAssertTrue(migration.contains(fact), fact) }
        XCTAssertTrue(MaintenanceLabels.upgradeConfirmationMessage(method: .native, topology: .legacy, language: .english).contains("18316"))
        let notice = "Oases 网关只支持原生部署；Docker 部署只包含上游 CLIProxyAPI 与 CPA Manager Plus"
        XCTAssertEqual(MaintenanceLabels.dockerGatewayNotice(language: .simplifiedChinese), notice)
        XCTAssertTrue(MaintenanceLabels.planConfirmationMessage(method: .docker, language: .simplifiedChinese).contains(notice))
        XCTAssertFalse(MaintenanceLabels.planConfirmationMessage(method: .native, language: .simplifiedChinese).contains(notice))
        XCTAssertTrue(MaintenanceLabels.upgradeConfirmationMessage(method: .docker, topology: .legacy, language: .simplifiedChinese).contains("Oases 网关只支持原生部署"))
        XCTAssertTrue(MaintenanceLabels.dockerGatewayNotice(language: .english).contains("native deployments only"))

        // Rollback, stop, removal and health texts name what really happens.
        for language in [AppLanguage.simplifiedChinese, .english] {
            let rollback = MaintenanceLabels.rollbackMessage(ports: "8317 / 18320 / 18316 / 18317", language: language)
            for fact in ["config.yaml", "gateway-data", "after-upgrade", "18320"] { XCTAssertTrue(rollback.contains(fact), "\(language): \(fact)") }
            XCTAssertTrue(MaintenanceLabels.removalMessage(topology: .gateway, directory: "/x", language: language).contains("/x"))
        }
        XCTAssertTrue(MaintenanceLabels.stopMessage(topology: .gateway, language: .simplifiedChinese).contains("Oases 网关"))
        XCTAssertFalse(MaintenanceLabels.stopMessage(topology: .legacy, language: .simplifiedChinese).contains("网关"))
        XCTAssertTrue(MaintenanceLabels.removalMessage(topology: .gateway, directory: "/x", language: .english).contains("Oases gateway"))
        XCTAssertTrue(MaintenanceLabels.healthyMessage(topology: .gateway, language: .english).contains("Oases gateway"))
        XCTAssertTrue(MaintenanceLabels.checkingMessage(topology: .gateway, language: .simplifiedChinese).contains("Oases 网关"))
        XCTAssertFalse(MaintenanceLabels.healthyMessage(topology: .legacy, language: .english).contains("gateway"))
        XCTAssertFalse(OasesLocalization.localized("正在下载并切换到本应用固定的运行时版本…", language: .english).contains("latest"))
    }

    // MARK: - Fix round 1

    /// A rollback puts the pre-upgrade engine configuration back, but the configuration edited
    /// after the upgrade (providers, upstream keys, client keys) is kept inside the backup.
    func testRollbackKeepsTheNewerEngineConfigurationInTheBackup() throws {
        let (fake, root) = try installed("rollback-keeps-config")
        let before = text(root, "cli-proxy-api/config.yaml")
        XCTAssertEqual(try upgrade(try fake.withGateway(version: "0.9.1-test"), root).status, 0)
        let edited = text(root, "cli-proxy-api/config.yaml") + "openai-compatibility:\n  - name: added-after-the-upgrade\n"
        try write(edited, root, "cli-proxy-api/config.yaml")

        let result = try rollback(fake, root)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(text(root, "cli-proxy-api/config.yaml"), before)
        let backup = try XCTUnwrap(upgradeBackups(root).last)
        XCTAssertEqual(text(root, "backups/\(backup)/cli-proxy-api-config.yaml.after-upgrade"), edited, "the newer config is kept")
        // The newer engine runtime of the same package name is moved aside, not deleted.
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("backups/\(backup)/cli-proxy-api-runtime-after-upgrade").path)) ?? []
        XCTAssertEqual(kept.count, 1, "\(kept)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups/\(backup)/cli-proxy-api-run.sh.after-upgrade").path),
                       "an identical run script is not duplicated")
    }

    /// After the stop nothing may still run from the root; a gateway without a pid file makes
    /// upgrade and rollback refuse with 28, before any backup copy or restore, and nothing is
    /// started next to it.
    func testUpgradeAndRollbackRefuseWhileAProcessWithoutPidFileRuns() throws {
        let (fake, root) = try installed("orphan-gateway")
        let next = try fake.withGateway(version: "0.9.1-test")
        XCTAssertEqual(try upgrade(next, root).status, 0)
        let gateway = try XCTUnwrap(pid(root, "gateway.pid"))
        defer { kill(gateway, SIGTERM) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("gateway.pid"))
        let versions = data(root, ".oases-cpa-versions")
        let config = data(root, "cli-proxy-api/config.yaml")
        let backupsBefore = upgradeBackups(root)

        let refusedUpgrade = try upgrade(next, root)
        XCTAssertEqual(refusedUpgrade.status, 28, refusedUpgrade.stderr)
        XCTAssertTrue(refusedUpgrade.stderr.contains("仍有 Oases CPA 进程在运行"), refusedUpgrade.stderr)
        XCTAssertEqual(kill(gateway, 0), 0, "the orphan was not touched")
        XCTAssertEqual(data(root, ".oases-cpa-versions"), versions)
        XCTAssertEqual(data(root, "cli-proxy-api/config.yaml"), config)
        XCTAssertEqual(upgradeBackups(root), backupsBefore, "no backup was made (a rollback still finds the real one)")
        XCTAssertNil(pid(root, "cli-proxy-api.pid"), "nothing was started next to it")

        // The rollback refuses the same way, before restoring anything.
        let refusedRollback = try rollback(fake, root)
        XCTAssertEqual(refusedRollback.status, 28, refusedRollback.stderr)
        XCTAssertEqual(data(root, "cli-proxy-api/config.yaml"), config)
        XCTAssertEqual(kill(gateway, 0), 0)
    }

    /// Pruning happens after a successful upgrade: a failed move logs and never rolls it back.
    func testFailedPruneDoesNotRollBackASuccessfulUpgrade() throws {
        let (fake, root) = try installed("prune-best-effort")
        for (index, old) in ["0.0.1", "0.0.2", "0.0.3"].enumerated() {
            try write("old\n", root, "gateway/\(old)/VERSION")
            let date = Date(timeIntervalSinceNow: TimeInterval(-86_400 * (5 - index)))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root.appendingPathComponent("gateway/\(old)").path)
        }
        // An mv that refuses only moves into backups/pruned-*.
        let bin = fake.caseDirectory.appendingPathComponent("prune-bin", isDirectory: true)
        try write("#!/bin/bash\nfor arg in \"$@\"; do case \"$arg\" in */backups/pruned-*) exit 1 ;; esac; done\nexec /bin/mv \"$@\"\n", bin, "mv")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("mv").path)
        let failing = try upgrade(try fake.withGateway(version: "0.9.1-test"), root,
                                  extraEnvironment: ["PATH": "\(bin.path):\(fake.binDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"])
        XCTAssertEqual(failing.status, 0, failing.stderr)
        XCTAssertTrue(failing.stderr.contains("未能移入 backups，已保留原处"), failing.stderr)
        XCTAssertEqual(link(root, "gateway/current"), "0.9.1-test", "the upgrade stands")
        XCTAssertEqual(try versions(root)["gateway"], "0.9.1-test")

        // Without the failing mv the oldest previous versions move to backups/pruned-*.
        let pruned = try upgrade(try fake.withGateway(version: "0.9.2-test"), root)
        XCTAssertEqual(pruned.status, 0, pruned.stderr)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("gateway").path)
            .filter { !["current", "downloads", "run.sh"].contains($0) && !$0.hasPrefix(".") }
        XCTAssertEqual(Set(remaining), ["0.9.2-test", "0.9.1-test", fake.gatewayVersion], "current + the two newest previous")
        let prunedDirectories = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("backups").path).filter { $0.hasPrefix("pruned-") }
        XCTAssertFalse(prunedDirectories.isEmpty)
    }

    /// A 0.1.x deployment has no versions file; a newer engine in its run.sh is still refused.
    func testLegacyRunScriptWithNewerEngineRefusesWithExit22() throws {
        let fake = try FakeArtifacts.make(caseName: "legacy-newer-engine")
        let root = try legacyLayout(fake)
        let newer = text(root, "cli-proxy-api/run.sh").replacingOccurrences(of: "CLIProxyAPI_7.2.141_", with: "CLIProxyAPI_9.1.0_")
        try write(newer, root, "cli-proxy-api/run.sh")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".oases-cpa-versions").path))
        let result = try upgrade(fake, root, extraEnvironment: migrationEnvironment(root))
        XCTAssertEqual(result.status, 22, result.stderr)
        XCTAssertTrue(result.stderr.contains("OASES_DOWNGRADE_REFUSED component=engine installed=v9.1.0 target=\(FakeArtifacts.engineTag)"), result.stderr)
        XCTAssertEqual(upgradeBackups(root), [])
        XCTAssertTrue(text(root, "cli-proxy-api/config.yaml").contains("port: 8317"))
    }

    /// The migration only moves an engine bound to loopback: any other host fails closed.
    func testLegacyMigrationRefusesANonLoopbackEngineHost() throws {
        for (index, host) in ["host: \"0.0.0.0\"", "host: \"\"", "host: 192.168.1.20"].enumerated() {
            let fake = try FakeArtifacts.make(caseName: "migrate-host-\(index)")
            let root = try legacyLayout(fake)
            let config = Self.legacyConfig(root: root).replacingOccurrences(of: "host: \"127.0.0.1\"", with: host)
            try write(config, root, "cli-proxy-api/config.yaml")
            let result = try upgrade(fake, root, extraEnvironment: migrationEnvironment(root))
            XCTAssertEqual(result.status, 27, "\(host): \(result.stderr)")
            XCTAssertTrue(result.stderr.contains("host 不是本机回环地址"), result.stderr)
            XCTAssertEqual(text(root, "cli-proxy-api/config.yaml"), config, "restored")
        }
        // Unquoted loopback is accepted.
        let fake = try FakeArtifacts.make(caseName: "migrate-host-plain")
        let root = try legacyLayout(fake)
        try write(Self.legacyConfig(root: root).replacingOccurrences(of: "host: \"127.0.0.1\"", with: "host: 127.0.0.1"), root, "cli-proxy-api/config.yaml")
        XCTAssertEqual(try upgrade(fake, root, extraEnvironment: migrationEnvironment(root)).status, 0)
    }

    func testDockerRollbackMovesTheUpgradesVersionsFileAsideWhenThereWasNone() throws {
        let fake = try FakeArtifacts.make(caseName: "docker-rollback-versions")
        let root = fake.caseDirectory.appendingPathComponent("root", isDirectory: true)
        try write("", root, ".oases-cpa-installed")
        try write("services:\n  cpa:\n    image: test\n", root, "compose.yaml")
        let bin = fake.caseDirectory.appendingPathComponent("docker-bin", isDirectory: true)
        try write("#!/bin/bash\nexit 0\n", bin, "docker")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("docker").path)
        let environment = ["PATH": "\(bin.path):\(fake.binDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"]
        XCTAssertEqual(try fake.run(maintenance.upgradeScriptForVerification(method: .docker, installDirectory: root.path, pins: fake.pins),
                                    extraEnvironment: environment).status, 0)
        XCTAssertNotNil(data(root, ".oases-cpa-versions"), "the upgrade wrote one")
        let backup = try XCTUnwrap(upgradeBackups(root).last)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups/\(backup)/versions.absent").path))

        let rolledBack = try fake.run(maintenance.rollbackScriptForVerification(method: .docker, installDirectory: root.path), extraEnvironment: environment)
        XCTAssertEqual(rolledBack.status, 0, rolledBack.stderr)
        XCTAssertNil(data(root, ".oases-cpa-versions"))
        XCTAssertTrue(text(root, "backups/\(backup)/versions-after-upgrade.json").contains(FakeArtifacts.engineTag), "moved, not deleted")
    }

    // MARK: - Docker (10a)

    func testDockerUpgradeRefusesDowngradeFromVersionsFile() throws {
        let fake = try FakeArtifacts.make(caseName: "docker-versions")
        let root = fake.caseDirectory.appendingPathComponent("root", isDirectory: true)
        try write("", root, ".oases-cpa-installed")
        try write("services:\n  cpa:\n    image: test\n", root, "compose.yaml")
        try write("{\n  \"engine\": \"v9.0.0\",\n  \"cpamp\": \"v1.14.10\"\n}\n", root, ".oases-cpa-versions")
        let bin = fake.caseDirectory.appendingPathComponent("docker-bin", isDirectory: true)
        let dockerLog = fake.caseDirectory.appendingPathComponent("docker.log")
        try write("#!/bin/bash\nprintf '%s\\n' \"$*\" >> '\(dockerLog.path)'\nexit 0\n", bin, "docker")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("docker").path)
        let environment = ["PATH": "\(bin.path):\(fake.binDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"]
        let script = maintenance.upgradeScriptForVerification(method: .docker, installDirectory: root.path, pins: fake.pins)

        let refused = try fake.run(script, extraEnvironment: environment)
        XCTAssertEqual(refused.status, 22, refused.stderr)
        XCTAssertTrue(refused.stderr.contains("OASES_DOWNGRADE_REFUSED component=engine installed=v9.0.0 target=\(FakeArtifacts.engineTag)"))
        XCTAssertFalse(((try? String(contentsOf: dockerLog, encoding: .utf8)) ?? "").contains("pull"), "nothing was pulled")
        XCTAssertEqual(upgradeBackups(root), [])

        try write("{\n  \"engine\": \"v8.0.0\",\n  \"cpamp\": \"v1.14.10\"\n}\n", root, ".oases-cpa-versions")
        let accepted = try fake.run(script, extraEnvironment: environment)
        XCTAssertEqual(accepted.status, 0, accepted.stderr)
        XCTAssertTrue(accepted.stdout.contains("OASES_CPA_TOPOLOGY=legacy"))
        XCTAssertEqual(try versions(root), ["engine": FakeArtifacts.engineTag, "cpamp": FakeArtifacts.cpampTag], "two keys only")
        let backup = try XCTUnwrap(upgradeBackups(root).last)
        XCTAssertTrue(text(root, "backups/\(backup)/versions.json").contains("v8.0.0"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gateway").path), "no gateway for Docker")
    }
}
