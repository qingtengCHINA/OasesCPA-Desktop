import CryptoKit
import Darwin
import XCTest
@testable import OasesCPA

/// The gateway as the third managed process: the lifecycle, control, removal, recovery, log,
/// probe and adoption scripts run for real with `/bin/bash` against a deployment the real
/// install script laid out with fake packages (`FakeArtifacts`, scratch roots and a scratch
/// HOME under `$OASES_SCRATCH`); the health checks run against `URLProtocolStub`.
final class RuntimeLifecycleGatewayTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func tearDown() {
        for cleanup in cleanups.reversed() { cleanup() }
        cleanups.removeAll()
        URLProtocolStub.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private struct Deployment {
        let fake: FakeArtifacts
        let root: URL
        let termLog: URL

        func pid(_ name: String) -> Int32? {
            guard let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) else { return nil }
            return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        func termLines() -> [String] {
            ((try? String(contentsOf: termLog, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
    }

    /// A native gateway deployment laid out and started by the real install script.
    private func installedDeployment(_ caseName: String, extraEnvironment: [String: String] = [:]) throws -> Deployment {
        let fake = try FakeArtifacts.make(caseName: caseName)
        let root = fake.caseDirectory.appendingPathComponent("root", isDirectory: true)
        let termLog = fake.caseDirectory.appendingPathComponent("term.log")
        let script = DeploymentExecutor().scriptForVerification(
            method: .native,
            installDirectory: root.path,
            pins: fake.pins,
            gatewayPayloadBase64: fake.gatewayPayloadBase64
        )
        cleanups.append { [fake, root] in fake.stopProcesses(under: root) }
        var environment = extraEnvironment
        environment["OASES_FAKE_TERM_LOG"] = termLog.path
        let result = try fake.run(script, extraEnvironment: environment)
        XCTAssertEqual(result.status, 0, result.stderr)
        let deployment = Deployment(fake: fake, root: root, termLog: termLog)
        for name in DeploymentScriptFragments.managedProcesses(topology: .gateway).map(\.pidFile) {
            let pid = try XCTUnwrap(deployment.pid(name), name)
            XCTAssertTrue(isAlive(pid), "\(name) runs after the install")
            XCTAssertTrue(waitUntilReady(pid), "\(name) is up")
        }
        return deployment
    }

    /// A fake service is up once it waits on its `sleep` child: its SIGTERM trap is then in
    /// place (a signal during the few milliseconds of `run.sh` before the `exec` would simply
    /// end it without the log line the tests look for).
    private func waitUntilReady(_ pid: Int32, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-P", String(pid)]
            process.standardOutput = pipe
            try? process.run()
            process.waitUntilExit()
            if !pipe.fileHandleForReading.readDataToEndOfFile().isEmpty { return true }
            usleep(20_000)
        } while Date() < deadline
        return false
    }

    private func run(_ deployment: Deployment, _ script: String, extraEnvironment: [String: String] = [:]) throws -> FakeArtifacts.RunResult {
        var environment = extraEnvironment
        environment["OASES_FAKE_TERM_LOG"] = deployment.termLog.path
        return try deployment.fake.run(script, extraEnvironment: environment)
    }

    private func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    private func waitForExit(_ pid: Int32, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isAlive(pid), Date() < deadline { usleep(50_000) }
        return !isAlive(pid)
    }

    private func commandLine(of pid: Int32) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// A process that does not belong to any deployment (a stale pid from another program).
    private func foreignProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        cleanups.append { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        return process
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private var lifecycle: RuntimeLifecycleService { RuntimeLifecycleService() }

    // MARK: - Start and stop

    func testStartStartsGatewayAfterEngineOnlyWhenRunScriptExists() throws {
        let deployment = try installedDeployment("lifecycle-start")
        let root = deployment.root
        let stop = try run(deployment, lifecycle.stopScriptForVerification(method: .native, installDirectory: root.path))
        XCTAssertEqual(stop.status, 0, stop.stderr)

        // A 0.1.x layout: no gateway/run.sh, so no gateway and no gateway.pid.
        let runScript = root.appendingPathComponent("gateway/run.sh")
        let parked = root.appendingPathComponent("gateway/run.sh.parked")
        try FileManager.default.moveItem(at: runScript, to: parked)
        let legacyStart = try run(deployment, lifecycle.startScriptForVerification(method: .native, installDirectory: root.path))
        XCTAssertEqual(legacyStart.status, 0, legacyStart.stderr)
        XCTAssertNil(deployment.pid("gateway.pid"))
        let engine = try XCTUnwrap(deployment.pid("cli-proxy-api.pid"))
        let panel = try XCTUnwrap(deployment.pid("cpa-manager-plus.pid"))
        XCTAssertTrue(isAlive(engine))
        XCTAssertTrue(isAlive(panel))

        // With gateway/run.sh the gateway starts too, from this root.
        try FileManager.default.moveItem(at: parked, to: runScript)
        let start = try run(deployment, lifecycle.startScriptForVerification(method: .native, installDirectory: root.path))
        XCTAssertEqual(start.status, 0, start.stderr)
        let gateway = try XCTUnwrap(deployment.pid("gateway.pid"))
        XCTAssertTrue(isAlive(gateway))
        XCTAssertTrue(waitUntilReady(gateway))
        XCTAssertTrue(commandLine(of: gateway).contains("\(root.path)/gateway"), commandLine(of: gateway))
        XCTAssertEqual(deployment.pid("cli-proxy-api.pid"), engine, "a running engine is not started twice")

        // Start order in the script: engine, CPA Manager Plus, then the gateway.
        let script = lifecycle.startScriptForVerification(method: .native, installDirectory: "/x")
        let positions = ["cli-proxy-api/run.sh", "cpamp/run.sh", "gateway/run.sh"].map { name in
            script.range(of: "start_if_needed \"$ROOT/\(name)\"")?.lowerBound
        }
        XCTAssertTrue(positions.allSatisfy { $0 != nil })
        XCTAssertLessThan(positions[0]!, positions[1]!)
        XCTAssertLessThan(positions[1]!, positions[2]!)
        XCTAssertTrue(script.contains("if [ -x \"$ROOT/gateway/run.sh\" ]; then"))
    }

    func testStopTermsGatewayFirstAndWaitsUpTo30Seconds() throws {
        // The fake gateway needs 6 s after SIGTERM (like the real one finishing its requests):
        // more than the 5 s the other processes get, well inside its own 30 s.
        let deployment = try installedDeployment("lifecycle-stop", extraEnvironment: ["FAKE_GATEWAY_TERM_DELAY": "6"])
        let pids = DeploymentScriptFragments.managedProcesses(topology: .gateway).compactMap { deployment.pid($0.pidFile) }
        XCTAssertEqual(pids.count, 3)

        let started = Date()
        let stop = try run(deployment, lifecycle.stopScriptForVerification(method: .native, installDirectory: deployment.root.path))
        XCTAssertEqual(stop.status, 0, stop.stderr)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 6, "the stop waited for the gateway")
        XCTAssertEqual(deployment.termLines(), ["gateway TERM", "gateway exited", "cpa-manager-plus TERM", "cli-proxy-api TERM"],
                       "gateway first, and it exited by itself (no SIGKILL inside its grace)")
        for pid in pids { XCTAssertTrue(waitForExit(pid), "\(pid) stopped") }
        for name in DeploymentScriptFragments.managedProcesses(topology: .gateway).map(\.pidFile) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: deployment.root.appendingPathComponent(name).path))
        }

        let processes = DeploymentScriptFragments.managedProcesses(topology: .gateway)
        XCTAssertEqual(processes.map(\.termGraceSeconds), [5, 5, 30])
        let list = DeploymentScriptFragments.managedProcessList(topology: .gateway)
        XCTAssertTrue(list.contains("gateway.pid) printf '%s' '150' ;;"), "30 s in 0.2 s steps")
        XCTAssertTrue(list.contains("OASES_MANAGED_STOP_ORDER=\"gateway.pid cpa-manager-plus.pid cli-proxy-api.pid\""))
        XCTAssertTrue(lifecycle.stopScriptForVerification(method: .native, installDirectory: "/x").contains(list))
    }

