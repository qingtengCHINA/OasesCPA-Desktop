import SwiftUI
import XCTest
@testable import OasesCPA

/// The window shell's state line (toolbar subtitle), sidebar order and badges.
final class ShellStatusTests: XCTestCase {
    private let endpoint = "127.0.0.1:8317"

    private func subtitle(
        _ stage: DeploymentStage,
        topology: DeploymentTopology = .gateway,
        method: DeploymentMethod = .native,
        installed: Bool = true,
        language: AppLanguage
    ) -> String {
        ShellStatus.subtitle(
            stage: stage,
            topology: topology,
            method: method,
            hasInstalledDeployment: installed,
            endpoint: endpoint,
            language: language
        )
    }

    func testRunningGatewayShowsTheEndpoint() {
        XCTAssertEqual(subtitle(.attached, language: .simplifiedChinese), "网关运行中 · 127.0.0.1:8317")
        XCTAssertEqual(subtitle(.attached, language: .english), "Gateway running · 127.0.0.1:8317")
    }

    func testNothingDeployedAndSavedTarget() {
        XCTAssertEqual(subtitle(.idle, installed: false, language: .simplifiedChinese), "未部署")
        XCTAssertEqual(subtitle(.idle, installed: false, language: .english), "Not deployed")
        XCTAssertEqual(subtitle(.idle, installed: true, language: .english), "Not Connected")
    }

    func testLegacyNativeDeploymentNeedsTheUpgrade() {
        XCTAssertEqual(subtitle(.attached, topology: .legacy, language: .simplifiedChinese), "需要升级")
        XCTAssertEqual(subtitle(.idle, topology: .legacy, language: .english), "Upgrade needed")
        // A legacy Docker deployment cannot take the gateway: it is simply connected.
        XCTAssertEqual(subtitle(.attached, topology: .legacy, method: .docker, language: .english), "Connected · 127.0.0.1:8317")
    }

    func testTransientAndFailedStates() {
        XCTAssertEqual(subtitle(.installing, language: .english), "Deploying")
        XCTAssertEqual(subtitle(.connecting, language: .english), "Connecting…")
        XCTAssertEqual(subtitle(.failed, language: .english), "Needs attention")
    }

    func testEndpointLabelIsHostAndPort() {
        XCTAssertEqual(ShellStatus.endpointLabel(DeploymentEndpoints(topology: .gateway)), "127.0.0.1:8317")
    }

    func testBadgesOnlyWhereSomethingWaits() {
        XCTAssertNotNil(ShellStatus.sidebarBadge(for: .accountActions, pendingAccountActions: 3, deploymentNeedsUpgrade: false))
        XCTAssertNil(ShellStatus.sidebarBadge(for: .accountActions, pendingAccountActions: 0, deploymentNeedsUpgrade: true))
        XCTAssertNotNil(ShellStatus.sidebarBadge(for: .environments, pendingAccountActions: 0, deploymentNeedsUpgrade: true))
        XCTAssertNil(ShellStatus.sidebarBadge(for: .environments, pendingAccountActions: 5, deploymentNeedsUpgrade: false))
        for section in AppSection.allCases where section != .accountActions && section != .environments {
            XCTAssertNil(ShellStatus.sidebarBadge(for: section, pendingAccountActions: 9, deploymentNeedsUpgrade: true), "\(section)")
        }
    }

    func testSidebarGroupsFollowTheUserJourney() {
        XCTAssertEqual(SectionGroup.allCases, [.overview, .gateway, .accounts, .configuration, .operations])
        let sources: [SectionGroup: String] = [
            .overview: "概览", .gateway: "网关", .accounts: "账号", .configuration: "配置", .operations: "运维",
        ]
        XCTAssertEqual(
            SectionGroup.allCases.map { OasesLocalization.localized(sources[$0] ?? "", language: .english) },
            ["Overview", "Gateway", "Accounts", "Configuration", "Operations"]
        )
    }

    func testShellStringsExistInBothLanguages() {
        for key in ["需要升级", "网关运行中 · %@", "检查更新…"] {
            XCTAssertNotEqual(OasesLocalization.localized(key, language: .english), key, key)
            XCTAssertEqual(OasesLocalization.localized(key, language: .simplifiedChinese), key, key)
        }
        XCTAssertEqual(OasesLocalization.localized("检查更新…", language: .english), "Check for Updates…")
    }
}
