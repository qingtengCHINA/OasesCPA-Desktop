import AppKit
import SwiftUI
import XCTest
@testable import OasesCPA

/// Offscreen renders of every welcome step and every 连接与部署 state, in zh-Hans / en and light /
/// dark. Opt-in (skipped unless `OASES_SNAPSHOT_DIR` is set); the stores are the idle offline
/// fixture, the phase or state is fixed through the views' overrides.
@MainActor
final class WelcomeSnapshotTests: XCTestCase {
    private var savedLanguage: String?
    private var directory: URL!

    override func setUp() async throws {
        directory = try SnapshotSupport.outputDirectory("welcome")
        savedLanguage = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
    }

    override func tearDown() async throws {
        guard directory != nil else { return }
        SnapshotSupport.reset(savedLanguage: savedLanguage)
    }

    private func eachVariant(_ body: (AppLanguage, SnapshotSupport.Appearance) throws -> Void) rethrows {
        for language in SnapshotSupport.languages {
            for appearance in SnapshotSupport.Appearance.allCases {
                try body(language, appearance)
            }
        }
    }

    static let windowSize = CGSize(width: 880, height: 600)

    private static var upgradeFailure: UpgradeFailure {
        UpgradeFailure(standardError: "OASES_UPGRADE_FAILURE stage=node status=18\nOASES_UPGRADE_OUTCOME changes=restored running=yes\n")!
    }

    static let welcomeCases: [(String, WelcomeStep, WelcomePhase, DeploymentFailure?, MaintenanceFailure?)] = [
        ("1-install", .install, .install, nil, nil),
        ("2-preparing", .install, .installing(.preparing), nil, nil),
        ("2-running", .install, .installing(.running(stage: "verify-cpamp")), nil, nil),
        ("2-running-unreported", .install, .installing(.running(stage: nil)), nil, nil),
        ("2-verifying", .install, .installing(.verifying), nil, nil),
        ("2-failed-offline", .install, .installing(.failed(stage: "download-cli")),
         DeploymentFailure(kind: .offline, stage: "download-cli", exitStatus: 18, machineState: .partialFilesNothingRunning), nil),
        ("2-failed-port", .install, .installing(.failed(stage: nil)),
         DeploymentFailure(kind: .portBusy(port: 8317, process: "node"), stage: nil, exitStatus: nil, machineState: .unchanged), nil),
        ("2-failed-health", .install, .installing(.failed(stage: "wait-gateway")),
         DeploymentFailure(kind: .healthTimeout, stage: "wait-gateway", exitStatus: 26, machineState: .partialFilesMaybeRunning), nil),
        ("2-failed-folder", .install, .installing(.failed(stage: nil)),
         DeploymentFailure(kind: .directoryNotEmpty, stage: nil, exitStatus: 12, machineState: .unchanged), nil),
        ("3-ready", .ready, .ready, nil, nil),
        ("U-upgrade", .upgrade, .upgrade, nil, nil),
        ("U-running", .upgrade, .upgrading(.running), nil, nil),
        ("U-failed-restored", .upgrade, .upgrading(.failed(stage: "node")), nil, .upgrade(upgradeFailure)),
        ("U-failed-other", .upgrade, .upgrading(.failed(stage: nil)), nil, .other),
        ("U-failed-refused", .upgrade, .upgrading(.failed(stage: nil)), nil,
         .refused(DeploymentExecutionError.downgradeRefused(component: "engine", installed: "8.1.0", target: "8.0.51").localizedDescription)),
        ("U-done", .upgrade, .upgraded, nil, nil),
    ]

    func testWelcomeSteps() throws {
        try eachVariant { language, appearance in
            for (name, step, phase, failure, maintenance) in Self.welcomeCases {
                let fixture = SnapshotFixture()
                try SnapshotSupport.render(
                    WelcomeFlowView(initialStep: step, phaseOverride: phase, failureOverride: failure, maintenanceFailureOverride: maintenance) { _ in }
                        .snapshotEnvironment(fixture),
                    size: Self.windowSize,
                    appearance: appearance,
                    language: language,
                    name: "welcome-\(name)-\(language.rawValue)-\(appearance.rawValue)",
                    directory: directory
                )
            }
        }
    }

    func testCheckingView() throws {
        try eachVariant { language, appearance in
            let session = try SnapshotSupport.begin(
                LaunchCheckingView().snapshotEnvironment(SnapshotFixture()),
                size: CGSize(width: 480, height: 200),
                appearance: appearance,
                language: language
            )
            defer { session.close() }
            SnapshotSupport.settle(0.5)
            _ = try session.write(name: "checking-\(language.rawValue)-\(appearance.rawValue)", to: directory)
        }
    }

    static let connectionCases: [(String, ConnectionPageState)] = [
        ("checking", .checking),
        ("not-deployed", .notDeployed),
        ("deploying", .deploying(.running(stage: "install-node"))),
        ("running", .running),
        ("stopped", .stopped),
        ("legacy", .legacy),
        ("maintaining", .maintaining),
        ("attention-not-connected", .needsAttention(.notConnected)),
        ("attention-unhealthy", .needsAttention(.unhealthy)),
        ("attention-removal", .needsAttention(.removalFailed)),
        ("error-checksum", .error(DeploymentFailure(kind: .checksumMismatch, stage: "verify-cli", exitStatus: 17, machineState: .partialFilesNothingRunning))),
    ]

    func testConnectionStates() throws {
        try eachVariant { language, appearance in
            for (name, state) in Self.connectionCases {
                let fixture = SnapshotFixture(section: .environments)
                try SnapshotSupport.render(
                    ConnectionCenterView(stateOverride: state).snapshotEnvironment(fixture),
                    size: CGSize(width: 900, height: 760),
                    appearance: appearance,
                    language: language,
                    name: "connection-\(name)-\(language.rawValue)-\(appearance.rawValue)",
                    directory: directory
                )
            }
        }
    }
}
