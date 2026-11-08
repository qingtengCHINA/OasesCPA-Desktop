import XCTest
@testable import OasesCPA

/// The shared bash fragments, each run on its own with real bash in a scratch case directory
/// (`FakeArtifacts`), independent of any whole script.
final class DeploymentScriptFragmentsTests: XCTestCase {
    /// What the fragments expect from the script around them.
    private let harness = """
    set -euo pipefail
    SHA256_COMMAND="shasum"
    curl_retry() { curl "$@"; }
    verify_fixed_archive() {
      local actual
      actual="$(shasum -a 256 "$3" | awk '{print $1}')"
      [ "$actual" = "$1" ] || { printf 'mismatch %s\\n' "$2" >&2; return 17; }
    }
    """

    private func selection(_ fake: FakeArtifacts) throws -> String {
        let platform = try XCTUnwrap(DeploymentPlatform.allCases.first)
        let parts = platform.rawValue.split(separator: "/").map(String.init)
        return """
        RELEASE_OS="\(parts[0])"
        ARCH="\(parts[1])"
        \(fake.pins.nativeSelectionScript())
        GATEWAY_PAYLOAD_BASE64='\(fake.gatewayPayloadBase64)'
        """
    }

    private func mode(_ url: URL) throws -> Int {
        ((try FileManager.default.attributesOfItem(atPath: url.path))[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testVersionGreaterThanAndVersionsFileRoundTrip() throws {
        let fake = try FakeArtifacts.make(caseName: "fragments")
        let rows: [(String, String, Bool)] = [
            ("v8.0.51", "v8.0.50", true), ("v8.0.50", "v8.0.51", false), ("v8.0.51", "v8.0.51", false),
            ("v8.0.100", "v8.0.99", true), ("v1.14.10", "v1.9.99", true), ("0.1.0", "0.1.0-dev", false),
            ("0.2.0", "0.1.9+build.7", true), ("v24.22.2", "v24.22", true), ("v8", "v7.99.99", true),
            ("v08.1", "v8.0", true),
        ]
        var script = DeploymentScriptFragments.versionCompareFunctions() + "\n"
        for (left, right, _) in rows {
            script += "if oases_version_gt '\(left)' '\(right)'; then echo yes; else echo no; fi\n"
        }
        let root = fake.caseDirectory.appendingPathComponent("versions-root")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cli-proxy-api"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cpamp"), withIntermediateDirectories: true)
        // A 0.1.x deployment without a versions file: the versions come from run.sh.
        try Data("exec \"\(root.path)/cli-proxy-api/runtime/CLIProxyAPI_7.2.141_linux_amd64/cli-proxy-api\" -config x\n".utf8)
            .write(to: root.appendingPathComponent("cli-proxy-api/run.sh"))
        try Data("cd \"\(root.path)/cpamp/runtime/cpa-manager-plus_v1.11.10_linux_amd64\"\nexec x\n".utf8)
            .write(to: root.appendingPathComponent("cpamp/run.sh"))
        script += DeploymentScriptFragments.readInstalledVersions() + "\n"
        script += DeploymentScriptFragments.writeVersionsFile() + "\n"
        script += """
        set -euo pipefail
        oases_read_installed_versions '\(root.path)'
        echo "legacy=$INSTALLED_ENGINE|$INSTALLED_CPAMP|$INSTALLED_NODE|$INSTALLED_GATEWAY"
        oases_write_versions '\(root.path)' v8.0.51 v1.14.10 v24.22.2 0.1.0
        oases_read_installed_versions '\(root.path)'
        echo "full=$INSTALLED_ENGINE|$INSTALLED_CPAMP|$INSTALLED_NODE|$INSTALLED_GATEWAY"
        oases_write_versions '\(root.path)' v8.0.51 v1.14.10
        oases_read_installed_versions '\(root.path)'
        echo "docker=$INSTALLED_ENGINE|$INSTALLED_CPAMP|$INSTALLED_NODE|$INSTALLED_GATEWAY"
        ls -a '\(root.path)' | grep -c 'oases-cpa-versions.part' || true
        """
        let result = try fake.run(script)
        XCTAssertEqual(result.status, 0, result.stderr)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(lines.prefix(rows.count)), rows.map { $0.2 ? "yes" : "no" })
        XCTAssertEqual(Array(lines.dropFirst(rows.count)), [
            "legacy=v7.2.141|v1.11.10||",
            "full=v8.0.51|v1.14.10|v24.22.2|0.1.0",
            "docker=v8.0.51|v1.14.10||",
            "0",
        ])
        let data = try Data(contentsOf: root.appendingPathComponent(".oases-cpa-versions"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: String], ["engine": "v8.0.51", "cpamp": "v1.14.10"])
    }

