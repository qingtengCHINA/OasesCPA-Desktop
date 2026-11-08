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
