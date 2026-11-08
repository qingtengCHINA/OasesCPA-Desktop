import XCTest
@testable import OasesCPA

/// The install failure classifier, fed with the real stderr of the native install script run
/// against fake packages and fake tools (`FakeArtifacts`: no network, scratch roots only), plus
/// a few synthetic messages for causes the fakes cannot produce (marked as such).
final class DeploymentFailureClassifierTests: XCTestCase {
    private var startedRoots: [(FakeArtifacts, URL)] = []

    override func tearDown() {
        for (fake, root) in startedRoots { fake.stopProcesses(under: root) }
        startedRoots.removeAll()
        super.tearDown()
    }

    /// Runs the real install script; `curlFailure` replaces the download with curl's own error
    /// line and exit code (`curl` and `sleep` are shell functions, so the retries are instant).
    private func failedInstall(
        _ caseName: String,
        pins: ((DeploymentPinSet) -> DeploymentPinSet)? = nil,
        curlFailure: (message: String, code: Int)? = nil,
        prepareRoot: ((URL) throws -> Void)? = nil,
        extraEnvironment: [String: String] = [:],
        gatewayHealthAttempts: Int = 2
    ) throws -> FakeArtifacts.RunResult {
        let fake = try FakeArtifacts.make(caseName: caseName)
        let root = fake.caseDirectory.appendingPathComponent("root", isDirectory: true)
        try prepareRoot?(root)
        startedRoots.append((fake, root))
        let script = DeploymentExecutor().scriptForVerification(
            method: .native,
            installDirectory: root.path,
            pins: pins?(fake.pins) ?? fake.pins,
            gatewayPayloadBase64: fake.gatewayPayloadBase64,
            gatewayHealthAttempts: gatewayHealthAttempts
        )
        var prelude = ""
        if let curlFailure {
            prelude = """
            sleep() { :; }
            curl() {
              case "$*" in
                *releases/download*|*nodejs.org*) printf '%s\\n' '\(curlFailure.message)' >&2; return \(curlFailure.code) ;;
                *) command curl "$@" ;;
              esac
            }
            """
        }
        let result = try fake.run(script, prelude: prelude, extraEnvironment: extraEnvironment)
        XCTAssertNotEqual(result.status, 0, "the fixture must fail")
        return result
    }

    /// What the store keeps for a failed script (`BoundedProcessRunner.userFacingMessage`).
    private func storedMessage(_ result: FakeArtifacts.RunResult) -> String {
        SSHConnectionService.userFacingError(result.stderr, fallback: "fallback")
    }

    func testOfflineDownload() throws {
        let run = try failedInstall("offline", curlFailure: ("curl: (6) Could not resolve host: github.com", 6))
        XCTAssertEqual(run.status, 18)
        let failure = DeploymentFailureClassifier.classify(message: storedMessage(run))
        XCTAssertEqual(failure.kind, .offline)
        XCTAssertEqual(failure.stage, "download-cli")
        XCTAssertEqual(failure.exitStatus, 18)
        XCTAssertEqual(failure.machineState, .partialFilesNothingRunning)
        XCTAssertEqual(failure.actions, [.retry, .showLog])
        XCTAssertEqual(
            failure.message(language: .english),
            "Can't reach the download server. Check your network and try again. Nothing is running. Trying again first moves this attempt's files into the backups folder."
        )
    }

    func testInterruptedDownload() throws {
        let run = try failedInstall("interrupted", curlFailure: ("curl: (18) transfer closed with 31457280 bytes remaining to read", 18))
        let failure = DeploymentFailureClassifier.classify(message: storedMessage(run))
        XCTAssertEqual(failure.kind, .downloadInterrupted)
        XCTAssertEqual(failure.actions, [.retry])
    }

    func testDiskFullWhileWritingTheDownload() throws {
        let run = try failedInstall("disk-full", curlFailure: ("curl: (23) Failure writing output to destination, passed 16384 returned 0", 23))
        XCTAssertEqual(DeploymentFailureClassifier.classify(message: storedMessage(run)).kind, .diskFull)
    }

    func testChecksumMismatch() throws {
        let run = try failedInstall("checksum") { pins in
            let wrong = String(repeating: "0", count: 64)
            var assets = pins.engine.assets
            for (platform, asset) in assets { assets[platform] = PinnedAsset(fileName: asset.fileName, sha256: wrong) }
            return DeploymentPinSet(
                engine: PinnedArtifact(tag: pins.engine.tag, assets: assets),
                cpamp: pins.cpamp, node: pins.node, gateway: pins.gateway,
                cliDockerImage: pins.cliDockerImage, cpampDockerImage: pins.cpampDockerImage
            )
        }
        XCTAssertEqual(run.status, 17)
        let failure = DeploymentFailureClassifier.classify(message: storedMessage(run))
        XCTAssertEqual(failure.kind, .checksumMismatch)
        XCTAssertEqual(failure.stage, "verify-cli")
        XCTAssertEqual(InstallChecklist.rows(phase: .failed(stage: failure.stage)).map(\.status), [.done, .failed, .pending, .pending, .pending, .pending, .pending])
    }

