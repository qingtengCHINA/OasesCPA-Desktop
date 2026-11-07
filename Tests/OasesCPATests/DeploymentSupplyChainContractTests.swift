import XCTest
@testable import OasesCPA

final class DeploymentSupplyChainContractTests: XCTestCase {
    private let cliDockerDigest = "eceasy/cli-proxy-api@sha256:7f598ce64478a8a5f90ed76875e0e9b0e7d77b80e17184b13df18c3d5bdb3def"
    private let cpampDockerDigest = "seakee/cpa-manager-plus@sha256:9a9715cc0849ee2feb553983713e70a197a5272a73b7a6f969fcff4dc26ab465"

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
        let expected = [
            "CLI_VERSION_TAG=\"v7.2.141\"",
            "CPAMP_VERSION_TAG=\"v1.11.10\"",
            "728fb56a1a45dc3590ddb94ada247393ee2d464b089170562482cf584fa27bc2",
            "fa88dbabf5000e04095ce7b2c1a7babbc579a58755c6ef3b94e6013c1daae50a",
            "2881c0a6bcbc412c4bbdb2799ffbf1b4bcdd927475e1e42f621b68eae314ef3f",
            "a70015ee303502e24be64061dd0d5985b2b4600f0605a076b993322d3b7effb",
            "b2e8942fb1ea66abe01d5f01141093ee46eb1f8d4aab9a034ee305722e4a64e9",
            "62676783a3d181a406828d3295dffc7e043f96704baaaf5346df8bb43e0081db",
            "c511e029b34f6f27bec65c2853b47991c1286767371a69d716bea29c8b8cc184",
            "72db0619b1e4fec3d82674b0b80797485eec3c2e5730484a43777b0f953f85f8"
        ]
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
}
