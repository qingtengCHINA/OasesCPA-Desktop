import CryptoKit
import XCTest
@testable import OasesCPA

/// The fresh native install script, run for real with `/bin/bash` against fake packages and
/// fake tools (`FakeArtifacts`): no network, no real binaries, no listening sockets. Install
/// roots live in scratch case directories under `$OASES_SCRATCH`, never under the real home.
final class NativeInstallScriptTests: XCTestCase {
    private var startedRoots: [(FakeArtifacts, URL)] = []

    override func tearDown() {
        for (fake, root) in startedRoots { fake.stopProcesses(under: root) }
        startedRoots.removeAll()
        super.tearDown()
    }

    private struct Install {
        let fake: FakeArtifacts
        let root: URL
        let result: FakeArtifacts.RunResult

        func text(_ relative: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        }

        func key(_ name: String) throws -> String {
            try text("secrets/\(name)").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func install(
        _ fake: FakeArtifacts,
        prelude: String = "",
        prepareRoot: ((URL) throws -> Void)? = nil,
        extraEnvironment: [String: String] = [:],
        gatewayHealthAttempts: Int = DeploymentExecutor.gatewayHealthAttempts
    ) throws -> Install {
        let root = fake.caseDirectory.appendingPathComponent("root", isDirectory: true)
        try prepareRoot?(root)
        let script = DeploymentExecutor().scriptForVerification(
            method: .native,
            installDirectory: root.path,
            pins: fake.pins,
            gatewayPayloadBase64: fake.gatewayPayloadBase64,
            gatewayHealthAttempts: gatewayHealthAttempts
        )
        startedRoots.append((fake, root))
        let result = try fake.run(script, prelude: prelude, extraEnvironment: extraEnvironment)
        return Install(fake: fake, root: root, result: result)
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func linkDestination(_ url: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    private func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The variables `gateway/run.sh` exports, read by running only its `export` lines in an
    /// empty environment.
    private func exportedEnvironment(of runScript: URL) throws -> [String: String] {
        let lines = try String(contentsOf: runScript, encoding: .utf8)
            .split(separator: "\n")
            .filter { $0.hasPrefix("export ") }
            .joined(separator: "\n")
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

    private func versions(_ install: Install) throws -> [String: String] {
        let data = try Data(contentsOf: install.root.appendingPathComponent(".oases-cpa-versions"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    // MARK: - Named contract tests

    func testFreshInstallLaysOutInterfaceDirectoriesAndVersions() throws {
        let fake = try FakeArtifacts.make(caseName: "layout")
        let run = try install(fake)
        XCTAssertEqual(run.result.status, 0, run.result.stderr)

        let root = run.root
        let fileManager = FileManager.default
        let nodeTag = fake.pins.node.tag
        let gatewayVersion = fake.gatewayVersion
        for path in [
            "node/\(nodeTag)/bin/node",
            "gateway/\(gatewayVersion)/bootstrap.mjs",
            "gateway/\(gatewayVersion)/server.mjs",
            "gateway/run.sh",
            "gateway-data/permissions.json",
            "secrets/cpa-management-key",
            "secrets/cpamp-admin-key",
            "secrets/pack-engine-key",
            "secrets/pack-store-key",
            "cpamp/config.json",
            "cpamp/run.sh",
            "cli-proxy-api/run.sh",
            "cli-proxy-api/config.yaml",
            ".oases-cpa-installed",
            ".oases-cpa-managed",
        ] {
            XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent(path).path), path)
        }
        XCTAssertEqual(try linkDestination(root.appendingPathComponent("node/current")), nodeTag)
        XCTAssertEqual(try linkDestination(root.appendingPathComponent("gateway/current")), gatewayVersion)
        XCTAssertEqual(try mode(of: root.appendingPathComponent("gateway/run.sh")), 0o755)
        XCTAssertEqual(try mode(of: root.appendingPathComponent("gateway-data/permissions.json")), 0o600)
        for secret in ["cpa-management-key", "cpamp-admin-key", "pack-engine-key", "pack-store-key"] {
            XCTAssertEqual(try mode(of: root.appendingPathComponent("secrets/\(secret)")), 0o600, secret)
        }
        XCTAssertEqual(try versions(run), [
            "engine": FakeArtifacts.engineTag,
            "cpamp": FakeArtifacts.cpampTag,
            "node": nodeTag,
            "gateway": gatewayVersion,
        ])
        // One key per line, in a fixed order (the upgrade scripts read it with sed).
        XCTAssertEqual(try run.text(".oases-cpa-versions"), """
        {
          "engine": "\(FakeArtifacts.engineTag)",
          "cpamp": "\(FakeArtifacts.cpampTag)",
          "node": "\(nodeTag)",
          "gateway": "\(gatewayVersion)"
        }

        """)
        // The three processes were started, the gateway last, by their run.sh.
        for pid in ["cli-proxy-api.pid", "cpa-manager-plus.pid", "gateway.pid"] {
            XCTAssertTrue(fileManager.fileExists(atPath: root.appendingPathComponent(pid).path), pid)
        }
        XCTAssertFalse(fileManager.fileExists(atPath: root.appendingPathComponent(".oases-cpa-installing").path))
        // Node is the pinned one, never one found on the target.
        XCTAssertTrue(fake.argv().contains("node --version"))
        let log = try run.text("logs/deployment.log")
        XCTAssertTrue(log.contains("部署阶段：install-node"))
        XCTAssertTrue(log.contains("部署阶段：bootstrap-gateway"))
        XCTAssertTrue(log.contains("\"ok\":true"), "the bootstrap summary goes to the deployment log")
    }

    func testAllListenersBindLoopback() throws {
        let fake = try FakeArtifacts.make(caseName: "loopback")
        let run = try install(fake)
        XCTAssertEqual(run.result.status, 0, run.result.stderr)
        let root = run.root.path

        let config = try run.text("cli-proxy-api/config.yaml")
        let lines = config.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertTrue(lines.contains("host: \"127.0.0.1\""))
        XCTAssertTrue(lines.contains("port: 18316"))
        XCTAssertFalse(lines.contains("port: 8317"))
        let compression = try XCTUnwrap(lines.firstIndex(of: "response-compression:"))
        XCTAssertEqual(lines[compression + 1], "  enabled: false")
        // The legacy layout the gateway reads: a top-level api-keys list holding the internal key.
        let apiKeys = try XCTUnwrap(lines.firstIndex(of: "api-keys:"))
        XCTAssertEqual(lines[apiKeys + 1], "  - \"\(try run.key("pack-engine-key"))\"")
        XCTAssertFalse(config.contains("api-keys: []"))
        XCTAssertTrue(config.contains("allow-remote: false"))
        XCTAssertTrue(config.contains("disable-control-panel: false"), "L3: kept until a probe shows true is safe")

        let cpamp = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try run.text("cpamp/config.json").utf8)) as? [String: Any])
        XCTAssertEqual(cpamp["httpAddr"] as? String, "127.0.0.1:18317")
        XCTAssertEqual(cpamp["cpaUpstreamUrl"] as? String, "http://127.0.0.1:18316")
        XCTAssertEqual(cpamp["dataDir"] as? String, "\(root)/cpamp/data")
        XCTAssertEqual(cpamp["adminKeyFile"] as? String, "\(root)/secrets/cpamp-admin-key")
        XCTAssertEqual(cpamp["dataKeyPath"] as? String, "\(root)/cpamp/data/data.key")
        XCTAssertEqual(cpamp["managementKeyFile"] as? String, "\(root)/secrets/cpa-management-key")
        for key in ["dataDir", "adminKeyFile", "dataKeyPath", "managementKeyFile"] {
            XCTAssertTrue((cpamp[key] as? String)?.hasPrefix("/") == true, key)
        }

        let gateway = try exportedEnvironment(of: run.root.appendingPathComponent("gateway/run.sh"))
        let versions = try versions(run)
        XCTAssertEqual(gateway, [
            "PORT": "8317",
            "BIND_HOST": "127.0.0.1",
            "ADMIN_LISTEN_PORT": "18320",
            "GO_BACKEND_URL": "http://127.0.0.1:18316",
            "CONFIG_PATH": "\(root)/cli-proxy-api/config.yaml",
            "KEY_FILE_PATH": "\(root)/secrets/cpa-management-key",
            "PACK_ENGINE_KEY_PATH": "\(root)/secrets/pack-engine-key",
            "PACK_STORE_KEY_FILE": "\(root)/secrets/pack-store-key",
            "OASES_DATA_DIR": "\(root)/gateway-data",
            "HOST_STATUS_ENGINE_VERSION": fake.pins.engine.tag,
            "HOST_STATUS_PANEL_VERSION": fake.pins.cpamp.tag,
        ])
        XCTAssertEqual(gateway["HOST_STATUS_ENGINE_VERSION"], versions["engine"])
        XCTAssertEqual(gateway["HOST_STATUS_PANEL_VERSION"], versions["cpamp"])
        let runScript = try run.text("gateway/run.sh")
        XCTAssertFalse(runScript.contains("HOST_STATUS_UNITS"))
        XCTAssertTrue(runScript.contains("exec 3>&- 4>&-"))
        XCTAssertTrue(runScript.contains("exec \(root)/node/current/bin/node \(root)/gateway/current/server.mjs"),
                      "node and server.mjs by absolute path, so ps shows the root")
        // The health checks of the install script only ever talk to loopback.
        let argv = fake.argv()
        XCTAssertTrue(argv.contains("http://127.0.0.1:18316/v0/management/config"))
        XCTAssertTrue(argv.contains("http://127.0.0.1:18317/health"))
        XCTAssertTrue(argv.contains("http://127.0.0.1:18320/healthz"))
        for line in argv.split(separator: "\n") where line.hasPrefix("curl") && line.contains("http://") {
            XCTAssertTrue(line.contains("http://127.0.0.1:"), String(line))
        }
    }

    func testDeploymentLogAndProcessArgumentsNeverContainGeneratedKeys() throws {
        let fake = try FakeArtifacts.make(caseName: "secrets")
        let run = try install(fake)
        XCTAssertEqual(run.result.status, 0, run.result.stderr)

        let keys = try ["cpa-management-key", "cpamp-admin-key", "pack-engine-key", "pack-store-key"].map { try run.key($0) }
        XCTAssertEqual(Set(keys).count, 4)
        for key in keys { XCTAssertGreaterThanOrEqual(key.count, 32) }
        let log = try run.text("logs/deployment.log")
        let argv = fake.argv()
        // stdout carries exactly the result lines for the app (fd 3); everything else must be free
        // of keys, and the two pack keys never appear on stdout at all.
        let resultPrefixes = ["OASES_CPA_MANAGEMENT_KEY=", "OASES_CPAMP_ADMIN_KEY="]
        let otherStdout = run.result.stdout.split(separator: "\n").filter { line in
            !resultPrefixes.contains(where: { line.hasPrefix($0) })
        }.joined(separator: "\n")
        for (index, key) in keys.enumerated() {
            XCTAssertFalse(log.contains(key), "deployment.log holds key #\(index)")
            XCTAssertFalse(argv.contains(key), "a process argument holds key #\(index)")
            XCTAssertFalse(run.result.stderr.contains(key), "stderr holds key #\(index)")
            XCTAssertFalse(otherStdout.contains(key), "stdout holds key #\(index) outside the result lines")
        }
        XCTAssertFalse(run.result.stdout.contains(keys[2]))
        XCTAssertFalse(run.result.stdout.contains(keys[3]))
        for name in ["cli-proxy-api.log", "cpa-manager-plus.log", "gateway.log"] {
            let text = (try? run.text("logs/\(name)")) ?? ""
            for key in keys { XCTAssertFalse(text.contains(key), name) }
        }
        // The readiness checks really used the stdin config file for the key.
        let keyed = argv.split(separator: "\n").filter { $0.contains("/v0/management/config") }
        XCTAssertFalse(keyed.isEmpty)
        for line in keyed {
            let words = line.split(separator: " ").map(String.init)
            let index = try XCTUnwrap(words.firstIndex(of: "-K"))
            XCTAssertEqual(words[index + 1], "-")
            XCTAssertFalse(line.contains("Authorization"))
        }
        // fd 3 returns the fingerprint of the internal engine key, never the key.
        let fingerprint = sha256Hex(keys[2])
        XCTAssertTrue(run.result.stdout.split(separator: "\n").contains("OASES_PACK_ENGINE_KEY_SHA256=\(fingerprint)"))
        let parsed = try DeploymentExecutor().parseResult(run.result.stdout)
        XCTAssertEqual(parsed.cpaManagementKey, keys[0])
        XCTAssertEqual(parsed.cpampAdminKey, keys[1])
        XCTAssertEqual(parsed.packEngineKeyFingerprint, fingerprint)
    }

    func testFreshInstallSucceedsUnderUmask002() throws {
        // The root starts 0775 (made under umask 002), like a plain mkdir on Ubuntu.
        let fake = try FakeArtifacts.make(caseName: "umask")
        let run = try install(fake, prelude: "umask 002") { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o775])
            XCTAssertEqual(try self.mode(of: root), 0o775)
        }
        XCTAssertEqual(run.result.status, 0, run.result.stderr)
        XCTAssertEqual(try mode(of: run.root.appendingPathComponent("secrets")), 0o700)
        XCTAssertEqual(try mode(of: run.root.appendingPathComponent("gateway-data")), 0o700)
        XCTAssertEqual(try mode(of: run.root) & 0o022, 0, "the install root loses group/other write permission")

        // A secrets directory that turns into a symlink before the keys are written: exit 25.
        let linked = try FakeArtifacts.make(caseName: "secrets-link")
        let swap = linked.binDirectory.appendingPathComponent("uname")
        try Data("""
        #!/bin/bash
        if [ "${1:-}" = "-s" ] && [ -d "$SWAP_ROOT/secrets" ] && [ ! -L "$SWAP_ROOT/secrets" ]; then
          mv "$SWAP_ROOT/secrets" "$SWAP_ROOT/secrets-real" && ln -s secrets-real "$SWAP_ROOT/secrets"
        fi
        exec /usr/bin/uname "$@"
        """.utf8).write(to: swap)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swap.path)
        let linkedRoot = linked.caseDirectory.appendingPathComponent("root")
        let refused = try install(linked, prelude: "umask 002", extraEnvironment: ["SWAP_ROOT": linkedRoot.path])
        XCTAssertEqual(refused.result.status, 25, refused.result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: linkedRoot.appendingPathComponent("secrets-real/cpa-management-key").path),
                       "no key is written through a symlinked secrets directory")

