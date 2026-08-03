import AppKit
import XCTest
@testable import OasesCPA

@MainActor
final class AppExperienceTests: XCTestCase {
    func testAppStartsOnDashboard() {
        XCTAssertEqual(AppStore().selectedSection, .dashboard)
    }

    func testLanguageOptionsExposeStableValues() {
        XCTAssertEqual(
            AppLanguage.allCases.map(\.rawValue),
            ["system", "zh-Hans", "en"]
        )
        XCTAssertEqual(AppLanguage.defaultsKey, "oasesCPA.appLanguage")
    }

    func testEnglishResourceCanTranslateCoreNavigation() {
        XCTAssertEqual(
            OasesLocalization.localized("仪表盘", language: .english),
            "Dashboard"
        )
    }

    func testEnglishResourceCoversNativeCPAMPWorkbenches() {
        let expected = [
            "认证文件": "Auth Files",
            "用量热力图": "Usage Heatmap",
            "CLIProxyAPI 快速配置": "CLIProxyAPI Quick Configuration",
            "当前网关模型目录": "Current Gateway Model Directory",
            "舍弃未保存的 Provider 配置？": "Discard unsaved provider configuration?"
        ]

        for (source, translation) in expected {
            XCTAssertEqual(
                OasesLocalization.localized(source, language: .english),
                translation
            )
        }
    }

    func testAppVersionInfoUsesBundleMarketingVersionAndBuild() {
        let version = AppVersionInfo(
            infoDictionary: [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "45"
            ]
        )

        XCTAssertEqual(version.marketingVersion, "1.2.3")
        XCTAssertEqual(version.displayText, "Oases CPA 1.2.3 (45)")
    }

    func testApplicationTerminationRunsRegisteredCleanup() {
        let delegate = AppDelegate()
        var cleanupCount = 0
        delegate.installTerminationHandler {
            cleanupCount += 1
        }

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        XCTAssertEqual(cleanupCount, 1)
    }

    func testTunnelProcessOwnerStopsRunningChild() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        XCTAssertTrue(process.isRunning)

        let owner = TunnelProcessOwner()
        owner.attach(process)
        owner.stop()

        XCTAssertFalse(process.isRunning)
    }
}