    func testManagedProcessListIsOneListForBothTopologies() throws {
        let gateway = DeploymentScriptFragments.managedProcesses(topology: .gateway)
        XCTAssertEqual(gateway.map(\.pidFile), ["cli-proxy-api.pid", "cpa-manager-plus.pid", "gateway.pid"])
        XCTAssertEqual(gateway.map(\.logFile), ["logs/cli-proxy-api.log", "logs/cpa-manager-plus.log", "logs/gateway.log"])
        XCTAssertEqual(gateway.map(\.runScript), ["cli-proxy-api/run.sh", "cpamp/run.sh", "gateway/run.sh"])
        XCTAssertEqual(DeploymentScriptFragments.managedProcesses(topology: .legacy).map(\.pidFile), ["cli-proxy-api.pid", "cpa-manager-plus.pid"])

        let fake = try FakeArtifacts.make(caseName: "process-list")
        let result = try fake.run(DeploymentScriptFragments.managedProcessList(topology: .gateway) + """

        echo "$OASES_MANAGED_PID_FILES"
        echo "$OASES_MANAGED_STOP_ORDER"
        echo "$OASES_MANAGED_LOG_FILES"
        for name in $OASES_MANAGED_PID_FILES; do oases_managed_owned_path "$name"; echo; done
        oases_managed_owned_path other.pid || echo refused
        """)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.split(separator: "\n").map(String.init), [
            "cli-proxy-api.pid cpa-manager-plus.pid gateway.pid",
            "gateway.pid cpa-manager-plus.pid cli-proxy-api.pid",
            "logs/cli-proxy-api.log logs/cpa-manager-plus.log logs/gateway.log",
            "cli-proxy-api", "cpamp", "gateway", "refused",
        ])
    }

    func testManagementCurlPassesTheKeyOnStdinOnly() throws {
        let fake = try FakeArtifacts.make(caseName: "mgmt-curl")
        // A curl that records its argv and the config it was given on stdin.
        let capture = fake.caseDirectory.appendingPathComponent("curl-stdin.txt")
        let curl = fake.binDirectory.appendingPathComponent("curl")
        try Data("""
        #!/bin/bash
        { printf 'curl'; for arg in "$@"; do printf ' %s' "$arg"; done; printf '\\n'; } >> "$OASES_FAKE_ARGV_LOG"
        cat > \(capture.path)
        exit 0
        """.utf8).write(to: curl)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: curl.path)
        let key = "cpa_" + String(repeating: "5e", count: 32)
        let keyFile = fake.caseDirectory.appendingPathComponent("key")
        try Data("\(key)\n".utf8).write(to: keyFile)
        let result = try fake.run(DeploymentScriptFragments.managementCurl() + """

        set -euo pipefail
        oases_mgmt_curl '\(keyFile.path)' -fsS -o /dev/null http://127.0.0.1:18316/v0/management/config
        echo first=$?
        if oases_mgmt_curl '\(fake.caseDirectory.path)/missing' -fsS http://127.0.0.1:1/x; then echo missing=0; else echo missing=1; fi
        """)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "first=0\nmissing=1\n")
        XCTAssertEqual(try String(contentsOf: capture, encoding: .utf8), "header = \"Authorization: Bearer \(key)\"\n")
        let argv = fake.argv()
        XCTAssertEqual(argv, "curl -K - -fsS -o /dev/null http://127.0.0.1:18316/v0/management/config\n", "one call; none for a missing key file")
        XCTAssertFalse(argv.contains(key))
    }

    func testInstallGatewayStripsTheTopDirectoryAndRefusesBadPackages() throws {
        let fake = try FakeArtifacts.make(caseName: "fragment-gateway")
        let install = harness + "\n" + (try selection(fake)) + "\n" + DeploymentScriptFragments.installGateway() + "\n"
        let root = fake.caseDirectory.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let good = try fake.run(install + "oases_install_gateway '\(root.path)'\n")
        XCTAssertEqual(good.status, 0, good.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("gateway/\(fake.gatewayVersion)/server.mjs").path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("gateway/current").path), fake.gatewayVersion)

        for broken in [
            try FakeArtifacts.make(caseName: "fragment-gateway-two", gatewayExtraTopDirectory: "stray"),
            try FakeArtifacts.make(caseName: "fragment-gateway-sha", gatewaySHA256Override: String(repeating: "0", count: 64)),
        ] {
            let brokenRoot = broken.caseDirectory.appendingPathComponent("root")
            try FileManager.default.createDirectory(at: brokenRoot, withIntermediateDirectories: true)
            let script = harness + "\n" + (try selection(broken)) + "\n" + DeploymentScriptFragments.installGateway() + "\n"
            let refused = try broken.run(script + "oases_install_gateway '\(brokenRoot.path)'\n")
            XCTAssertEqual(refused.status, 24, refused.stderr)
            XCTAssertFalse(FileManager.default.fileExists(atPath: brokenRoot.appendingPathComponent("gateway").path))
        }
        // An undecodable payload is refused the same way.
        let garbage = try FakeArtifacts.make(caseName: "fragment-gateway-garbage")
        let garbageRoot = garbage.caseDirectory.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: garbageRoot, withIntermediateDirectories: true)
        let script = harness + "\n" + (try selection(garbage)) + "\nGATEWAY_PAYLOAD_BASE64='not base64 at all'\n" + DeploymentScriptFragments.installGateway() + "\n"
        let refused = try garbage.run(script + "oases_install_gateway '\(garbageRoot.path)'\n")
        XCTAssertEqual(refused.status, 24)
        XCTAssertFalse(FileManager.default.fileExists(atPath: garbageRoot.appendingPathComponent("gateway").path))
    }

    func testInstallNodeUsesThePinnedPackageAndChecksItsVersion() throws {
        let fake = try FakeArtifacts.make(caseName: "fragment-node")
        let install = harness + "\n" + (try selection(fake)) + "\n" + DeploymentScriptFragments.installNode() + "\n"
        let root = fake.caseDirectory.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let good = try fake.run(install + "oases_install_node '\(root.path)'\necho \"$NODE_BIN\"\n")
        XCTAssertEqual(good.status, 0, good.stderr)
        XCTAssertEqual(good.stdout, "\(root.path)/node/current/bin/node\n")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("node/current").path), FakeArtifacts.nodeTag)
        XCTAssertTrue(fake.argv().contains("https://nodejs.org/dist/\(FakeArtifacts.nodeTag)/"))

        let other = try FakeArtifacts.make(caseName: "fragment-node-version")
        let otherRoot = other.caseDirectory.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        let script = harness + "\n" + (try selection(other)) + "\n" + DeploymentScriptFragments.installNode() + "\n"
        let refused = try other.run(script + "oases_install_node '\(otherRoot.path)'\n", extraEnvironment: ["FAKE_NODE_VERSION": "v20.0.0"])
        XCTAssertEqual(refused.status, 23, refused.stderr)
    }

    func testSecurePrivateDirectoriesAndBootstrapExitCodes() throws {
        let fake = try FakeArtifacts.make(caseName: "fragment-secure")
        let root = fake.caseDirectory.appendingPathComponent("root")
        let functions = DeploymentScriptFragments.securePrivateDirectories() + "\n" + DeploymentScriptFragments.runBootstrap() + "\n"
        let result = try fake.run(functions + """
        mkdir -p '\(root.path)/secrets'
        oases_secure_private_directories '\(root.path)'
        """, prelude: "umask 002")
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try mode(root) & 0o022, 0)
        XCTAssertEqual(try mode(root.appendingPathComponent("secrets")), 0o700)
        XCTAssertEqual(try mode(root.appendingPathComponent("gateway-data")), 0o700)

        // The fake bootstrap with the real rules: it accepts what the function prepared.
        let node = fake.caseDirectory.appendingPathComponent("node-bin")
        try FileManager.default.createDirectory(at: node, withIntermediateDirectories: true)
        let unpack = try fake.run("tar -xzf '\(fake.artifactsDirectory.path)/\(try XCTUnwrap(fake.pins.node.assets[.darwinARM64]).fileName)' -C '\(node.path)' --strip-components=1\n")
        XCTAssertEqual(unpack.status, 0, unpack.stderr)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("gateway/current"), withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: root.appendingPathComponent("gateway/current/bootstrap.mjs"))
        try Data("cpa_test\n".utf8).write(to: root.appendingPathComponent("secrets/cpa-management-key"))
        let bootstrap = functions + "NODE_BIN='\(node.path)/bin/node'\noases_run_bootstrap '\(root.path)'\n"
        let accepted = try fake.run(bootstrap)
        XCTAssertEqual(accepted.status, 0, accepted.stderr)
        XCTAssertEqual(try mode(root.appendingPathComponent("secrets/pack-engine-key")), 0o600)
        for code in ["2", "3"] {
            let refused = try fake.run(bootstrap, extraEnvironment: ["FAKE_BOOTSTRAP_EXIT": code])
            XCTAssertEqual(refused.status, 25)
            XCTAssertTrue(refused.stderr.contains("bootstrap 退出码 \(code)"), refused.stderr)
        }
        // Without the parent rule the fake bootstrap refuses a group-writable secrets directory.
        try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: root.appendingPathComponent("secrets").path)
        let insecure = try fake.run(bootstrap)
        XCTAssertEqual(insecure.status, 25)
        XCTAssertTrue(insecure.stdout.contains("insecure_directory") || insecure.stderr.contains("insecure_directory"))

        // Symlinked secrets or gateway-data, or a symlinked root: 25, nothing changed through them.
        let linked = fake.caseDirectory.appendingPathComponent("linked-root")
        try FileManager.default.createDirectory(at: linked.appendingPathComponent("elsewhere"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: linked.appendingPathComponent("secrets").path, withDestinationPath: "elsewhere")
        let refusedLink = try fake.run(functions + "oases_secure_private_directories '\(linked.path)'\n")
        XCTAssertEqual(refusedLink.status, 25)
        let rootLink = fake.caseDirectory.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(atPath: rootLink.path, withDestinationPath: root.path)
        let refusedRoot = try fake.run(functions + "oases_secure_private_directories '\(rootLink.path)'\n")
        XCTAssertEqual(refusedRoot.status, 25)
    }

    func testRunScriptsCloseTheResultDescriptorsAndQuotePaths() throws {
        let fake = try FakeArtifacts.make(caseName: "fragment-run")
        let root = fake.caseDirectory.appendingPathComponent("odd root 'x'")
        for directory in ["cli-proxy-api", "cpamp", "gateway"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let quoted = "'" + root.path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        let result = try fake.run(
            DeploymentScriptFragments.engineRunScript() + "\n" + DeploymentScriptFragments.cpampRunScript() + "\n"
                + DeploymentScriptFragments.gatewayRunScript() + "\n" + """
            set -euo pipefail
            R=\(quoted)
            oases_write_engine_run "$R/cli-proxy-api" "$R/cli-proxy-api/runtime/p/cli-proxy-api"
            oases_write_cpamp_run "$R/cpamp" "$R/cpamp/runtime/p/cpa-manager-plus"
            oases_write_gateway_run "$R" v8.0.51 v1.14.10 8317 18320 18316
            bash -n "$R/cli-proxy-api/run.sh" && bash -n "$R/cpamp/run.sh" && bash -n "$R/gateway/run.sh" && echo syntax-ok
            ( eval "$(grep '^export ' "$R/cpamp/run.sh")"; printf '%s\\n' "$CPA_MANAGER_CONFIG" )
            ( eval "$(grep '^export ' "$R/gateway/run.sh")"; printf '%s\\n' "$CONFIG_PATH" "$OASES_DATA_DIR" "$PORT" )
            """
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.split(separator: "\n").map(String.init), [
            "syntax-ok",
            "\(root.path)/cpamp/config.json",
            "\(root.path)/cli-proxy-api/config.yaml",
            "\(root.path)/gateway-data",
            "8317",
        ])
        for name in ["cli-proxy-api/run.sh", "cpamp/run.sh", "gateway/run.sh"] {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.hasPrefix("#!/bin/bash\nset -euo pipefail\nexec 3>&- 4>&-\n"), name)
            XCTAssertEqual(try mode(root.appendingPathComponent(name)), 0o755, name)
        }
    }
}