        // A symlinked install root: exit 25 before anything is created.
        let rootLink = try FakeArtifacts.make(caseName: "root-link")
        let target = rootLink.caseDirectory.appendingPathComponent("real-root")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let linkRun = try install(rootLink, prelude: "umask 002") { root in
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
        }
        XCTAssertEqual(linkRun.result.status, 25, linkRun.result.stderr)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testGatewayTarballTopLevelIsStripped() throws {
        let fake = try FakeArtifacts.make(caseName: "strip")
        let run = try install(fake)
        XCTAssertEqual(run.result.status, 0, run.result.stderr)
        let versionDirectory = run.root.appendingPathComponent("gateway/\(fake.gatewayVersion)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: versionDirectory.appendingPathComponent("server.mjs").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: versionDirectory.appendingPathComponent("oases-gateway_\(fake.gatewayVersion)").path))
        XCTAssertEqual(try String(contentsOf: versionDirectory.appendingPathComponent("VERSION"), encoding: .utf8), "\(fake.gatewayVersion)\n")

        let twoTops = try FakeArtifacts.make(caseName: "two-tops", gatewayExtraTopDirectory: "stray")
        let refused = try install(twoTops)
        XCTAssertEqual(refused.result.status, 24, refused.result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: refused.root.appendingPathComponent("gateway").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: refused.root.appendingPathComponent(".oases-cpa-installed").path))
    }

