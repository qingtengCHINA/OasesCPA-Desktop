import XCTest
@testable import OasesCPA

final class DeploymentSupplyChainContractTests: XCTestCase {
    // Index digests of the multi-platform images (docs/acceptance/supply-chain-pins.md).
    private let cliDockerDigest = "eceasy/cli-proxy-api@sha256:15d13889e1a39a688be306dfbf2f6cf9003e99cd913b5070fa463f8ab2aa0031"
    private let cpampDockerDigest = "seakee/cpa-manager-plus@sha256:0e803f21d51aceea7b752686417bf57f40678d8068fe102ba23cb2a3afb414e1"
    private let previousCLIDockerDigest = "eceasy/cli-proxy-api@sha256:7f598ce64478a8a5f90ed76875e0e9b0e7d77b80e17184b13df18c3d5bdb3def"
    private let previousCPAMPDockerDigest = "seakee/cpa-manager-plus@sha256:9a9715cc0849ee2feb553983713e70a197a5272a73b7a6f969fcff4dc26ab465"

    func testCurrentPinsCoverEveryPlatformWithSHA256() throws {
        let p = DeploymentPinSet.current
        XCTAssertEqual(p.engine.tag, "v8.0.51"); XCTAssertEqual(p.cpamp.tag, "v1.14.10"); XCTAssertTrue(p.node.tag.hasPrefix("v24."))
        var allSHAs: [String] = []
        for artifact in [p.engine, p.cpamp, p.node] {
            for platform in DeploymentPlatform.allCases {
                let asset = try XCTUnwrap(artifact.assets[platform], "\(artifact.tag) \(platform.rawValue)")
                XCTAssertNotNil(asset.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
                XCTAssertTrue(asset.fileName.hasSuffix(".tar.gz"))
                allSHAs.append(asset.sha256)
            }
        }
        XCTAssertEqual(allSHAs.count, 12); XCTAssertEqual(Set(allSHAs).count, 12)   // no duplicates
        // The engine's linux/amd64 package is the one the production upgrade record names.
        XCTAssertEqual(p.engine.assets[.linuxAMD64]?.sha256, "15de160e1fd97a0f9f7e0577582c765b14e040ab6a8314f514af9fae8a2c4700")
        // Engine asset names use aarch64 (R13), the panel and Node use arm64.
        XCTAssertEqual(p.engine.assets[.darwinARM64]?.fileName, "CLIProxyAPI_8.0.51_darwin_aarch64.tar.gz")
        XCTAssertEqual(p.cpamp.assets[.linuxARM64]?.fileName, "cpa-manager-plus_v1.14.10_linux_arm64.tar.gz")
        XCTAssertEqual(p.node.assets[.darwinAMD64]?.fileName, "node-\(p.node.tag)-darwin-x64.tar.gz")
        XCTAssertEqual(p.gateway, GatewayBundle.bundled)
    }

    func testSelectionScriptSelectsEachPlatform() throws {
        let pins = DeploymentPinSet.current
        for platform in DeploymentPlatform.allCases {
            let parts = platform.rawValue.split(separator: "/").map(String.init)
            let result = try runBash("""
            set -euo pipefail
            RELEASE_OS="\(parts[0])"
            ARCH="\(parts[1])"
            \(pins.nativeSelectionScript())
            printf '%s\\n' "$CLI_ASSET" "$CLI_EXPECTED_SHA256" "$CLI_PACKAGE" "$CPAMP_ASSET" "$CPAMP_EXPECTED_SHA256" "$CPAMP_PACKAGE" \\
              "$NODE_ASSET" "$NODE_EXPECTED_SHA256" "$NODE_PACKAGE" "$CLI_VERSION_TAG" "$CPAMP_VERSION_TAG" "$NODE_VERSION_TAG" \\
              "$GATEWAY_VERSION" "$GATEWAY_FILE" "$GATEWAY_EXPECTED_SHA256" "$PLATFORM"
            """)
            XCTAssertEqual(result.status, 0, result.stderr)
            let cli = try XCTUnwrap(pins.engine.assets[platform])
            let panel = try XCTUnwrap(pins.cpamp.assets[platform])
            let node = try XCTUnwrap(pins.node.assets[platform])
            XCTAssertEqual(result.lines, [
                cli.fileName, cli.sha256, String(cli.fileName.dropLast(7)),
                panel.fileName, panel.sha256, String(panel.fileName.dropLast(7)),
                node.fileName, node.sha256, String(node.fileName.dropLast(7)),
                pins.engine.tag, pins.cpamp.tag, pins.node.tag,
                pins.gateway.version, pins.gateway.fileName, pins.gateway.sha256, platform.rawValue,
            ], platform.rawValue)
        }
    }

    func testUnknownPlatformExits14() throws {
        for (os, arch) in [("darwin", "aarch64"), ("freebsd", "amd64"), ("linux", "riscv64"), ("windows", "amd64")] {
            let result = try runBash("""
            set -euo pipefail
            RELEASE_OS="\(os)"
            ARCH="\(arch)"
            \(DeploymentPinSet.current.nativeSelectionScript())
            echo selected
            """)
            XCTAssertEqual(result.status, 14, "\(os)/\(arch)")
            XCTAssertFalse(result.lines.contains("selected"))
        }
    }

    func testNoScriptUsesLatestOrRemoteChecksums() {
        let scripts = [
            DeploymentExecutor().scriptForVerification(method: .native, installDirectory: "~/.oases-cpa"),
            DeploymentExecutor().scriptForVerification(method: .docker, installDirectory: "~/.oases-cpa"),
            DeploymentMaintenanceService().upgradeScriptForVerification(method: .native, installDirectory: "~/.oases-cpa"),
            DeploymentMaintenanceService().upgradeScriptForVerification(method: .docker, installDirectory: "~/.oases-cpa"),
        ]
        for script in scripts {
            for forbidden in ["/releases/latest", "checksums.txt", "SHASUMS256"] {
                XCTAssertFalse(script.contains(forbidden), forbidden)
            }
        }
    }

    func testDockerPinsUseV8AndV1_14Digests() {
        let pins = DeploymentPinSet.current
        for image in [pins.cliDockerImage, pins.cpampDockerImage] {
            XCTAssertNotNil(image.range(of: "^[a-z0-9-]+/[a-z0-9-]+@sha256:[0-9a-f]{64}$", options: .regularExpression), image)
        }
        XCTAssertEqual(pins.cliDockerImage, cliDockerDigest)
        XCTAssertEqual(pins.cpampDockerImage, cpampDockerDigest)
        XCTAssertNotEqual(pins.cliDockerImage, previousCLIDockerDigest)
        XCTAssertNotEqual(pins.cpampDockerImage, previousCPAMPDockerDigest)
        XCTAssertTrue(pins.cliDockerImage.hasPrefix("eceasy/cli-proxy-api@"))
        XCTAssertTrue(pins.cpampDockerImage.hasPrefix("seakee/cpa-manager-plus@"))
    }

    func testMaintenanceUsesTheCurrentPinSet() {
        // H4: the upgrade script reads DeploymentPinSet.current (with the compatibility names).
        let upgrade = DeploymentMaintenanceService().upgradeScriptForVerification(method: .native, installDirectory: "~/.oases-cpa")
        XCTAssertTrue(upgrade.contains(DeploymentPinSet.current.nativeSelectionScript()))
        let docker = DeploymentMaintenanceService().upgradeScriptForVerification(method: .docker, installDirectory: "~/.oases-cpa")
        XCTAssertTrue(docker.contains(DeploymentPinSet.current.dockerImageEnvironmentScript()))
    }

    func testNativeInstallUsesPinnedTagsAndEveryPlatformDigest() {
        let script = DeploymentExecutor().scriptForVerification(method: .native, installDirectory: "~/.oases-cpa")

        assertNativePins(in: script)
        XCTAssertFalse(script.contains("/releases/latest"))
        XCTAssertFalse(script.contains("checksums.txt"))
        XCTAssertTrue(script.contains("verify_fixed_archive"))
        assertGitHubReleaseRedirectPolicy(in: script)
    }

    func testNativeMaintenanceUsesPinnedTagsAndEveryPlatformDigest() {
        let script = DeploymentMaintenanceService().upgradeScriptForVerification(
            method: .native,
            installDirectory: "~/.oases-cpa"
        )

        assertNativePins(in: script)
        XCTAssertFalse(script.contains("/releases/latest"))
        XCTAssertFalse(script.contains("checksums.txt"))
        XCTAssertTrue(script.contains("verify_fixed_archive"))
        assertGitHubReleaseRedirectPolicy(in: script)
    }

    func testDockerInstallPinsBothComposeImagesAndPassesThemToInstallerAndCompose() {
        let script = DeploymentExecutor().scriptForVerification(method: .docker, installDirectory: "~/.oases-cpa")

        assertDockerPins(in: script)
        XCTAssertTrue(script.contains("CPAMP_IMAGE=\"$CPAMP_DOCKER_IMAGE\""))
        XCTAssertTrue(script.contains("CPAMP_CPA_IMAGE=\"$CLI_DOCKER_IMAGE\""))
        XCTAssertTrue(script.contains("CPAMP_IMAGE=\"$CPAMP_DOCKER_IMAGE\" CPA_IMAGE=\"$CLI_DOCKER_IMAGE\" docker compose pull"))
        XCTAssertTrue(script.contains("CPAMP_IMAGE=\"$CPAMP_DOCKER_IMAGE\" CPA_IMAGE=\"$CLI_DOCKER_IMAGE\" docker compose up -d"))
        XCTAssertTrue(script.contains("docker compose pull"))
        XCTAssertTrue(script.contains("docker compose up -d"))
        XCTAssertFalse(script.contains("/releases/latest"))
    }

    func testDockerMaintenancePinsBothComposeImagesAndUsesThemForPullAndUp() {
        let service = DeploymentMaintenanceService()
        let upgrade = service.upgradeScriptForVerification(method: .docker, installDirectory: "~/.oases-cpa")
        let rollback = service.rollbackScriptForVerification(method: .docker, installDirectory: "~/.oases-cpa")

        assertDockerPins(in: upgrade)
        assertDockerPins(in: rollback)
        XCTAssertTrue(upgrade.contains("CPAMP_IMAGE=\"$CPAMP_DOCKER_IMAGE\""))
        XCTAssertTrue(upgrade.contains("CPAMP_IMAGE=\"$CPAMP_DOCKER_IMAGE\" CPA_IMAGE=\"$CLI_DOCKER_IMAGE\" docker compose pull"))
        XCTAssertTrue(upgrade.contains("CPAMP_IMAGE=\"$CPAMP_DOCKER_IMAGE\" CPA_IMAGE=\"$CLI_DOCKER_IMAGE\" docker compose up -d"))
        XCTAssertTrue(rollback.contains("CPAMP_IMAGE=\"$CPAMP_DOCKER_IMAGE\""))
        XCTAssertTrue(rollback.contains("CPAMP_IMAGE=\"$CPAMP_DOCKER_IMAGE\" CPA_IMAGE=\"$CLI_DOCKER_IMAGE\" docker compose up -d"))
        XCTAssertFalse(upgrade.contains("/releases/latest"))
        XCTAssertFalse(rollback.contains("/releases/latest"))
    }

    func testNativeScriptsFailClosedForUnsupportedPlatform() {
        let executor = DeploymentExecutor().scriptForVerification(method: .native, installDirectory: "~/.oases-cpa")
        let maintenance = DeploymentMaintenanceService().upgradeScriptForVerification(
            method: .native,
            installDirectory: "~/.oases-cpa"
        )

        for script in [executor, maintenance] {
            XCTAssertTrue(script.contains("*)"))
            XCTAssertTrue(script.contains("exit 14"))
        }
    }

    private func assertNativePins(in script: String, file: StaticString = #filePath, line: UInt = #line) {
        let pins = DeploymentPinSet.current
        var expected = [
            "CLI_VERSION_TAG=\"v8.0.51\"",
            "CPAMP_VERSION_TAG=\"v1.14.10\"",
            "NODE_VERSION_TAG=\"\(pins.node.tag)\"",
        ]
        for artifact in [pins.engine, pins.cpamp, pins.node] {
            for platform in DeploymentPlatform.allCases {
                if let asset = artifact.assets[platform] { expected.append(asset.sha256); expected.append(asset.fileName) }
            }
        }
        for value in expected {
            XCTAssertTrue(script.contains(value), value, file: file, line: line)
        }
    }

    private func assertDockerPins(in script: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(script.contains(cliDockerDigest), file: file, line: line)
        XCTAssertTrue(script.contains(cpampDockerDigest), file: file, line: line)
        XCTAssertFalse(script.contains(":latest"), file: file, line: line)
    }

    private func assertGitHubReleaseRedirectPolicy(in script: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(script.contains("--location"), file: file, line: line)
        XCTAssertTrue(script.contains("--max-redirs 3"), file: file, line: line)
        XCTAssertTrue(script.contains("--proto '=https'"), file: file, line: line)
        XCTAssertTrue(script.contains("--proto-redir '=https'"), file: file, line: line)
        XCTAssertFalse(script.contains("--max-redirs 0"), file: file, line: line)
    }

    private struct BashResult { let status: Int32; let lines: [String]; let stderr: String }

    private func runBash(_ script: String) throws -> BashResult {
        let process = Process()
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-s"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        input.fileHandleForWriting.closeFile()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: out, encoding: .utf8) ?? ""
        return BashResult(
            status: process.terminationStatus,
            lines: text.split(separator: "\n").map(String.init),
            stderr: String(data: err, encoding: .utf8) ?? ""
        )
    }
}