    func testHealthTimeoutAfterTheServicesStarted() throws {
        let run = try failedInstall("health", extraEnvironment: ["FAKE_HEALTHZ_BODY": "{\"ok\":true,\"version\":\"other\"}", "FAKE_GATEWAY_EXIT": "1"])
        XCTAssertEqual(run.status, 26)
        let failure = DeploymentFailureClassifier.classify(message: storedMessage(run))
        XCTAssertEqual(failure.kind, .healthTimeout)
        XCTAssertEqual(failure.stage, "wait-gateway")
        XCTAssertEqual(failure.machineState, .partialFilesMaybeRunning, "engine and CPA Manager Plus were started")
        XCTAssertEqual(failure.actions, [.retry, .showLog])
    }

    func testAnExistingDeploymentIsNeverInstalledOver() throws {
        let run = try failedInstall("existing", prepareRoot: { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data().write(to: root.appendingPathComponent(".oases-cpa-installed"))
        })
        XCTAssertEqual(run.status, 12)
        let failure = DeploymentFailureClassifier.classify(message: storedMessage(run))
        XCTAssertEqual(failure.kind, .alreadyInstalled)
        XCTAssertEqual(failure.machineState, .unchanged)
    }

    func testANonEmptyFolderIsRefused() throws {
        let run = try failedInstall("non-empty", prepareRoot: { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: root.appendingPathComponent("notes.txt"))
        })
        XCTAssertEqual(run.status, 12)
        let failure = DeploymentFailureClassifier.classify(message: storedMessage(run))
        XCTAssertEqual(failure.kind, .directoryNotEmpty)
        XCTAssertEqual(failure.actions, [.revealInFinder, .retry])
    }

    func testASymlinkedRootIsUnsafe() throws {
        let run = try failedInstall("symlink", prepareRoot: { root in
            let real = root.deletingLastPathComponent().appendingPathComponent("real-root", isDirectory: true)
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: root, withDestinationURL: real)
        })
        XCTAssertEqual(run.status, 25)
        XCTAssertEqual(DeploymentFailureClassifier.classify(message: storedMessage(run)).kind, .unsafeDirectory)
    }

    func testAnUnwritableParentIsPermissionDenied() throws {
        let fake = try FakeArtifacts.make(caseName: "permission")
        let parent = fake.caseDirectory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o500])
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        let script = DeploymentExecutor().scriptForVerification(
            method: .native,
            installDirectory: parent.appendingPathComponent("root").path,
            pins: fake.pins,
            gatewayPayloadBase64: fake.gatewayPayloadBase64
        )
        let run = try fake.run(script)
        XCTAssertNotEqual(run.status, 0)
        let failure = DeploymentFailureClassifier.classify(message: storedMessage(run))
        XCTAssertEqual(failure.kind, .permissionDenied, run.stderr)
        XCTAssertEqual(failure.machineState, .unchanged)
        XCTAssertEqual(failure.actions, [.revealInFinder, .retry])
    }

    // MARK: - Synthetic (causes the fake tools cannot produce)

    func testSyntheticPortBusyFromTheGatewayLog() {
        // Node's message for a taken listen port, as it would appear in the gateway.log tail.
        let message = "Error: listen EADDRINUSE: address already in use 127.0.0.1:8317\n[t] 部署在阶段 wait-gateway 失败（退出码 26）。"
        let failure = DeploymentFailureClassifier.classify(message: message)
        XCTAssertEqual(failure.kind, .portBusy(port: 8317, process: nil))
        XCTAssertEqual(failure.reason(language: .english), "Port 8317 is in use by another app. Quit it and try again.")
    }

    func testSyntheticAppSideFailures() {
        XCTAssertEqual(DeploymentFailureClassifier.classify(message: "命令执行超时，已停止。").kind, .timedOut)
        XCTAssertEqual(DeploymentFailureClassifier.classify(message: "命令已取消。").kind, .cancelled)
        XCTAssertEqual(DeploymentFailureClassifier.classify(message: "当前部署方式无法继续：缺少curl。").kind, .missingTools)
        let installed = DeploymentFailureClassifier.classify(message: "anything", installed: true)
        XCTAssertEqual(installed.kind, .connectionCheckFailed)
        XCTAssertEqual(installed.machineState, .installed)
        XCTAssertEqual(DeploymentFailureClassifier.classify(message: "something unexpected").kind, .other)
        XCTAssertEqual(DeploymentFailureClassifier.classify(message: "something unexpected").machineState, .unchanged)
    }

    /// The copy never carries raw stderr: every reason is a fixed, translated sentence.
    func testReasonsAreTranslatedSentences() {
        let kinds: [DeploymentFailure.Kind] = [
            .offline, .downloadInterrupted, .checksumMismatch, .portBusy(port: 8317, process: "node"), .portBusy(port: nil, process: nil),
            .permissionDenied, .diskFull, .healthTimeout, .connectionCheckFailed, .alreadyInstalled, .directoryNotEmpty,
            .anotherInstallRunning, .missingTools, .unsupportedPlatform, .unsafeDirectory, .gatewayPackage, .cancelled, .timedOut, .other,
        ]
        let states: [DeploymentFailure.MachineState] = [.unchanged, .partialFilesNothingRunning, .partialFilesMaybeRunning, .installed]
        for kind in kinds {
            for state in states {
                let failure = DeploymentFailure(kind: kind, stage: nil, exitStatus: nil, machineState: state)
                let english = failure.message(language: .english)
                XCTAssertNil(english.range(of: #"\p{Han}"#, options: .regularExpression), english)
                XCTAssertNotNil(failure.message(language: .simplifiedChinese).range(of: #"\p{Han}"#, options: .regularExpression))
            }
        }
    }
}
