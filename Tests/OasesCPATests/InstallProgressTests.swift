import XCTest
@testable import OasesCPA

/// The install checklist rows, the live progress reader, the Trash step of a cancelled install
/// and the port check.
final class InstallProgressTests: XCTestCase {
    // MARK: - Checklist rows

    func testInstallChecklistMapsEveryScriptStage() {
        let stages = [
            "prepare", "secure-directories", "resolve-cli-version", "download-cli", "verify-cli", "install-cli",
            "resolve-cpamp-version", "download-cpamp", "verify-cpamp", "install-cpamp", "install-node",
            "install-gateway", "bootstrap-gateway", "configure-cli", "start-cli", "wait-cli", "start-cpamp",
            "wait-cpamp", "start-gateway", "wait-gateway", "finalize",
        ]
        var lastIndex = 0
        for stage in stages {
            let id = InstallChecklist.rowID(forStage: stage)
            XCTAssertNotNil(id, stage)
            let index = InstallChecklist.rowIDs.firstIndex(of: id ?? "") ?? -1
            XCTAssertGreaterThanOrEqual(index, lastIndex, "\(stage) keeps the script order")
            lastIndex = index
        }
        // Every stage the install script sets is known.
        let script = DeploymentExecutor().scriptForVerification(method: .native, installDirectory: "/x", gatewayPayloadBase64: "")
        let regex = try! NSRegularExpression(pattern: #"set_stage "([a-z0-9-]+)""#)
        let found = Set(regex.matches(in: script, range: NSRange(script.startIndex..., in: script)).compactMap {
            Range($0.range(at: 1), in: script).map { String(script[$0]) }
        })
        XCTAssertEqual(found, Set(stages))
    }

    func testRunningRowsMarkDoneActiveAndPendingAndShowBytesWithoutAPercentage() {
        let rows = InstallChecklist.rows(phase: .running(stage: "download-cpamp"), receivedBytes: 2_800_000, language: .english)
        XCTAssertEqual(rows.map(\.status), [.done, .done, .active, .pending, .pending, .pending, .pending])
        let detail = rows[2].detail ?? ""
        XCTAssertTrue(detail.hasPrefix("Downloading · "), detail)
        XCTAssertTrue(detail.contains("MB"), detail)
        XCTAssertFalse(rows.contains { ($0.detail ?? "").contains("%") })
        XCTAssertEqual(rows[1].title, "Download and verify CLIProxyAPI v8.0.51")
        // No stage (an SSH target): no row claims to be active.
        XCTAssertTrue(InstallChecklist.rows(phase: .running(stage: nil)).allSatisfy { $0.status == .pending })
        XCTAssertEqual(InstallChecklist.rows(phase: .failed(stage: "wait-gateway")).map(\.status), [.done, .done, .done, .done, .done, .done, .failed])
        XCTAssertTrue(InstallChecklist.rows(phase: .done).allSatisfy { $0.status == .done })
    }

    func testUpgradeRowsAreOnlyMarkedFromAReportedFailureStage() {
        XCTAssertTrue(UpgradeChecklist.rows(phase: .running).allSatisfy { $0.status == .pending }, "the upgrade reports no live stage")
        XCTAssertEqual(UpgradeChecklist.rows(phase: .failed(stage: "migration-keys")).map(\.status), [.done, .done, .done, .failed, .pending, .pending])
        XCTAssertEqual(UpgradeChecklist.rows(phase: .failed(stage: "ports")).map(\.status), [.failed, .pending, .pending, .pending, .pending, .pending])
        for stage in UpgradeFailure.stages { XCTAssertNotNil(UpgradeChecklist.rowID(forStage: stage), stage) }
    }

    // MARK: - Progress reader

    func testMarkerOfAnotherRunIsIgnoredAndTheDownloadSizeIsRead() throws {
        let root = FakeArtifacts.scratchRoot.appendingPathComponent("welcome-progress-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cli-proxy-api/downloads"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = "timestamp=2026-11-08T00:00:00Z\nmethod=native\nstage=download-cli\npid=1\ncontrol_token=abc-1\n"
        try Data(marker.utf8).write(to: root.appendingPathComponent(".oases-cpa-installing"))
        let asset = try XCTUnwrap(DeploymentPinSet.current.engine.assets[.local])
        try Data(count: 4_096).write(to: root.appendingPathComponent("cli-proxy-api/downloads/\(asset.fileName).part"))

        XCTAssertNil(InstallProgressReader.read(installDirectory: root.path, controlToken: "other"), "a marker from an earlier attempt")
        let snapshot = try XCTUnwrap(InstallProgressReader.read(installDirectory: root.path, controlToken: "abc-1"))
        XCTAssertEqual(snapshot, InstallProgressSnapshot(stage: "download-cli", receivedBytes: 4_096))
        XCTAssertNil(InstallAttemptMarker(contents: "stage=$(rm -rf /)\n"), "only stage-shaped values")
    }

    // MARK: - Trash after a cancelled install

    func testCancelledAttemptGoesToTheTrashButBackupsAndFinishedDeploymentsStay() throws {
        let manager = FileManager.default
        let root = FakeArtifacts.scratchRoot.appendingPathComponent("welcome-trash-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        for directory in ["cli-proxy-api/downloads", "logs", "secrets", "backups/upgrade-1"] {
            try manager.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appendingPathComponent(".oases-cpa-installing"))
        try Data().write(to: root.appendingPathComponent(".oases-cpa-managed"))

        var trashed: [String] = []
        let moved = try InstallAttemptTrash.moveAttemptToTrash(root: root) { url in
            trashed.append(url.lastPathComponent)
            try manager.removeItem(at: url) // the fake Trash: this scratch root only
        }
        XCTAssertEqual(moved, 5)
        XCTAssertEqual(Set(trashed), ["cli-proxy-api", "logs", "secrets", ".oases-cpa-installing", ".oases-cpa-managed"])
        XCTAssertTrue(manager.fileExists(atPath: root.appendingPathComponent("backups/upgrade-1").path), "backups are kept")
        XCTAssertTrue(manager.fileExists(atPath: root.path), "a root with backups stays")

        // A finished deployment is never touched.
        try Data().write(to: root.appendingPathComponent(".oases-cpa-installed"))
        XCTAssertThrowsError(try InstallAttemptTrash.moveAttemptToTrash(root: root) { _ in XCTFail("nothing may move") })
    }

    func testAnEmptyAttemptRootGoesToTheTrashToo() throws {
        let manager = FileManager.default
        let root = FakeArtifacts.scratchRoot.appendingPathComponent("welcome-trash-empty-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root.appendingPathComponent("node"), withIntermediateDirectories: true)
        var trashed: [String] = []
        try InstallAttemptTrash.moveAttemptToTrash(root: root) { url in
            trashed.append(url.lastPathComponent)
            try manager.removeItem(at: url)
        }
        XCTAssertEqual(trashed, ["node", root.lastPathComponent])
    }

    // MARK: - Ports

    func testFirstBusyPortAndLsofParsing() {
        XCTAssertEqual(LocalPortCheck.firstBusyPort([8317, 18317, 18316], isListening: { $0 == 18317 }), 18317)
        XCTAssertNil(LocalPortCheck.firstBusyPort([8317], isListening: { _ in false }))
        XCTAssertEqual(LocalPortCheck.processName(fromLsofOutput: "p4242\ncnode\nf23\n"), "node")
        XCTAssertNil(LocalPortCheck.processName(fromLsofOutput: ""))
    }
}

/// `DeploymentStore.startOneClickInstall` against fake services: one click goes from the port
/// check through the probe to the install without a confirmation step; a busy port stops it
/// before anything runs; a cancelled install moves its files to the Trash.
@MainActor
final class OneClickInstallStoreTests: XCTestCase {
    private func probe(directory: String, managed: Bool = false) -> DeploymentProbe {
        DeploymentProbe(
            operatingSystem: "Darwin", architecture: "arm64", shell: "/bin/zsh",
            curlPath: "/usr/bin/curl", tarPath: "/usr/bin/tar", opensslPath: "/usr/bin/openssl", sha256Path: "/usr/bin/shasum",
            dockerPath: nil, dockerComposeAvailable: false, dockerDaemonAvailable: false, installWritable: true,
            testedInstallDirectory: directory,
            hasManagedRoot: managed, hasManagedInstallation: managed, hasRecoverableCredentials: managed,
            hasNativeRuntime: managed, hasDockerRuntime: false
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
        let suiteName = "oases-one-click-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        try await DeploymentProfileStore.withDefaultsForTesting(suite) {
            try await KeychainStore.withInMemoryKeychainForTesting {
                try await body()
            }
        }
    }

    private func services(
        directory: String,
        busyPort: (Int, String?)? = nil,
        execute: @escaping @Sendable (DeploymentExecutionRequest, String) async throws -> DeploymentExecutionResult,
        trash: @escaping @Sendable (DeploymentExecutionRequest) async throws -> Void = { _ in }
    ) -> DeploymentStoreServices {
        URLProtocolStub.install { request, _ in
            request.url?.path == "/healthz"
                ? .json(200, #"{"ok":true,"version":"0.1.0"}"#, for: request)
                : .json(200, "{}", for: request)
        }
        let readyProbe = probe(directory: directory)
        var services = DeploymentStoreServices(
            execute: execute,
            probe: { _ in readyProbe },
            readExistingCredentials: { _ in throw DeploymentExecutionError.missingResult },
            upgrade: { _ in throw DeploymentExecutionError.missingResult },
            rollback: { _ in throw DeploymentExecutionError.missingResult },
            healthSession: URLProtocolStub.makeSession()
        )
        services.busyLocalPort = { busyPort.map { (port: $0.0, process: $0.1) } }
        services.readInstallProgress = { _, _ in InstallProgressSnapshot(stage: "install-node", receivedBytes: nil) }
        services.trashInstallAttempt = trash
        return services
    }

    private var scratchDirectory: String {
        FakeArtifacts.scratchRoot.appendingPathComponent("one-click-\(UUID().uuidString.prefix(8))").path
    }

    func testOneClickInstallsWithoutAConfirmationStep() async throws {
        try await withIsolation {
            let directory = scratchDirectory
            let result = DeploymentExecutionResult(cpaManagementKey: "cpa_test", cpampAdminKey: "cpamp_test")
            let store = DeploymentStore(autoProbe: false, services: services(directory: directory, execute: { _, _ in
                try await Task.sleep(nanoseconds: 700_000_000)
                return result
            }))
            store.installDirectory = directory
            store.startOneClickInstall()
            XCTAssertTrue(store.isPreparingOneClickInstall)
            try await waitUntil({ store.stage == .installing }, "the script starts without a plan confirmation")
            try await waitUntil({ store.installProgress?.stage == "install-node" }, "the live stage is polled")
            try await waitUntil({ store.stage == .attached }, "install: \(store.deploymentError ?? "")")
            XCTAssertFalse(store.isPreparingOneClickInstall)
            XCTAssertEqual(store.managedRootPresent, true)
            XCTAssertNil(store.installProgress, "a finished install forgets its stage")
        }
    }

    func testABusyPortStopsBeforeTheProbe() async throws {
        try await withIsolation {
            let directory = scratchDirectory
            let store = DeploymentStore(autoProbe: false, services: services(directory: directory, busyPort: (8317, "node"), execute: { _, _ in
                XCTFail("nothing may run")
                throw DeploymentExecutionError.missingResult
            }))
            store.installDirectory = directory
            store.startOneClickInstall()
            try await waitUntil({ store.stage == .failed }, "port check")
            XCTAssertNil(store.probe, "no probe after a busy port")
            XCTAssertEqual(store.oneClickPreflightFailure?.kind, .portBusy(port: 8317, process: "node"))
            XCTAssertEqual(store.oneClickPreflightFailure?.machineState, .unchanged)
            XCTAssertEqual(
                store.oneClickPreflightFailure?.message(language: .english),
                "Port 8317 is in use by another app (node). Quit it and try again. Nothing was changed."
            )
        }
    }
}