    /// Stop (pause services), cancel, removal and the failed-deployment cleanup each end the
    /// gateway of the deployment, and none of them signals a pid that is not the deployment's.
    func testPauseCancelRemoveRecoverAllCoverGatewayPid() throws {
        // 1. Stop.
        let stopped = try installedDeployment("cover-stop")
        let stoppedGateway = try XCTUnwrap(stopped.pid("gateway.pid"))
        XCTAssertEqual(try run(stopped, lifecycle.stopScriptForVerification(method: .native, installDirectory: stopped.root.path)).status, 0)
        XCTAssertTrue(waitForExit(stoppedGateway))

        // 2. Cancel a deployment in progress (marker, lock and a live installer process).
        let cancelled = try installedDeployment("cover-cancel")
        let cancelledGateway = try XCTUnwrap(cancelled.pid("gateway.pid"))
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/bash")
        installer.arguments = ["-c", "sleep 30 & wait"]
        try installer.run()
        cleanups.append { if installer.isRunning { installer.terminate(); installer.waitUntilExit() } }
        try write("timestamp=now\nmethod=native\nstage=start-gateway\npid=\(installer.processIdentifier)\ncontrol_token=cover\n",
                  to: cancelled.root.appendingPathComponent(".oases-cpa-installing"))
        try write("\(installer.processIdentifier)\n", to: cancelled.root.appendingPathComponent(".oases-cpa-deployment-lock/pid"))
        let cancel = try run(cancelled, DeploymentControlService().scriptForVerification(
            action: .cancel, method: .native, installDirectory: cancelled.root.path, controlToken: "cover"
        ))
        XCTAssertEqual(cancel.status, 0, cancel.stderr)
        XCTAssertTrue(waitForExit(cancelledGateway))

        // 3. Removal (M6: a root this test created under $OASES_SCRATCH, scratch HOME).
        let removed = try installedDeployment("cover-remove")
        XCTAssertTrue(removed.root.path.hasPrefix(FakeArtifacts.scratchRoot.path), "removal runs only on a scratch root")
        XCTAssertTrue(removed.fake.environment()["HOME"]?.hasPrefix(FakeArtifacts.scratchRoot.path) == true)
        let removedPids = DeploymentScriptFragments.managedProcesses(topology: .gateway).compactMap { removed.pid($0.pidFile) }
        let removal = try run(removed, DeploymentRemovalService().scriptForVerification(method: .native, installDirectory: removed.root.path))
        XCTAssertEqual(removal.status, 0, removal.stderr)
        XCTAssertTrue(removal.stdout.contains("OASES_CPA_REMOVED=1"))
        for pid in removedPids { XCTAssertTrue(waitForExit(pid), "removal stopped \(pid) first") }
        XCTAssertEqual(removed.termLines().first, "gateway TERM")
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.root.path))

        // 4. Cleanup of a failed deployment: everything stopped, gateway files backed up.
        let failed = try installedDeployment("cover-recover")
        let failedGateway = try XCTUnwrap(failed.pid("gateway.pid"))
        try write("stage=wait-gateway\n", to: failed.root.appendingPathComponent(".oases-cpa-failed"))
        let recovery = try run(failed, DeploymentRecoveryService().scriptForVerification(
            method: .native, installDirectory: failed.root.path, backupName: "failed-cover"
        ))
        XCTAssertEqual(recovery.status, 0, recovery.stderr)
        XCTAssertTrue(waitForExit(failedGateway))
        let backup = failed.root.appendingPathComponent("backups/failed-cover")
        for item in ["gateway", "gateway-data", "node", "gateway.pid"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent(item).path), item)
        }

        // A foreign pid in gateway.pid survives all four.
        for (index, makeScript) in [
            { (root: URL) in self.lifecycle.stopScriptForVerification(method: .native, installDirectory: root.path) },
            { (root: URL) in DeploymentRemovalService().scriptForVerification(method: .native, installDirectory: root.path) },
            { (root: URL) in DeploymentRecoveryService().scriptForVerification(method: .native, installDirectory: root.path, backupName: "foreign") },
        ].enumerated() {
            let fake = try FakeArtifacts.make(caseName: "foreign-\(index)")
            let root = fake.caseDirectory.appendingPathComponent("root", isDirectory: true)
            try write("owned-by=oases-cpa\n", to: root.appendingPathComponent(".oases-cpa-managed"))
            try write("stage=x\n", to: root.appendingPathComponent(".oases-cpa-failed"))
            let foreign = try foreignProcess()
            try write("\(foreign.processIdentifier)\n", to: root.appendingPathComponent("gateway.pid"))
            let result = try fake.run(makeScript(root))
            XCTAssertEqual(result.status, 0, "\(index): \(result.stderr)")
            XCTAssertTrue(foreign.isRunning, "script \(index) left the foreign pid alone")
        }
        let cancelFake = try FakeArtifacts.make(caseName: "foreign-cancel")
        let cancelRoot = cancelFake.caseDirectory.appendingPathComponent("root", isDirectory: true)
        let foreign = try foreignProcess()
        let foreignInstaller = Process()
        foreignInstaller.executableURL = URL(fileURLWithPath: "/bin/bash")
        foreignInstaller.arguments = ["-c", "sleep 30 & wait"]
        try foreignInstaller.run()
        cleanups.append { if foreignInstaller.isRunning { foreignInstaller.terminate(); foreignInstaller.waitUntilExit() } }
        try write("owned-by=oases-cpa\n", to: cancelRoot.appendingPathComponent(".oases-cpa-managed"))
        try write("pid=\(foreignInstaller.processIdentifier)\ncontrol_token=f\n", to: cancelRoot.appendingPathComponent(".oases-cpa-installing"))
        try write("\(foreignInstaller.processIdentifier)\n", to: cancelRoot.appendingPathComponent(".oases-cpa-deployment-lock/pid"))
        try write("\(foreign.processIdentifier)\n", to: cancelRoot.appendingPathComponent("gateway.pid"))
        let foreignCancel = try cancelFake.run(DeploymentControlService().scriptForVerification(
            action: .cancel, method: .native, installDirectory: cancelRoot.path, controlToken: "f"
        ))
        XCTAssertEqual(foreignCancel.status, 0, foreignCancel.stderr)
        XCTAssertTrue(foreign.isRunning, "cancel left the foreign pid alone")
    }

    /// Removal never deletes a root while a process of the deployment still runs from it, even
    /// when its pid file is gone.
    func testRemovalRefusesWhileAGatewayRunsWithoutPidFile() throws {
        let deployment = try installedDeployment("remove-orphan")
        let gateway = try XCTUnwrap(deployment.pid("gateway.pid"))
        cleanups.append { kill(gateway, SIGTERM) }
        try FileManager.default.removeItem(at: deployment.root.appendingPathComponent("gateway.pid"))
        let removal = try run(deployment, DeploymentRemovalService().scriptForVerification(method: .native, installDirectory: deployment.root.path))
        XCTAssertNotEqual(removal.status, 0)
        XCTAssertTrue(removal.stderr.contains("目标目录中仍有 Oases CPA 进程在运行"), removal.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: deployment.root.appendingPathComponent("gateway-data").path))
        XCTAssertTrue(isAlive(gateway))
    }

    // MARK: - Logs, probe, adoption

    func testLogListIncludesGatewayLog() throws {
        let fake = try FakeArtifacts.make(caseName: "logs")
        let root = fake.caseDirectory.appendingPathComponent("root", isDirectory: true)
        try write("gateway listening on the admin port\n", to: root.appendingPathComponent("logs/gateway.log"))
        try write("engine line\n", to: root.appendingPathComponent("logs/cli-proxy-api.log"))
        let script = DeploymentLogService().scriptForVerification(method: .native, installDirectory: root.path)
        XCTAssertTrue(script.contains(DeploymentScriptFragments.managedProcessList(topology: .gateway)))
        let result = try fake.run(script)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("===== \(root.path)/logs/gateway.log ====="), result.stdout)
        XCTAssertTrue(result.stdout.contains("gateway listening on the admin port"))
        XCTAssertTrue(result.stdout.contains("engine line"))
    }

    private func probe(_ root: URL, fake: FakeArtifacts, shell: String) throws -> DeploymentProbe {
        let command = DeploymentProbeService().commandForVerification(installDirectory: root.path)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        process.environment = fake.environment()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return DeploymentProbeService().parseForVerification(String(decoding: data, as: UTF8.self), installDirectory: root.path)
    }

    func testProbeReportsGatewayTopologyAndVersions() throws {
        let deployment = try installedDeployment("probe")
        // The local probe runs in zsh, a remote one in the login shell (bash here).
        for shell in ["/bin/zsh", "/bin/bash"] {
            let result = try probe(deployment.root, fake: deployment.fake, shell: shell)
            XCTAssertTrue(result.hasGatewayRuntime, shell)
            XCTAssertEqual(result.topology, .gateway, shell)
            XCTAssertEqual(result.installedVersions["gateway"], deployment.fake.gatewayVersion, shell)
            XCTAssertEqual(result.installedVersions["engine"], FakeArtifacts.engineTag, shell)
            XCTAssertEqual(result.installedVersions["cpamp"], FakeArtifacts.cpampTag, shell)
            XCTAssertEqual(result.installedVersions["node"], FakeArtifacts.nodeTag, shell)
            XCTAssertTrue(result.hasManagedInstallation && result.canAdopt(method: .native), shell)
        }

        // A run.sh without a recorded gateway version is not the gateway topology.
        let versions = deployment.root.appendingPathComponent(".oases-cpa-versions")
        try write("{\n  \"engine\": \"v8.0.51\",\n  \"cpamp\": \"v1.14.10\"\n}\n", to: versions)
        let noVersion = try probe(deployment.root, fake: deployment.fake, shell: "/bin/bash")
        XCTAssertTrue(noVersion.hasGatewayRuntime)
        XCTAssertEqual(noVersion.topology, .legacy)

        // A 0.1.x layout: no gateway/run.sh, no versions file; versions from run.sh.
        try FileManager.default.removeItem(at: versions)
        try FileManager.default.moveItem(at: deployment.root.appendingPathComponent("gateway/run.sh"),
                                         to: deployment.root.appendingPathComponent("gateway/run.sh.parked"))
        let legacy = try probe(deployment.root, fake: deployment.fake, shell: "/bin/bash")
        XCTAssertFalse(legacy.hasGatewayRuntime)
        XCTAssertEqual(legacy.topology, .legacy)
        XCTAssertEqual(legacy.installedVersions["engine"], FakeArtifacts.engineTag)
        XCTAssertNil(legacy.installedVersions["gateway"])

        // Values that are not version text are dropped.
        let parsed = DeploymentProbeService().parseForVerification(
            "managed_gateway_runtime=yes\nversion_gateway=$(rm -rf x)\nversion_engine=v8.0.51\n", installDirectory: "/x"
        )
        XCTAssertNil(parsed.installedVersions["gateway"])
        XCTAssertEqual(parsed.topology, .legacy)
    }

    /// Wrappers for the tools the adoption and probe scripts call: each logs its full argv to
    /// the fake argv log (one write per line, so concurrent tools of a pipeline cannot split a
    /// line) and runs the real tool.
    private func argvRecordingBin(_ fake: FakeArtifacts) throws -> URL {
        let bin = fake.caseDirectory.appendingPathComponent("argv-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for tool in ["shasum", "sha256sum", "tr", "awk", "base64", "wc", "cat", "sed", "head", "grep", "uname", "dirname", "openssl", "docker"] {
            let real = ["/usr/bin/\(tool)", "/bin/\(tool)"].first { FileManager.default.isExecutableFile(atPath: $0) }
            guard let real else { continue }
            let wrapper = """
            #!/bin/bash
            line='\(tool)'; for arg in "$@"; do line="$line $arg"; done
            printf '%s\\n' "$line" >> "$OASES_FAKE_ARGV_LOG"
            exec \(real) "$@"

            """
            try Data(wrapper.utf8).write(to: bin.appendingPathComponent(tool))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent(tool).path)
        }
        return bin
    }

    func testAdoptionAndProbeScriptsPassNoKeyInArgv() throws {
        let deployment = try installedDeployment("adoption-argv")
        let root = deployment.root
        let bin = try argvRecordingBin(deployment.fake)
        try Data().write(to: deployment.fake.argvLog)
        let path = "\(bin.path):\(deployment.fake.binDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin"

        let adoption = try deployment.fake.run(
            ExistingDeploymentAdoptionService().scriptForVerification(installDirectory: root.path),
            extraEnvironment: ["PATH": path]
        )
        XCTAssertEqual(adoption.status, 0, adoption.stderr)
        let probeProcess = Process()
        probeProcess.executableURL = URL(fileURLWithPath: "/bin/bash")
        probeProcess.arguments = ["-c", DeploymentProbeService().commandForVerification(installDirectory: root.path)]
        probeProcess.environment = deployment.fake.environment(extra: ["PATH": path])
        probeProcess.standardOutput = FileHandle.nullDevice
        probeProcess.standardError = FileHandle.nullDevice
        try probeProcess.run()
        probeProcess.waitUntilExit()

        let argv = deployment.fake.argv()
        XCTAssertTrue(argv.contains("shasum -a 256"), "the wrappers were on PATH: \(argv)")
        XCTAssertTrue(argv.contains("sed -n"), "the probe ran through them too: \(argv)")
        for name in ["cpa-management-key", "cpamp-admin-key", "pack-engine-key", "pack-store-key"] {
            let key = try String(contentsOf: root.appendingPathComponent("secrets/\(name)"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(key.isEmpty)
            XCTAssertFalse(argv.contains(key), "\(name) appears in a process argument")
        }

        // The fingerprint line is the SHA-256 of the internal key; the key itself is not output.
        let packKey = try String(contentsOf: root.appendingPathComponent("secrets/pack-engine-key"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = SHA256.hash(data: Data(packKey.utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(adoption.stdout.contains("OASES_PACK_ENGINE_KEY_SHA256=\(expected)\n"), adoption.stdout)
        XCTAssertFalse(adoption.stdout.contains(packKey))
    }

    func testAdoptionReadsTheEngineKeyFingerprint() async throws {
        let deployment = try installedDeployment("adoption-fingerprint")
        let result = try await ExistingDeploymentAdoptionService().readCredentials(request: DeploymentExecutionRequest(
            target: .local, method: .native, host: "", user: "", port: "22", privateKeyPath: "",
            installDirectory: deployment.root.path
        ))
        let packKey = try String(contentsOf: deployment.root.appendingPathComponent("secrets/pack-engine-key"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(result.packEngineKeyFingerprint, SHA256.hash(data: Data(packKey.utf8)).map { String(format: "%02x", $0) }.joined())
        XCTAssertFalse(result.cpaManagementKey.isEmpty)
    }

    // MARK: - Health checks

    func testGatewayHealthCheckSendsNoManagementKey() async {
        URLProtocolStub.install { request, _ in
            if request.url?.path == "/healthz" {
                return .json(200, #"{"ok":true,"version":"0.1.0"}"#, for: request)
            }
            return .json(200, "{}", for: request)
        }
        let service = RuntimeLifecycleService(session: URLProtocolStub.makeSession(), endpoints: DeploymentEndpoints(topology: .gateway))
        let healthy = await service.checkConnectionHealth(cpaManagementKey: "cpa_secret_for_the_engine_only")
        XCTAssertTrue(healthy)
        let healthz = URLProtocolStub.recordedRequests.map(\.0).filter { $0.url?.absoluteString == "http://127.0.0.1:18320/healthz" }
        XCTAssertEqual(healthz.count, 1)
        XCTAssertEqual(healthz.first?.httpMethod, "GET")
        XCTAssertNil(healthz.first?.value(forHTTPHeaderField: "x-management-key"))
        XCTAssertNil(healthz.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertFalse((healthz.first?.allHTTPHeaderFields ?? [:]).values.contains { $0.contains("cpa_secret_for_the_engine_only") })

        // Not ok, or 401: unhealthy, and the 401 is not retried.
        for (status, body) in [(200, #"{"ok":false}"#), (401, #"{"error":"unauthorized"}"#), (200, "not json")] {
            URLProtocolStub.install { request, _ in
                request.url?.path == "/healthz" ? .json(status, body, for: request) : .json(200, "{}", for: request)
            }
            let result = await service.checkConnectionHealth(cpaManagementKey: "cpa_x")
            XCTAssertFalse(result, "\(status) \(body)")
            XCTAssertEqual(URLProtocolStub.recordedRequests.filter { $0.0.url?.path == "/healthz" }.count, 1, "no retry")
        }
    }

    func testLegacyTopologyChecksOnlyEngineAndCPAMP() async {
        URLProtocolStub.install { request, _ in .json(200, "{}", for: request) }
        let service = RuntimeLifecycleService(session: URLProtocolStub.makeSession(), endpoints: DeploymentEndpoints(topology: .legacy))
        XCTAssertNil(service.gatewayHealthURL)
        let healthy = await service.checkConnectionHealth(cpaManagementKey: "cpa_x")
        XCTAssertTrue(healthy)
        let ports = URLProtocolStub.recordedRequests.compactMap { $0.0.url?.port }
        XCTAssertEqual(Set(ports), [8317, 18317])
        XCTAssertFalse(ports.contains(18320))
    }

    func testRecoveredNotificationNamesTheGatewayOnlyInTheGatewayTopology() {
        XCTAssertEqual(
            HealthNotificationService.recoveredBody(target: "本机 Mac", topology: .gateway, language: .simplifiedChinese),
            "本机 Mac：CLIProxyAPI、CPAMP、Oases 网关和连接通道已重新可用。"
        )
        XCTAssertEqual(
            HealthNotificationService.recoveredBody(target: "本机 Mac", topology: .legacy, language: .simplifiedChinese),
            "本机 Mac：CLIProxyAPI、CPAMP 和连接通道已重新可用。"
        )
        XCTAssertTrue(HealthNotificationService.recoveredBody(target: "Mac", topology: .gateway, language: .english).contains("Oases gateway"))
        XCTAssertTrue(HealthNotificationService.healthCheckFailedDetail(topology: .gateway, language: .english).contains("Oases gateway"))
        XCTAssertFalse(HealthNotificationService.healthCheckFailedDetail(topology: .legacy, language: .english).contains("gateway"))
    }

    /// Every script that lists pid files uses the one shared list (M9).
    func testEveryProcessScriptUsesTheSharedList() {
        let list = DeploymentScriptFragments.managedProcessList(topology: .gateway)
        let scripts = [
            lifecycle.startScriptForVerification(method: .native, installDirectory: "/x"),
            lifecycle.stopScriptForVerification(method: .native, installDirectory: "/x"),
            DeploymentControlService().scriptForVerification(action: .cancel, method: .native, installDirectory: "/x", controlToken: "t"),
            DeploymentRemovalService().scriptForVerification(method: .native, installDirectory: "/x"),
            DeploymentRecoveryService().scriptForVerification(method: .native, installDirectory: "/x", backupName: "b"),
            DeploymentLogService().scriptForVerification(method: .native, installDirectory: "/x"),
            DeploymentExecutor().scriptForVerification(method: .native, installDirectory: "/x", gatewayPayloadBase64: ""),
        ]
        for (index, script) in scripts.enumerated() {
            XCTAssertTrue(script.contains(list), "script \(index)")
            XCTAssertFalse(script.contains("\"$ROOT/cli-proxy-api.pid\" \"$ROOT/cpa-manager-plus.pid\""), "script \(index) keeps a private list")
        }
    }
}

/// The store's decisions around the topology, with fake services (no scripts, no network,
/// an in-memory Keychain and a scratch defaults suite).
@MainActor
final class DeploymentStoreTopologyTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    private static let fingerprint = String(repeating: "ab", count: 32)

    private func readyProbe(directory: String, managed: Bool, gateway: Bool) -> DeploymentProbe {
        DeploymentProbe(
            operatingSystem: "Darwin", architecture: "arm64", shell: "/bin/zsh",
            curlPath: "/usr/bin/curl", tarPath: "/usr/bin/tar", opensslPath: "/usr/bin/openssl",
            sha256Path: "/usr/bin/shasum", dockerPath: "/usr/local/bin/docker",
            dockerComposeAvailable: true, dockerDaemonAvailable: true, installWritable: true,
            testedInstallDirectory: directory,
            hasManagedRoot: managed, hasManagedInstallation: managed, hasRecoverableCredentials: managed,
            hasNativeRuntime: managed, hasDockerRuntime: false,
            hasGatewayRuntime: gateway,
            installedVersions: gateway ? ["engine": "v8.0.51", "cpamp": "v1.14.10", "node": "v24.22.2", "gateway": "0.1.0"] : ["engine": "v7.2.141"]
        )
    }

    private func services(probe: DeploymentProbe, result: DeploymentExecutionResult) -> DeploymentStoreServices {
        URLProtocolStub.install { request, _ in
            request.url?.path == "/healthz"
                ? .json(200, #"{"ok":true,"version":"0.1.0"}"#, for: request)
                : .json(200, "{}", for: request)
        }
        return DeploymentStoreServices(
            execute: { _, _ in result },
            probe: { _ in probe },
            readExistingCredentials: { _ in result },
            upgrade: { _ in throw DeploymentExecutionError.missingResult },
            rollback: { _ in throw DeploymentExecutionError.missingResult },
            healthSession: URLProtocolStub.makeSession()
        )
    }

    private func waitUntil(_ condition: () -> Bool, _ message: String) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out: \(message)")
    }

    private func withIsolation(_ body: () async throws -> Void) async throws {
        let suiteName = "oases-store-topology-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        try await DeploymentProfileStore.withDefaultsForTesting(suite) {
            try await KeychainStore.withInMemoryKeychainForTesting {
                try await body()
            }
        }
    }

    private var scratchDirectory: String {
        FakeArtifacts.scratchRoot.appendingPathComponent("store-topology-\(UUID().uuidString.prefix(8))").path
    }

    private func install(method: DeploymentMethod) async throws -> DeploymentStore {
        let directory = scratchDirectory
        let probe = readyProbe(directory: directory, managed: false, gateway: false)
        let result = DeploymentExecutionResult(cpaManagementKey: "cpa_test", cpampAdminKey: "cpamp_test",
                                               packEngineKeyFingerprint: method == .native ? Self.fingerprint : nil)
        let store = DeploymentStore(autoProbe: false, services: services(probe: probe, result: result))
        store.installDirectory = directory
        store.selectMethod(method)
        store.probeTarget()
        try await waitUntil({ store.stage == .ready && store.probe != nil }, "probe")
        store.acknowledgePlan()
        try await waitUntil({ store.stage == .attached }, "install: \(store.deploymentError ?? "")")
        return store
    }

    func testNativeInstallSwitchesToGatewayTopologyAndSavesFingerprint() async throws {
        try await withIsolation {
            let store = try await install(method: .native)
            XCTAssertEqual(store.topology, .gateway)
            XCTAssertEqual(store.packEngineKeyFingerprint, Self.fingerprint)
            let saved = try XCTUnwrap(DeploymentProfileStore.load())
            XCTAssertEqual(saved.topology, .gateway)
            XCTAssertEqual(saved.packEngineKeyFingerprint, Self.fingerprint)
            XCTAssertTrue(saved.isInstalled)
            let ports = Set(URLProtocolStub.recordedRequests.compactMap { $0.0.url?.port })
            XCTAssertEqual(ports, [18316, 18317, 18320], "the post-install health check used the gateway topology")
        }
    }

    func testDockerInstallStaysLegacy() async throws {
        try await withIsolation {
            let store = try await install(method: .docker)
            XCTAssertEqual(store.topology, .legacy)
            XCTAssertNil(store.packEngineKeyFingerprint)
            XCTAssertEqual(DeploymentProfileStore.load()?.topology, .legacy)
            XCTAssertFalse(URLProtocolStub.recordedRequests.contains { $0.0.url?.port == 18320 })
        }
    }

    /// The store takes the topology a maintenance run reports (upgrade of a 0.1.x deployment →
    /// gateway; its rollback → legacy), saves it, and checks health with it.
    func testMaintenanceResultSwitchesTheTopology() async throws {
        for (start, reported) in [(DeploymentTopology.legacy, DeploymentTopology.gateway), (.gateway, .legacy)] {
            try await withIsolation {
                let directory = scratchDirectory
                var services = services(probe: readyProbe(directory: directory, managed: true, gateway: false),
                                        result: DeploymentExecutionResult(cpaManagementKey: "cpa_m", cpampAdminKey: "cpamp_m"))
                let maintenance = DeploymentMaintenanceResult(backupName: "upgrade-x", detail: "done", topology: reported,
                                                              packEngineKeyFingerprint: reported == .gateway ? Self.fingerprint : nil)
                services.upgrade = { _ in maintenance }
                services.rollback = { _ in maintenance }
                let store = DeploymentStore(autoProbe: false, services: services)
                store.installDirectory = directory
                store.attachForTesting(topology: start, managementKey: "cpa_m", adminKey: "cpamp_m", installed: true)
                start == .legacy ? store.upgradeDeployment() : store.rollbackDeployment()
                try await waitUntil({ !store.isMaintaining && store.stage == .attached }, "maintenance: \(store.maintenanceError ?? "")")
                XCTAssertEqual(store.topology, reported)
                XCTAssertEqual(DeploymentProfileStore.load()?.topology, reported)
                XCTAssertEqual(URLProtocolStub.recordedRequests.contains { $0.0.url?.port == 18320 }, reported == .gateway)
                if reported == .gateway { XCTAssertEqual(store.packEngineKeyFingerprint, Self.fingerprint) }
            }
        }
    }

    func testAdoptionTakesTheProbedTopologyAndFingerprint() async throws {
        for gateway in [true, false] {
            try await withIsolation {
                let directory = scratchDirectory
                let result = DeploymentExecutionResult(cpaManagementKey: "cpa_adopt", cpampAdminKey: "cpamp_adopt",
                                                       packEngineKeyFingerprint: gateway ? Self.fingerprint : nil)
                let store = DeploymentStore(autoProbe: false, services: services(
                    probe: readyProbe(directory: directory, managed: true, gateway: gateway), result: result
                ))
                store.installDirectory = directory
                store.probeTarget()
                try await waitUntil({ store.probe != nil && !store.isProbing }, "probe")
                XCTAssertEqual(store.topology, .legacy, "nothing changes before the adoption")
                store.adoptProbedDeploymentForTesting()
                try await waitUntil({ store.stage == .attached }, "adoption: \(store.deploymentError ?? "")")
                XCTAssertEqual(store.topology, gateway ? .gateway : .legacy)
                XCTAssertEqual(store.packEngineKeyFingerprint, gateway ? Self.fingerprint : nil)
                XCTAssertEqual(DeploymentProfileStore.load()?.topology, gateway ? .gateway : .legacy)
                XCTAssertEqual(URLProtocolStub.recordedRequests.contains { $0.0.url?.port == 18320 }, gateway)
            }
        }
    }
}