    func testGatewayChecksumMismatchExits24AndLeavesNoGatewayDir() throws {
        let fake = try FakeArtifacts.make(caseName: "gateway-sha", gatewaySHA256Override: String(repeating: "0", count: 64))
        let run = try install(fake)
        XCTAssertEqual(run.result.status, 24, run.result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.root.appendingPathComponent("gateway").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.root.appendingPathComponent(".oases-cpa-installed").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.root.appendingPathComponent("cli-proxy-api.pid").path), "nothing was started")
        XCTAssertTrue(run.result.stderr.contains("Oases 网关包校验失败"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.root.appendingPathComponent(".oases-cpa-failed").path))
    }

    func testBootstrapExit2SurfacesAsExit25() throws {
        let fake = try FakeArtifacts.make(caseName: "bootstrap-2")
        let run = try install(fake, extraEnvironment: ["FAKE_BOOTSTRAP_EXIT": "2"])
        XCTAssertEqual(run.result.status, 25, run.result.stderr)
        XCTAssertTrue(run.result.stderr.contains("bootstrap 退出码 2"), run.result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.root.appendingPathComponent("cli-proxy-api.pid").path))

        // The bootstrap's own refusal of a private-directory problem (3) surfaces the same way.
        let insecure = try FakeArtifacts.make(caseName: "bootstrap-3")
        let refused = try install(insecure, extraEnvironment: ["FAKE_BOOTSTRAP_EXIT": "3"])
        XCTAssertEqual(refused.result.status, 25)
        XCTAssertTrue(refused.result.stderr.contains("bootstrap 退出码 3"))
    }

    func testCPAMPRunScriptUsesFixedConfigPath() throws {
        let fake = try FakeArtifacts.make(caseName: "cpamp-config")
        let run = try install(fake)
        XCTAssertEqual(run.result.status, 0, run.result.stderr)
        let runScript = try run.text("cpamp/run.sh")
        XCTAssertTrue(runScript.contains("export CPA_MANAGER_CONFIG=\(run.root.path)/cpamp/config.json\n"))
        XCTAssertTrue(runScript.contains("exec 3>&- 4>&-"))
        let package = try XCTUnwrap(fake.pins.cpamp.assets.values.first?.fileName).replacingOccurrences(of: ".tar.gz", with: "")
        let runtime = run.root.appendingPathComponent("cpamp/runtime")
        let packages = try FileManager.default.contentsOfDirectory(atPath: runtime.path)
        XCTAssertEqual(packages.count, 1)
        XCTAssertTrue(packages[0].hasPrefix("cpa-manager-plus_\(FakeArtifacts.cpampTag)_"), package)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.appendingPathComponent(packages[0]).appendingPathComponent("config.json").path),
                       "no config.json inside the versioned runtime directory")
        let script = DeploymentExecutor().scriptForVerification(method: .native, installDirectory: "/x")
        XCTAssertFalse(script.contains("$CPAMP_BINARY_DIR/config.json"))
    }

    // MARK: - More behaviour

    func testGatewayThatDiesExits26() throws {
        let fake = try FakeArtifacts.make(caseName: "gateway-dies")
        // The fake gateway exits at once: the health wait ends without waiting 45 s.
        let run = try install(fake, extraEnvironment: ["FAKE_HEALTHZ_BODY": "{\"ok\":true,\"version\":\"other\"}", "FAKE_GATEWAY_EXIT": "1"])
        XCTAssertEqual(run.result.status, 26, run.result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.root.appendingPathComponent(".oases-cpa-installed").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.root.appendingPathComponent(".oases-cpa-versions").path))
    }

    /// Our gateway stays alive, but whatever answers the admin port reports another version
    /// (another program on 18320): the wait runs out (45 attempts in production, 3 here) and
    /// the install fails with 26 instead of trusting the foreign answer.
    func testForeignHealthzAnswerWhileOurGatewayRunsTimesOutWith26() throws {
        let fake = try FakeArtifacts.make(caseName: "gateway-foreign-healthz")
        let started = Date()
        let run = try install(
            fake,
            extraEnvironment: ["FAKE_HEALTHZ_BODY": "{\"ok\":true,\"version\":\"9.9.9-someone-else\"}"],
            gatewayHealthAttempts: 3
        )
        XCTAssertEqual(run.result.status, 26, run.result.stderr)
        XCTAssertTrue(run.result.stderr.contains("Oases 网关在 45 秒内没有通过健康检查。"), run.result.stderr)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 3, "every attempt was waited for")
        // It was the wait that ran out, not our gateway that died: its process is still ours.
        let pidText = try run.text("gateway.pid").trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidText))
        XCTAssertEqual(kill(pid, 0), 0, "our gateway is still running")
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.root.appendingPathComponent(".oases-cpa-installed").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.root.appendingPathComponent(".oases-cpa-versions").path))
        let script = DeploymentExecutor().scriptForVerification(method: .native, installDirectory: "/x", gatewayPayloadBase64: "")
        XCTAssertTrue(script.contains("for _ in $(seq 1 45); do\n  HEALTHZ_BODY="), "production waits 45 attempts")
    }

    /// Defence in depth (the rule of vendor_gateway.sh): Node and gateway archives with an
    /// absolute path or a `..` component are refused before anything is unpacked.
    func testArchivesWithAbsoluteOrParentPathsAreRefused() throws {
        let gatewayParent = try FakeArtifacts.make(caseName: "gateway-dotdot", gatewayCraftedEntry: "oases-gateway_0.9.0-test/../../escaped")
        let refusedParent = try install(gatewayParent)
        XCTAssertEqual(refusedParent.result.status, 24, refusedParent.result.stderr)
        XCTAssertTrue(refusedParent.result.stderr.contains("Oases 网关包含有绝对路径或 .. 路径，已拒绝。"), refusedParent.result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: refusedParent.root.appendingPathComponent("gateway").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gatewayParent.caseDirectory.appendingPathComponent("escaped").path))

        let absoluteTarget = FakeArtifacts.scratchRoot.appendingPathComponent("absolute-entry-\(UUID().uuidString.prefix(8))").path
        let gatewayAbsolute = try FakeArtifacts.make(caseName: "gateway-absolute", gatewayCraftedEntry: absoluteTarget)
        let refusedAbsolute = try install(gatewayAbsolute)
        XCTAssertEqual(refusedAbsolute.result.status, 24, refusedAbsolute.result.stderr)
        XCTAssertTrue(refusedAbsolute.result.stderr.contains("Oases 网关包含有绝对路径或 .. 路径，已拒绝。"), refusedAbsolute.result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absoluteTarget))

        let nodeParent = try FakeArtifacts.make(caseName: "node-dotdot", nodeCraftedEntry: "node-v24.99.0-darwin-arm64/../../escaped-node")
        let refusedNode = try install(nodeParent)
        XCTAssertEqual(refusedNode.result.status, 23, refusedNode.result.stderr)
        XCTAssertTrue(refusedNode.result.stderr.contains("Node 运行时包含有绝对路径或 .. 路径，已拒绝。"), refusedNode.result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: refusedNode.root.appendingPathComponent("node/v24.99.0").path))
    }

    func testNodeVersionMismatchExits23() throws {
        let fake = try FakeArtifacts.make(caseName: "node-version")
        let run = try install(fake, extraEnvironment: ["FAKE_NODE_VERSION": "v18.0.0"])
        XCTAssertEqual(run.result.status, 23, run.result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.root.appendingPathComponent("gateway").path))
    }

    func testRealBundleScriptCarriesThePinnedGatewayPackage() throws {
        let script = DeploymentExecutor().scriptForVerification(method: .native, installDirectory: "/x")
        let payload = try GatewayBundle.bundled.verifiedPayload(in: GatewayBundle.resourceBundle).base64EncodedString()
        XCTAssertTrue(script.contains("GATEWAY_PAYLOAD_BASE64='\(payload)'"))
        XCTAssertTrue(script.contains("GATEWAY_EXPECTED_SHA256=\"\(GatewayBundle.bundled.sha256)\""))
        XCTAssertTrue(script.contains("openssl base64 -d -A"))
        XCTAssertFalse(script.contains("base64 -d \""))
        XCTAssertFalse(script.contains("-H \"Authorization"), "no key in a curl argument")
    }

    func testNativeScriptUsesTheSharedProcessListAndRecoversGatewayItems() {
        let native = DeploymentExecutor().scriptForVerification(method: .native, installDirectory: "/x")
        XCTAssertTrue(native.contains(DeploymentScriptFragments.managedProcessList(topology: .gateway)))
        XCTAssertTrue(native.contains("for pid_name in $OASES_MANAGED_STOP_ORDER; do"))
        for item in ["\"node\"", "\"gateway\"", "\"gateway-data\""] {
            XCTAssertTrue(native.contains("move_recovery_item \(item)"), item)
        }
    }

    func testStaleAttemptWithGatewayIsBackedUpBeforeReinstall() throws {
        let fake = try FakeArtifacts.make(caseName: "recovery")
        let run = try install(fake) { root in
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: root.appendingPathComponent("gateway/0.0.1"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: root.appendingPathComponent("gateway-data"), withIntermediateDirectories: true)
            try fileManager.createDirectory(at: root.appendingPathComponent("node/v1"), withIntermediateDirectories: true)
            try Data("stale\n".utf8).write(to: root.appendingPathComponent("gateway-data/permissions.json"))
            try Data("4242424\n".utf8).write(to: root.appendingPathComponent("gateway.pid"))
            try Data("stage=bootstrap-gateway\n".utf8).write(to: root.appendingPathComponent(".oases-cpa-failed"))
        }
        XCTAssertEqual(run.result.status, 0, run.result.stderr)
        let backups = try FileManager.default.contentsOfDirectory(atPath: run.root.appendingPathComponent("backups").path)
        let backup = try XCTUnwrap(backups.first { $0.hasPrefix("auto-recovery-") })
        let saved = run.root.appendingPathComponent("backups/\(backup)")
        for item in ["gateway/0.0.1", "gateway-data/permissions.json", "node/v1", "gateway.pid"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: saved.appendingPathComponent(item).path), item)
        }
        XCTAssertNotEqual(try run.text("gateway-data/permissions.json"), "stale\n")
    }

    // MARK: - Models

    func testProfileKeepsTheEngineKeyFingerprint() throws {
        let old = #"""
        {"id":"7B1A4C30-8D2B-4F6E-9C55-3A1E2D4B5C6F","targetKind":"local","deploymentMethod":"native","remoteHost":"",
         "remoteUser":"root","remotePort":"22","privateKeyPath":"","installDirectory":"/x","isInstalled":true}
        """#
        let decoded = try JSONDecoder().decode(DeploymentProfile.self, from: Data(old.utf8))
        XCTAssertNil(decoded.packEngineKeyFingerprint)
        var profile = decoded
        profile.packEngineKeyFingerprint = String(repeating: "c", count: 64)
        let roundTrip = try JSONDecoder().decode(DeploymentProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(roundTrip.packEngineKeyFingerprint, String(repeating: "c", count: 64))
        XCTAssertEqual(roundTrip, profile)
    }

    func testParseResultReadsOnlyAWellFormedFingerprint() throws {
        let executor = DeploymentExecutor()
        let good = String(repeating: "a", count: 64)
        let parsed = try executor.parseResult("OASES_CPA_MANAGEMENT_KEY=m\nOASES_CPAMP_ADMIN_KEY=a\nOASES_PACK_ENGINE_KEY_SHA256=\(good)\n")
        XCTAssertEqual(parsed.packEngineKeyFingerprint, good)
        let malformed = try executor.parseResult("OASES_CPA_MANAGEMENT_KEY=m\nOASES_CPAMP_ADMIN_KEY=a\nOASES_PACK_ENGINE_KEY_SHA256=oases-int-not-a-hash\n")
        XCTAssertNil(malformed.packEngineKeyFingerprint)
        let docker = try executor.parseResult("OASES_CPA_MANAGEMENT_KEY=m\nOASES_CPAMP_ADMIN_KEY=a\n")
        XCTAssertNil(docker.packEngineKeyFingerprint)
    }

    func testNativePlanNamesNodeAndGatewaySteps() {
        let native = DeploymentPlanFactory.makeSteps(target: .local, method: .native).map(\.title)
        let titles = ["部署 CLIProxyAPI", "安装 Node 运行时", "部署 Oases 网关"].map { OasesLocalization.localized($0) }
        let start = native.firstIndex(of: titles[0])
        XCTAssertNotNil(start)
        if let start { XCTAssertEqual(Array(native[start..<(start + 3)]), titles) }
        let verify = DeploymentPlanFactory.makeSteps(target: .local, method: .native)
            .first { $0.title == OasesLocalization.localized("启动并验证网关") }
        XCTAssertEqual(verify?.detail, OasesLocalization.localized("验证引擎、CPA Manager Plus 与网关的本机健康检查"))
        XCTAssertEqual(OasesLocalization.localized("安装 Node 运行时", language: .english), "Install the Node runtime")
        XCTAssertEqual(OasesLocalization.localized("部署 Oases 网关", language: .english), "Deploy the Oases gateway")
        let docker = DeploymentPlanFactory.makeSteps(target: .local, method: .docker).map(\.title)
        XCTAssertFalse(docker.contains(titles[1]))
        XCTAssertFalse(docker.contains(titles[2]))
    }
}
