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
    /// Random free loopback ports for every script of a test (never the fixed ports: the
    /// upgrade checks that its ports are free, and the owner's deployment may hold 8317/18317).
    /// The legacy engine port stays 8317: only the fakes "listen" there.
    private lazy var ports: DeploymentScriptPorts = {
        let free = (try? FakeArtifacts.freeLoopbackPorts(4)) ?? [28_101, 28_102, 28_103, 28_104]
        return DeploymentScriptPorts(gatewayAPI: free[0], gatewayAdmin: free[1], engine: free[2], cpamp: free[3])
    }()

    /// A gateway deployment installed and started by the real install script.
    private func installed(_ caseName: String, extraEnvironment: [String: String] = [:]) throws -> (FakeArtifacts, URL) {
        let fake = try FakeArtifacts.make(caseName: caseName)
        let root = fake.caseDirectory.appendingPathComponent("root", isDirectory: true)
        startedRoots.append((fake, root))
        let result = try fake.run(DeploymentExecutor().scriptForVerification(
            method: .native, installDirectory: root.path, pins: fake.pins, gatewayPayloadBase64: fake.gatewayPayloadBase64, ports: ports
        ), extraEnvironment: extraEnvironment)
        XCTAssertEqual(result.status, 0, result.stderr)
        return (fake, root)
    }

    private func upgrade(_ fake: FakeArtifacts, _ root: URL, prelude: String = "", extraEnvironment: [String: String] = [:]) throws -> FakeArtifacts.RunResult {
        try fake.run(maintenance.upgradeScriptForVerification(
            method: .native, installDirectory: root.path, pins: fake.pins,
            gatewayPayloadBase64: fake.gatewayPayloadBase64, ports: ports, healthAttempts: 3
        ), prelude: prelude, extraEnvironment: extraEnvironment)
    }

    private func rollback(_ fake: FakeArtifacts, _ root: URL, extraEnvironment: [String: String] = [:]) throws -> FakeArtifacts.RunResult {
        try fake.run(maintenance.rollbackScriptForVerification(method: .native, installDirectory: root.path, ports: ports, healthAttempts: 3),
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
    private func legacyLayout(_ fake: FakeArtifacts, mode: Int = 0o700, managedMarker: String? = "owned-by=oases-cpa\n") throws -> URL {
        let root = fake.caseDirectory.appendingPathComponent("root", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: mode])
        try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: root.path)
        startedRoots.append((fake, root))
        if let managedMarker { try write(managedMarker, root, ".oases-cpa-managed") }
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

    // MARK: - MODEL_CATALOG_URL survives the regenerated gateway/run.sh

    private let catalogDropped = "MODEL_CATALOG_URL 不是 off 或安全的 https:// 地址"

    /// An installed deployment whose `gateway/run.sh` got `line` by hand (next to the other
    /// exports), then upgraded to a newer gateway.
    private func upgradeWithCatalogLine(_ caseName: String, _ line: String?) throws -> (FakeArtifacts.RunResult, URL, FakeArtifacts) {
        let (fake, root) = try installed(caseName)
        if let line {
            // The fake health check answers at once, so the install may return before the
            // gateway's bash has read run.sh up to its exec; editing the file earlier would run
            // the edited line in that bash. Wait until the gateway runs (fake node logs it).
            let deadline = Date().addingTimeInterval(10)
            while !((try? String(contentsOf: fake.argvLog, encoding: .utf8)) ?? "").contains("/gateway/current/server.mjs"),
                  Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            let edited = text(root, "gateway/run.sh").replacingOccurrences(
                of: "export HOST_STATUS_PANEL_VERSION=", with: line + "\nexport HOST_STATUS_PANEL_VERSION=")
            try write(edited, root, "gateway/run.sh")
            XCTAssertTrue(text(root, "gateway/run.sh").contains(line + "\n"))
        }
        let upgraded = try upgrade(try fake.withGateway(version: "0.9.1-test"), root)
        XCTAssertEqual(upgraded.status, 0, upgraded.stderr)
        XCTAssertEqual(link(root, "gateway/current"), "0.9.1-test", "the gateway really was upgraded")
        let syntax = Process()
        syntax.executableURL = URL(fileURLWithPath: "/bin/bash")
        syntax.arguments = ["-n", root.appendingPathComponent("gateway/run.sh").path]
        try syntax.run()
        syntax.waitUntilExit()
        XCTAssertEqual(syntax.terminationStatus, 0, "gateway/run.sh stays valid bash")
        return (upgraded, root, fake)
    }

    private func pwnedFiles(_ fake: FakeArtifacts) -> [String] {
        let enumerator = FileManager.default.enumerator(at: fake.caseDirectory, includingPropertiesForKeys: nil)
        var found: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == "pwned" { found.append(url.path) }
        }
        return found
    }

    func testUpgradeKeepsModelCatalogOff() throws {
        let (upgraded, root, fake) = try upgradeWithCatalogLine("catalog-off", "export MODEL_CATALOG_URL=off")
        XCTAssertEqual(try exportedEnvironment(root)["MODEL_CATALOG_URL"], "off")
        XCTAssertFalse(upgraded.stderr.contains(catalogDropped), upgraded.stderr)
        XCTAssertNotNil(pid(root, "gateway.pid"), "the upgraded gateway runs with the carried-over setting")

        // The carried-over (single-quoted) form survives the next upgrade as well.
        let again = try upgrade(try fake.withGateway(version: "0.9.2-test"), root)
        XCTAssertEqual(again.status, 0, again.stderr)
        XCTAssertEqual(link(root, "gateway/current"), "0.9.2-test")
        XCTAssertEqual(try exportedEnvironment(root)["MODEL_CATALOG_URL"], "off")
        XCTAssertFalse(again.stderr.contains(catalogDropped), again.stderr)
    }

    func testUpgradeKeepsAValidModelCatalogURL() throws {
        let url = "https://catalog.example/api/v1/models?mirror=1"
        let (upgraded, root, _) = try upgradeWithCatalogLine("catalog-url", "export MODEL_CATALOG_URL='\(url)'")
        XCTAssertEqual(try exportedEnvironment(root)["MODEL_CATALOG_URL"], url)
        XCTAssertTrue(text(root, "gateway/run.sh").contains("export MODEL_CATALOG_URL='\(url)'\n"))
        XCTAssertFalse(upgraded.stderr.contains(catalogDropped), upgraded.stderr)
    }

    func testUpgradeDropsAnUnsafeModelCatalogValueWithoutRunningIt() throws {
        for (index, line) in [#"export MODEL_CATALOG_URL=x';touch pwned;'"#, #"export MODEL_CATALOG_URL=$(touch pwned)"#].enumerated() {
            let (upgraded, root, fake) = try upgradeWithCatalogLine("catalog-unsafe-\(index)", line)
            let run = text(root, "gateway/run.sh")
            XCTAssertFalse(run.contains("MODEL_CATALOG_URL"), line)
            // Never evaluate a run.sh that carries the value (it would run outside the scratch).
            guard !run.contains("pwned") else { XCTFail("the unsafe value reached run.sh: \(line)"); continue }
            XCTAssertNil(try exportedEnvironment(root)["MODEL_CATALOG_URL"], line)
            XCTAssertEqual(upgraded.stderr.components(separatedBy: catalogDropped).count - 1, 1, upgraded.stderr)
            XCTAssertFalse(upgraded.stderr.contains("pwned"), "the value is not repeated")
            XCTAssertNotNil(pid(root, "gateway.pid"), "the upgraded gateway runs")
            XCTAssertEqual(pwnedFiles(fake), [], line)
        }
    }

    func testUpgradeWithoutModelCatalogSettingWritesTheSameRunScript() throws {
        let (upgraded, root, _) = try upgradeWithCatalogLine("catalog-none", nil)
        XCTAssertFalse(text(root, "gateway/run.sh").contains("MODEL_CATALOG_URL"))
        XCTAssertFalse(upgraded.stderr.contains("MODEL_CATALOG_URL"), upgraded.stderr)
        XCTAssertEqual(Set(try exportedEnvironment(root).keys), ["PORT", "BIND_HOST", "ADMIN_LISTEN_PORT", "GO_BACKEND_URL", "CONFIG_PATH",
                                                                 "KEY_FILE_PATH", "PACK_ENGINE_KEY_PATH", "PACK_STORE_KEY_FILE",
                                                                 "OASES_DATA_DIR", "HOST_STATUS_ENGINE_VERSION", "HOST_STATUS_PANEL_VERSION"])
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
        XCTAssertTrue(config.contains("\nport: \(ports.engine)\n"), config)
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
        XCTAssertTrue(text(root, "cpamp/config.json").contains("\"cpaUpstreamUrl\": \"http://127.0.0.1:\(ports.engine)\""))
        XCTAssertTrue(text(root, "cpamp/run.sh").contains("export CPA_MANAGER_CONFIG=\(root.path)/cpamp/config.json"))
        XCTAssertEqual(text(root, "cpamp/data/usage.db"), "usage\n", "CPA Manager Plus data untouched")
        XCTAssertNotNil(pid(root, "gateway.pid"))
        let backup = try XCTUnwrap(upgradeBackups(root).last)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups/\(backup)/versions.absent").path))
        XCTAssertEqual(text(root, "backups/\(backup)/cli-proxy-api-config.yaml"), originalConfig)
        // A legacy backup is the one without gateway-current (nothing reads a topology file).
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups/\(backup)/gateway-current").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups/\(backup)/topology").path))
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
        XCTAssertTrue(argv.contains("curl -K - -fsS -o /dev/null http://127.0.0.1:\(ports.engine)/v0/management/config"), "keyed curl through -K -")
        XCTAssertTrue(argv.contains("node -e "), "the inline api-keys script ran")
        // The rollback to the 0.1.x layout moves the gateway's pack keys into the backup.
        let backup = upgradeBackups(root).last ?? ""
        for name in ["cpa-management-key", "cpamp-admin-key", "pack-engine-key", "pack-store-key"] {
            let current = text(root, "secrets/\(name)").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = current.isEmpty
                ? text(root, "backups/\(backup)/secrets-after-upgrade/\(name)").trimmingCharacters(in: .whitespacesAndNewlines)
                : current
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

    /// Every native upgrade ends in the gateway topology: the script carries no legacy-target
    /// branch, and each shared shell function is defined once in a script that includes both
    /// the Node and the gateway fragment.
    func testGeneratedScriptsDefineSharedFunctionsOnceAndHaveNoDeadTopologyBranch() {
        let upgrade = maintenance.upgradeScriptForVerification(method: .native, installDirectory: "/x", gatewayPayloadBase64: "")
        let install = DeploymentExecutor().scriptForVerification(method: .native, installDirectory: "/x", gatewayPayloadBase64: "")
        for (name, script) in [("upgrade", upgrade), ("install", install)] {
            XCTAssertEqual(script.components(separatedBy: "oases_archive_paths_are_relative() {").count - 1, 1, "\(name): defined once")
            XCTAssertTrue(script.contains("oases_install_node()") && script.contains("oases_install_gateway()"), name)
        }
        XCTAssertFalse(upgrade.contains("TARGET_TOPOLOGY"), "no dead legacy-target branch")
        XCTAssertFalse(upgrade.contains("/topology"), "no topology file nobody reads")
        XCTAssertTrue(upgrade.contains("printf 'OASES_CPA_TOPOLOGY=%s\\n' gateway"))
    }

    /// A printf format string never spans a line break in the generated scripts (the file's
    /// convention: `\\n` in the Swift source, `\n` in the script).
    func testPrintfFormatsStayOnOneLine() {
        let scripts = [
            ("docker upgrade", maintenance.upgradeScriptForVerification(method: .docker, installDirectory: "/x", gatewayPayloadBase64: "")),
            ("native upgrade", maintenance.upgradeScriptForVerification(method: .native, installDirectory: "/x", gatewayPayloadBase64: "")),
            ("docker rollback", maintenance.rollbackScriptForVerification(method: .docker, installDirectory: "/x")),
            ("native rollback", maintenance.rollbackScriptForVerification(method: .native, installDirectory: "/x"))
        ]
        let format = try? NSRegularExpression(pattern: #"^\s*printf '[^']*'"#)
        for (name, script) in scripts {
            for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
                let text = String(line)
                guard text.trimmingCharacters(in: .whitespaces).hasPrefix("printf '") else { continue }
                XCTAssertNotNil(format?.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)), "\(name): \(text)")
            }
        }
        XCTAssertTrue(scripts[0].1.contains("printf '%s\\n' '升级在备份完成前失败；未完成的备份未能移走"))
    }

    func testTopologyChangeAfterUpgradeRestartsTunnel() {
        XCTAssertEqual(DeploymentStore.tunnelAction(previous: .legacy, result: .gateway, target: .ssh), .restart(.gateway))
        XCTAssertEqual(DeploymentStore.tunnelAction(previous: .gateway, result: .legacy, target: .ssh), .restart(.legacy))
        XCTAssertEqual(DeploymentStore.tunnelAction(previous: .gateway, result: .gateway, target: .ssh), .none)
        XCTAssertEqual(DeploymentStore.tunnelAction(previous: .legacy, result: .gateway, target: .local), .none, "no tunnel on this Mac")
    }

    func testUpgradeCalloutIsShownOnlyForAnInstalledLegacyNativeDeployment() {
        // The gateway pages send the user to the upgrade, so the main page must offer it.
        XCTAssertTrue(MaintenanceLabels.showsUpgradeCallout(method: .native, topology: .legacy, hasInstalledDeployment: true))
        XCTAssertFalse(MaintenanceLabels.showsUpgradeCallout(method: .native, topology: .legacy, hasInstalledDeployment: false), "nothing is installed yet")
        XCTAssertFalse(MaintenanceLabels.showsUpgradeCallout(method: .native, topology: .gateway, hasInstalledDeployment: true), "already the full edition")
        XCTAssertFalse(MaintenanceLabels.showsUpgradeCallout(method: .docker, topology: .legacy, hasInstalledDeployment: true), "Docker has no gateway")
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
        // ::1 is loopback, but the gateway and CPA Manager Plus dial 127.0.0.1 (IPv4 only).
        for (index, host) in ["host: \"0.0.0.0\"", "host: \"\"", "host: 192.168.1.20", "host: \"::1\"", "host: ::1", "host: \"[::1]\""].enumerated() {
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

    // MARK: - Batch-4 review follow-ups (batch 6, step 0)

    /// A bin directory with one executable `name` (bash text), first on PATH before the fakes.
    private func shadowingTool(_ fake: FakeArtifacts, _ name: String, _ body: String) throws -> [String: String] {
        let bin = fake.caseDirectory.appendingPathComponent("shadow-\(name)-bin", isDirectory: true)
        try write("#!/bin/bash\n" + body, bin, name)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent(name).path)
        return ["PATH": "\(bin.path):\(fake.binDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"]
    }

    /// 28 is also curl's timeout code: once the backup is ready, a failure with status 28 must
    /// restore the previous version and start it again like any other failure.
    func testExit28AfterTheBackupIsReadyStillRestoresAndRestarts() throws {
        let (fake, root) = try installed("exit28-after-backup")
        let versionsBefore = data(root, ".oases-cpa-versions")
        let configBefore = data(root, "cli-proxy-api/config.yaml")
        let environment = try shadowingTool(fake, "tar", """
        if [ "$1" = "-xzf" ]; then case "$2" in */.oases-cpa-upgrade-*/cli-proxy-api/*) exit 28 ;; esac; fi
        exec /usr/bin/tar "$@"

        """)
        let result = try upgrade(try fake.withGateway(version: "0.9.1-test"), root, extraEnvironment: environment)
        XCTAssertEqual(result.status, 28, result.stderr)
        XCTAssertTrue(result.stderr.contains("正在恢复升级前的版本"), result.stderr)
        XCTAssertEqual(data(root, ".oases-cpa-versions"), versionsBefore)
        XCTAssertEqual(data(root, "cli-proxy-api/config.yaml"), configBefore)
        XCTAssertEqual(link(root, "gateway/current"), fake.gatewayVersion)
        let pids = DeploymentScriptFragments.managedProcesses(topology: .gateway).compactMap { pid(root, $0.pidFile) }
        XCTAssertEqual(pids.count, 3, "the previous version was started again")
        for pid in pids { XCTAssertEqual(kill(pid, 0), 0, "\(pid) runs") }
    }

    /// A backup that failed half way is moved to backups/incomplete-* (never deleted), so a
    /// later rollback cannot take it for the newest backup.
    func testFailedBackupCopyMovesThePartialBackupAsideAndRollbackFindsNone() throws {
        let (fake, root) = try installed("partial-backup")
        let counter = fake.caseDirectory.appendingPathComponent("cp-count")
        let environment = try shadowingTool(fake, "cp", """
        for arg in "$@"; do
          case "$arg" in
            */backups/upgrade-*)
              n="$(cat '\(counter.path)' 2>/dev/null || echo 0)"; n=$((n + 1)); printf '%s\\n' "$n" > '\(counter.path)'
              [ "$n" -ne 3 ] || exit 1
              break ;;
          esac
        done
        exec /bin/cp "$@"

        """)
        let versionsBefore = data(root, ".oases-cpa-versions")
        let failed = try upgrade(try fake.withGateway(version: "0.9.1-test"), root, extraEnvironment: environment)
        XCTAssertNotEqual(failed.status, 0)
        XCTAssertTrue(failed.stderr.contains("升级在备份完成前失败"), failed.stderr)
        XCTAssertEqual(upgradeBackups(root), [], "no upgrade-* directory is left")
        let incomplete = ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("backups").path)) ?? [])
            .filter { $0.hasPrefix("incomplete-") }
        XCTAssertEqual(incomplete.count, 1, "the partial backup is kept: \(incomplete)")
        let kept = try XCTUnwrap(incomplete.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups/\(kept)/cli-proxy-api-run.sh").path))
        XCTAssertEqual(data(root, ".oases-cpa-versions"), versionsBefore)
        let pids = DeploymentScriptFragments.managedProcesses(topology: .gateway).compactMap { pid(root, $0.pidFile) }
        for pid in pids { XCTAssertEqual(kill(pid, 0), 0, "\(pid) runs again") }

        let rolledBack = try rollback(fake, root)
        XCTAssertEqual(rolledBack.status, 19, rolledBack.stderr)
        XCTAssertEqual(data(root, ".oases-cpa-versions"), versionsBefore, "nothing was moved aside")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("gateway-data").path))
    }

    /// A backup this app started (marker `backup-started`) without its last marker
    /// (`backup-complete`, written after the last copy) is refused by the rollback; a backup
    /// without any marker (app 0.1.4 and earlier builds) is still accepted.
    func testRollbackRefusesABackupWithoutItsCompletionMarker() throws {
        let (fake, root) = try installed("backup-marker")
        XCTAssertEqual(try upgrade(try fake.withGateway(version: "0.9.1-test"), root).status, 0)
        let backup = try XCTUnwrap(upgradeBackups(root).last)
        let complete = root.appendingPathComponent("backups/\(backup)/backup-complete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups/\(backup)/backup-started").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: complete.path))
        try FileManager.default.removeItem(at: complete)
        let versions = data(root, ".oases-cpa-versions")

        let refused = try rollback(fake, root)
        XCTAssertEqual(refused.status, 19, refused.stderr)
        XCTAssertTrue(refused.stderr.contains("不完整"), refused.stderr)
        XCTAssertEqual(data(root, ".oases-cpa-versions"), versions)
        XCTAssertFalse(try fake.run(maintenance.latestBackupScriptForVerification(installDirectory: root.path)).stdout.contains("OASES_CPA_BACKUP="),
                       "an incomplete backup is not offered")
    }

    /// The Docker rollback keeps the current compose.yaml and .env inside the backup before it
    /// puts the backup's copies back.
    func testDockerRollbackKeepsTheCurrentComposeAndEnvAside() throws {
        let fake = try FakeArtifacts.make(caseName: "docker-rollback-keeps")
        let root = fake.caseDirectory.appendingPathComponent("root", isDirectory: true)
        try write("", root, ".oases-cpa-installed")
        try write("services:\n  cpa:\n    image: before\n", root, "compose.yaml")
        try write("CPA_PORT=8317\n", root, ".env")
        let environment = try shadowingTool(fake, "docker", "exit 0\n")
        XCTAssertEqual(try fake.run(maintenance.upgradeScriptForVerification(method: .docker, installDirectory: root.path, pins: fake.pins),
                                    extraEnvironment: environment).status, 0)
        try write("services:\n  cpa:\n    image: edited-after\n", root, "compose.yaml")
        try write("CPA_PORT=9999\n", root, ".env")

        let rolledBack = try fake.run(maintenance.rollbackScriptForVerification(method: .docker, installDirectory: root.path), extraEnvironment: environment)
        XCTAssertEqual(rolledBack.status, 0, rolledBack.stderr)
        XCTAssertEqual(text(root, "compose.yaml"), "services:\n  cpa:\n    image: before\n")
        XCTAssertEqual(text(root, ".env"), "CPA_PORT=8317\n")
        let backup = try XCTUnwrap(upgradeBackups(root).last)
        XCTAssertEqual(text(root, "backups/\(backup)/compose.yaml.after-upgrade"), "services:\n  cpa:\n    image: edited-after\n")
        XCTAssertEqual(text(root, "backups/\(backup)/.env.after-upgrade"), "CPA_PORT=9999\n")
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

    // MARK: - Batch-6 review follow-ups (batch 7a, step 0)

    /// A Docker backup that fails half way is moved to backups/incomplete-* (never deleted) like
    /// the native one, so the rollback still uses the older COMPLETE backup instead of exiting 19.
    func testFailedDockerBackupIsSetAsideAndRollbackUsesTheOlderCompleteBackup() throws {
        let fake = try FakeArtifacts.make(caseName: "docker-partial-backup")
        let root = fake.caseDirectory.appendingPathComponent("root", isDirectory: true)
        try write("", root, ".oases-cpa-installed")
        try write("services:\n  cpa:\n    image: before\n", root, "compose.yaml")
        try write("CPA_PORT=8317\n", root, ".env")
        let bin = fake.caseDirectory.appendingPathComponent("docker-partial-bin", isDirectory: true)
        let failFlag = fake.caseDirectory.appendingPathComponent("fail-env-copy")
        try write("#!/bin/bash\nexit 0\n", bin, "docker")
        try write("""
        #!/bin/bash
        if [ -f '\(failFlag.path)' ]; then
          for arg in "$@"; do case "$arg" in */backups/upgrade-*/.env) exit 1 ;; esac; done
        fi
        exec /bin/cp "$@"

        """, bin, "cp")
        for tool in ["docker", "cp"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent(tool).path)
        }
        let environment = ["PATH": "\(bin.path):\(fake.binDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"]
        let script = maintenance.upgradeScriptForVerification(method: .docker, installDirectory: root.path, pins: fake.pins)
        let first = try fake.run(script, extraEnvironment: environment)
        XCTAssertEqual(first.status, 0, first.stderr)
        let complete = try XCTUnwrap(upgradeBackups(root).last)
        try write("services:\n  cpa:\n    image: after-first-upgrade\n", root, "compose.yaml")

        try write("", fake.caseDirectory, "fail-env-copy")
        let failed = try fake.run(script, extraEnvironment: environment)
        XCTAssertNotEqual(failed.status, 0)
        XCTAssertTrue(failed.stderr.contains("升级在备份完成前失败"), failed.stderr)
        XCTAssertEqual(upgradeBackups(root), [complete], "only the complete backup is left as upgrade-*")
        let incomplete = ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("backups").path)) ?? [])
            .filter { $0.hasPrefix("incomplete-") }
        XCTAssertEqual(incomplete.count, 1, "the partial backup is kept: \(incomplete)")
        let kept = try XCTUnwrap(incomplete.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups/\(kept)/backup-started").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups/\(kept)/backup-complete").path))
        XCTAssertEqual(text(root, "compose.yaml"), "services:\n  cpa:\n    image: after-first-upgrade\n", "nothing else changed")

        try FileManager.default.removeItem(at: failFlag) // the test's own scratch file: copies work again
        let rolledBack = try fake.run(maintenance.rollbackScriptForVerification(method: .docker, installDirectory: root.path), extraEnvironment: environment)
        XCTAssertEqual(rolledBack.status, 0, rolledBack.stderr)
        XCTAssertEqual(text(root, "compose.yaml"), "services:\n  cpa:\n    image: before\n", "the older complete backup was used")
        XCTAssertTrue(rolledBack.stdout.contains("OASES_CPA_BACKUP=\(root.appendingPathComponent("backups/\(complete)").path)"), rolledBack.stdout)
    }

    // MARK: - Legacy migration safety (2026-11-08): data backup, ownership marker, failure reasons

    /// Every regular file under `relative` (path relative to it → bytes).
    private func snapshot(_ root: URL, _ relative: String) -> [String: Data] {
        let base = root.appendingPathComponent(relative)
        var files: [String: Data] = [:]
        for path in (try? FileManager.default.subpathsOfDirectory(atPath: base.path)) ?? [] {
            var isDirectory: ObjCBool = false
            let url = base.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            files[path] = try? Data(contentsOf: url)
        }
        return files
    }

    private func mode(_ root: URL, _ relative: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(relative).path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func exists(_ root: URL, _ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
    }

    /// CPA Manager Plus data like a 0.1.x deployment has it: the SQLite file with -wal/-shm,
    /// data.key and an import (synthetic bytes; the fakes never open them).
    private func addLegacyPanelData(_ root: URL) throws {
        try write("SQLite format 3\u{0}synthetic-usage-rows\n", root, "cpamp/data/usage.sqlite")
        try write("synthetic-wal\n", root, "cpamp/data/usage.sqlite-wal")
        try write("synthetic-shm\n", root, "cpamp/data/usage.sqlite-shm")
        try write("synthetic-data-key-for-the-fake-panel\n", root, "cpamp/data/data.key")
        try write("{\"rows\":2}\n", root, "cpamp/data/usage-imports/import-1.json")
    }

    /// The fake `/healthz` answers one fixed version: after a restore it must be the installed one.
    private func restoredHealthz(_ fake: FakeArtifacts) -> [String: String] {
        ["FAKE_HEALTHZ_BODY": "{\"ok\":true,\"version\":\"\(fake.gatewayVersion)\"}"]
    }

    private func failure(_ result: FakeArtifacts.RunResult) -> UpgradeFailure? {
        UpgradeFailure(standardError: result.stderr)
    }

    func testLegacyMigrationBacksUpPanelDataKeysAndMarkersAndRollbackRestoresThem() throws {
        let fake = try FakeArtifacts.make(caseName: "migrate-data-backup")
        let root = try legacyLayout(fake, managedMarker: nil)
        try addLegacyPanelData(root)
        try startLegacy(fake, root)
        let dataBefore = snapshot(root, "cpamp/data")
        let secretsBefore = snapshot(root, "secrets")
        let installedMarker = data(root, ".oases-cpa-installed")
        XCTAssertEqual(dataBefore.count, 6)
        XCTAssertFalse(exists(root, ".oases-cpa-managed"))

        let upgraded = try upgrade(fake, root, extraEnvironment: migrationEnvironment(root))
        XCTAssertEqual(upgraded.status, 0, upgraded.stderr)
        let backup = "backups/" + (try XCTUnwrap(upgradeBackups(root).last))
        XCTAssertEqual(mode(root, backup), 0o700)
        XCTAssertEqual(snapshot(root, "\(backup)/cpamp-data"), dataBefore, "cpamp/data in the backup byte for byte")
        XCTAssertEqual(snapshot(root, "\(backup)/secrets"), secretsBefore)
        XCTAssertEqual(data(root, "\(backup)/root-files/.oases-cpa-installed"), installedMarker)
        for pidFile in ["cli-proxy-api.pid", "cpa-manager-plus.pid"] {
            XCTAssertTrue(exists(root, "\(backup)/root-files/\(pidFile)"), pidFile)
        }
        XCTAssertTrue(exists(root, "\(backup)/root-files/managed-marker.absent"))
        // After every health check: the installer's ownership marker, 0600.
        XCTAssertEqual(text(root, ".oases-cpa-managed"), "owned-by=oases-cpa\n")
        XCTAssertEqual(mode(root, ".oases-cpa-managed"), 0o600)

        // The newer CPA Manager Plus migrates its database forward and records more usage.
        try write("SQLite format 3\u{0}migrated-forward\n", root, "cpamp/data/usage.sqlite")
        try write("new\n", root, "cpamp/data/only-after-upgrade.bin")

        let rolledBack = try rollback(fake, root)
        XCTAssertEqual(rolledBack.status, 0, rolledBack.stderr)
        XCTAssertTrue(rolledBack.stdout.contains("OASES_CPA_TOPOLOGY=legacy"))
        XCTAssertEqual(snapshot(root, "cpamp/data"), dataBefore, "cpamp/data back byte for byte")
        let keptData = snapshot(root, "\(backup)/cpamp-data-after-upgrade")
        XCTAssertEqual(keptData["usage.sqlite"], Data("SQLite format 3\u{0}migrated-forward\n".utf8), "moved, not deleted")
        XCTAssertNotNil(keptData["only-after-upgrade.bin"])
        XCTAssertEqual(snapshot(root, "secrets"), secretsBefore, "the keys as before the migration")
        XCTAssertEqual(mode(root, "secrets"), 0o700)
        for packKey in ["pack-engine-key", "pack-store-key"] {
            XCTAssertTrue(exists(root, "\(backup)/secrets-after-upgrade/\(packKey)"), "\(packKey) kept in the backup")
        }
        XCTAssertFalse(exists(root, ".oases-cpa-managed"), "a restored 0.1.x root has no marker, as before")
        XCTAssertEqual(text(root, "\(backup)/oases-cpa-managed.after-upgrade"), "owned-by=oases-cpa\n")
        XCTAssertEqual(data(root, ".oases-cpa-installed"), installedMarker)
        XCTAssertNotNil(pid(root, "cli-proxy-api.pid"))
        XCTAssertNotNil(pid(root, "cpa-manager-plus.pid"))
        XCTAssertNil(pid(root, "gateway.pid"))
    }

    /// A gateway upgrade with the same CPA Manager Plus keeps the usage recorded since then:
    /// the data only comes back when the rollback changes the CPA Manager Plus binary.
    func testRollbackWithTheSamePanelBinaryKeepsTheNewerPanelData() throws {
        let (fake, root) = try installed("same-panel-data")
        try write("before\n", root, "cpamp/data/usage.sqlite")
        XCTAssertEqual(try upgrade(try fake.withGateway(version: "0.9.1-test"), root).status, 0)
        try write("after\n", root, "cpamp/data/usage.sqlite")
        XCTAssertEqual(try rollback(fake, root).status, 0)
        XCTAssertEqual(text(root, "cpamp/data/usage.sqlite"), "after\n")
        XCTAssertEqual(text(root, ".oases-cpa-managed"), "owned-by=oases-cpa\n", "the installer's marker stays")
    }

    func testExistingOwnershipMarkersAreKeptAndAForeignOneIsNeverOverwritten() throws {
        let ours = try FakeArtifacts.make(caseName: "migrate-marker-ours")
        let oursRoot = try legacyLayout(ours)
        let result = try upgrade(ours, oursRoot, extraEnvironment: migrationEnvironment(oursRoot))
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(text(oursRoot, ".oases-cpa-managed"), "owned-by=oases-cpa\n")
        XCTAssertEqual(try rollback(ours, oursRoot).status, 0)
        XCTAssertEqual(text(oursRoot, ".oases-cpa-managed"), "owned-by=oases-cpa\n", "a marker that was there before stays")

        let foreign = try FakeArtifacts.make(caseName: "migrate-marker-foreign")
        let foreignRoot = try legacyLayout(foreign, managedMarker: "owned-by=someone-else\n")
        let foreignResult = try upgrade(foreign, foreignRoot, extraEnvironment: migrationEnvironment(foreignRoot))
        XCTAssertEqual(foreignResult.status, 0, foreignResult.stderr)
        XCTAssertEqual(text(foreignRoot, ".oases-cpa-managed"), "owned-by=someone-else\n")
        XCTAssertTrue(foreignResult.stderr.contains("已有另一个 .oases-cpa-managed 标记"), foreignResult.stderr)
    }

    func testNoMarkerIsWrittenWithoutTheLegacyInstallMarker() throws {
        let fake = try FakeArtifacts.make(caseName: "migrate-no-installed")
        let root = try legacyLayout(fake, managedMarker: nil)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".oases-cpa-installed"))
        let result = try upgrade(fake, root, extraEnvironment: migrationEnvironment(root))
        XCTAssertEqual(result.status, 18, result.stderr)
        XCTAssertFalse(exists(root, ".oases-cpa-managed"))
        XCTAssertEqual(upgradeBackups(root), [])
    }

    /// A migration that fails after the backup (the api-keys step) restores cpamp/data and the
    /// keys, writes no marker, and reports a localized reason with the outcome.
    func testFailedMigrationRestoresDataLeavesNoMarkerAndReportsWhy() throws {
        let fake = try FakeArtifacts.make(caseName: "migrate-fails")
        let root = try legacyLayout(fake, managedMarker: nil)
        try addLegacyPanelData(root)
        try startLegacy(fake, root)
        let dataBefore = snapshot(root, "cpamp/data")
        let secretsBefore = snapshot(root, "secrets")
        let configBefore = data(root, "cli-proxy-api/config.yaml")

        var environment = migrationEnvironment(root)
        environment["FAKE_NODE_E_EXIT"] = "5"
        let result = try upgrade(fake, root, extraEnvironment: environment)
        XCTAssertEqual(result.status, 27, result.stderr)
        XCTAssertFalse(exists(root, ".oases-cpa-managed"), "no marker after a failed migration")
        XCTAssertEqual(snapshot(root, "cpamp/data"), dataBefore)
        XCTAssertEqual(snapshot(root, "secrets"), secretsBefore)
        XCTAssertEqual(data(root, "cli-proxy-api/config.yaml"), configBefore)
        XCTAssertNil(pid(root, "gateway.pid"))
        XCTAssertNotNil(pid(root, "cli-proxy-api.pid"), "the old version runs again")

        let parsed = try XCTUnwrap(failure(result), result.stderr)
        XCTAssertEqual(parsed.stage, "migration-keys")
        XCTAssertEqual(parsed.status, 27)
        XCTAssertEqual(parsed.changes, .restored)
        XCTAssertEqual(parsed.running, .yes)
        let error = DeploymentMaintenanceService.mapError(.nonZero(status: 27, standardOutput: "", standardError: result.stderr))
        guard case .upgradeFailed(let mapped) = error else { return XCTFail("\(error)") }
        XCTAssertEqual(mapped, parsed)
        let english = parsed.message(language: .english)
        XCTAssertTrue(english.hasPrefix("Upgrade failed: The Oases gateway's internal key could not be added"), english)
        XCTAssertTrue(english.contains("The previous version was restored automatically"), english)
        XCTAssertTrue(parsed.message(language: .simplifiedChinese).contains("已自动恢复升级前的版本"))
        XCTAssertFalse(english.contains(root.path), "no raw stderr")
    }

    /// A port of the gateway topology held by another program: refused before the backup
    /// (exit 29), nothing changed, the old version started again.
    func testBusyPortRefusesBeforeTheBackupAndRestartsTheOldVersion() throws {
        let (fake, root) = try installed("busy-port")
        let versions = data(root, ".oases-cpa-versions")
        let busy = try FakeArtifacts.boundLoopbackSocket(port: ports.gatewayAdmin, listen: true)
        defer { close(busy.fd) }
        let result = try upgrade(try fake.withGateway(version: "0.9.1-test"), root, extraEnvironment: restoredHealthz(fake))
        XCTAssertEqual(result.status, 29, result.stderr)
        XCTAssertTrue(result.stderr.contains("OASES_UPGRADE_PORT_BUSY port=\(ports.gatewayAdmin)"), result.stderr)
        XCTAssertEqual(upgradeBackups(root), [], "refused before the backup")
        XCTAssertEqual(data(root, ".oases-cpa-versions"), versions)
        XCTAssertEqual(link(root, "gateway/current"), fake.gatewayVersion)
        let pids = DeploymentScriptFragments.managedProcesses(topology: .gateway).compactMap { pid(root, $0.pidFile) }
        XCTAssertEqual(pids.count, 3)
        for pid in pids { XCTAssertEqual(kill(pid, 0), 0, "\(pid) runs again") }
        let parsed = try XCTUnwrap(failure(result), result.stderr)
        XCTAssertEqual([parsed.stage, parsed.changes.rawValue, parsed.running.rawValue], ["ports", "unchanged", "yes"])
        XCTAssertEqual(parsed.busyPort, ports.gatewayAdmin)
        let english = parsed.message(language: .english)
        XCTAssertTrue(english.contains("Port \(ports.gatewayAdmin) is in use by another program"), english)
        XCTAssertTrue(english.contains("Nothing was changed"), english)
        XCTAssertTrue(parsed.message(language: .simplifiedChinese).contains("端口 \(ports.gatewayAdmin) 已被其他程序占用"))
    }

    /// A download that fails after the backup restores the previous version, which runs again.
    func testDownloadFailureRestoresAndNamesTheComponent() throws {
        let (fake, root) = try installed("download-fails")
        let versions = data(root, ".oases-cpa-versions")
        let environment = try shadowingTool(fake, "curl", """
        for arg in "$@"; do case "$arg" in */releases/download/*cpa-manager-plus*) exit 6 ;; esac; done
        exec '\(fake.binDirectory.appendingPathComponent("curl").path)' "$@"

        """).merging(restoredHealthz(fake)) { $1 }
        let result = try upgrade(try fake.withGateway(version: "0.9.1-test"), root, extraEnvironment: environment)
        XCTAssertEqual(result.status, 18, result.stderr)
        XCTAssertEqual(data(root, ".oases-cpa-versions"), versions)
        XCTAssertEqual(link(root, "gateway/current"), fake.gatewayVersion)
        let parsed = try XCTUnwrap(failure(result), result.stderr)
        XCTAssertEqual([parsed.stage, parsed.changes.rawValue, parsed.running.rawValue], ["cpamp", "restored", "yes"])
        XCTAssertTrue(parsed.message(language: .english).contains("Downloading CPA Manager Plus failed"), parsed.message(language: .english))
        XCTAssertTrue(parsed.message(language: .simplifiedChinese).contains("下载 CPA Manager Plus 失败"))
    }

    func testChecksumFailureRestoresAndNamesTheComponent() throws {
        let (fake, root) = try installed("checksum-fails")
        let next = try fake.withGateway(version: "0.9.1-test")
        let wrongEngine = PinnedArtifact(tag: next.pins.engine.tag, assets: next.pins.engine.assets.mapValues {
            PinnedAsset(fileName: $0.fileName, sha256: String(repeating: "0", count: 64))
        })
        let pins = DeploymentPinSet(engine: wrongEngine, cpamp: next.pins.cpamp, node: next.pins.node, gateway: next.pins.gateway,
                                    cliDockerImage: next.pins.cliDockerImage, cpampDockerImage: next.pins.cpampDockerImage)
        let result = try next.run(maintenance.upgradeScriptForVerification(
            method: .native, installDirectory: root.path, pins: pins,
            gatewayPayloadBase64: next.gatewayPayloadBase64, ports: ports, healthAttempts: 3), extraEnvironment: restoredHealthz(fake))
        XCTAssertEqual(result.status, 17, result.stderr)
        let parsed = try XCTUnwrap(failure(result), result.stderr)
        XCTAssertEqual([parsed.stage, parsed.changes.rawValue, parsed.running.rawValue], ["engine", "restored", "yes"])
        XCTAssertTrue(parsed.message(language: .english).contains("The CLIProxyAPI download did not pass the pinned SHA-256 check"))
        XCTAssertEqual(link(root, "gateway/current"), fake.gatewayVersion)
    }

    /// The migrated engine never answers on its new port: restored, the legacy engine (its own
    /// port) answers again.
    func testMigratedEngineThatDoesNotStartIsReportedAndTheLegacyVersionRunsAgain() throws {
        let fake = try FakeArtifacts.make(caseName: "migrate-engine-down")
        let root = try legacyLayout(fake, managedMarker: nil)
        try startLegacy(fake, root)
        var environment = try shadowingTool(fake, "curl", """
        for arg in "$@"; do case "$arg" in *:\(ports.engine)/v0/management/*) exit 7 ;; esac; done
        exec '\(fake.binDirectory.appendingPathComponent("curl").path)' "$@"

        """)
        environment.merge(migrationEnvironment(root)) { $1 }
        let result = try upgrade(fake, root, extraEnvironment: environment)
        XCTAssertEqual(result.status, 27, result.stderr)
        XCTAssertTrue(text(root, "cli-proxy-api/config.yaml").contains("port: 8317"))
        XCTAssertFalse(exists(root, ".oases-cpa-managed"))
        let parsed = try XCTUnwrap(failure(result), result.stderr)
        XCTAssertEqual([parsed.stage, parsed.changes.rawValue, parsed.running.rawValue], ["migration-engine", "restored", "yes"])
        XCTAssertTrue(parsed.message(language: .english).contains("The new CLIProxyAPI did not start on its new port"))
    }

    /// The upgraded gateway never becomes healthy: everything is restored; the restored gateway
    /// (same fake setting) fails too, which the outcome says instead of claiming success.
    func testHealthTimeoutIsReportedWithAnHonestOutcome() throws {
        let (fake, root) = try installed("health-timeout")
        let result = try upgrade(try fake.withGateway(version: "0.9.1-test"), root, extraEnvironment: ["FAKE_GATEWAY_EXIT": "1"])
        XCTAssertEqual(result.status, 26, result.stderr)
        let parsed = try XCTUnwrap(failure(result), result.stderr)
        XCTAssertEqual([parsed.stage, parsed.changes.rawValue, parsed.running.rawValue], ["health", "restored", "no"])
        let english = parsed.message(language: .english)
        XCTAssertTrue(english.contains("did not pass their health checks in time"), english)
        XCTAssertTrue(english.contains("but the previous services did not pass their health checks"), english)
    }

    func testUpgradeFailureParsingAcceptsOnlyKnownValues() {
        let good = "x\nOASES_UPGRADE_FAILURE stage=engine status=18\nOASES_UPGRADE_OUTCOME changes=restored running=yes\n"
        XCTAssertNotNil(UpgradeFailure(standardError: good))
        for bad in [
            "OASES_UPGRADE_FAILURE stage=$(id) status=18\nOASES_UPGRADE_OUTCOME changes=restored running=yes",
            "OASES_UPGRADE_FAILURE stage=engine status=x\nOASES_UPGRADE_OUTCOME changes=restored running=yes",
            "OASES_UPGRADE_FAILURE stage=engine status=18\nOASES_UPGRADE_OUTCOME changes=gone running=yes",
            "OASES_UPGRADE_FAILURE stage=engine status=18",
        ] {
            XCTAssertNil(UpgradeFailure(standardError: bad), bad)
            guard case .commandFailed = DeploymentMaintenanceService.mapError(.nonZero(status: 18, standardOutput: "", standardError: bad)) else {
                return XCTFail(bad)
            }
        }
        // Every stage has a reason in both languages; an unknown pair gets a generic one.
        for stage in UpgradeFailure.stages {
            let failure = UpgradeFailure(standardError: "OASES_UPGRADE_FAILURE stage=\(stage) status=1\nOASES_UPGRADE_OUTCOME changes=unchanged running=yes")
            for language in [AppLanguage.simplifiedChinese, .english] {
                XCTAssertFalse((failure?.reason(language: language) ?? "").isEmpty, stage)
            }
        }
        let generic = UpgradeFailure(standardError: "OASES_UPGRADE_FAILURE stage=finalize status=1\nOASES_UPGRADE_OUTCOME changes=restore_incomplete running=no")
        XCTAssertEqual(generic?.reason(language: .english), "The upgrade failed in the “finalize” phase (exit code 1).")
        XCTAssertTrue(generic?.outcome(language: .english).contains("Use Roll Back") == true)
    }
}
