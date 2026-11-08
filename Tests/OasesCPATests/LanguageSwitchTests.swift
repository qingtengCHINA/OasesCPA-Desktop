import AppKit
import Observation
import SwiftUI
import XCTest
@testable import OasesCPA

/// The in-app language switch: lookups follow the new language at once, SwiftUI bodies that
/// looked up a string depend on the language (Observation), stores translate the text they
/// hold, and every enum-backed title exists in both languages.
@MainActor
final class LanguageSwitchTests: XCTestCase {
    private var savedLanguage: String?

    override func setUp() async throws {
        savedLanguage = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
    }

    override func tearDown() async throws {
        if let savedLanguage {
            UserDefaults.standard.set(savedLanguage, forKey: AppLanguage.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey)
        }
        OasesLanguageObserver.shared.synchronize()
    }

    // MARK: - The stale-string mechanism

    func testSameAccessorReturnsTheNewLanguageAfterASwitch() {
        OasesLocalization.setPreferredLanguage(.simplifiedChinese)
        XCTAssertEqual(AppSection.authFiles.title, "认证文件")
        XCTAssertEqual(SectionGroup.accounts.title, "账号")
        XCTAssertEqual(OasesAppearance.dark.title, "深色")

        OasesLocalization.setPreferredLanguage(.english)
        XCTAssertEqual(AppSection.authFiles.title, "Auth Files")
        XCTAssertEqual(SectionGroup.accounts.title, "Accounts")
        XCTAssertEqual(OasesAppearance.dark.title, "Dark")
        XCTAssertEqual(AppStore().connectionLabel, OasesLocalization.localized("未连接", language: .english))

        OasesLocalization.setPreferredLanguage(.simplifiedChinese)
        XCTAssertEqual(AppSection.authFiles.title, "认证文件")
    }

    /// A SwiftUI body that called `OasesLocalization.localized` is invalidated by a language
    /// change made the way the Settings picker makes it (`@AppStorage` writes `UserDefaults`).
    func testLookupMakesTheCallerDependOnTheLanguage() {
        OasesLocalization.setPreferredLanguage(.simplifiedChinese)
        let changes = ChangeCounter()
        withObservationTracking {
            _ = AppSection.dashboard.title
        } onChange: {
            changes.increment()
        }

        UserDefaults.standard.set("x", forKey: "oasesCPA.test.unrelatedKey")
        UserDefaults.standard.removeObject(forKey: "oasesCPA.test.unrelatedKey")
        XCTAssertEqual(changes.value, 0, "an unrelated defaults change does not invalidate")

        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: AppLanguage.defaultsKey)
        XCTAssertEqual(changes.value, 1, "the language change invalidates the dependent body")
        XCTAssertEqual(AppSection.dashboard.title, "Dashboard")
    }

    func testStoresTranslateTheTextTheyHoldAfterASwitch() {
        OasesLocalization.setPreferredLanguage(.simplifiedChinese)
        let store = DeploymentStore(autoProbe: false)
        store.statusMessage = OasesLocalization.localizedFormat("已切换到 %@，可重新检测环境", "VPS A")
        let chineseSteps = store.steps.map(\.title)
        XCTAssertFalse(chineseSteps.isEmpty)

        OasesLocalization.setPreferredLanguage(.english)
        // The stores listen on the main queue.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(
            store.statusMessage,
            OasesLocalization.localizedFormat("已切换到 %@，可重新检测环境", language: .english, "VPS A")
        )
        XCTAssertEqual(store.steps.map(\.title), DeploymentPlanFactory.makeSteps(target: store.targetKind, method: store.deploymentMethod).map(\.title))
        XCTAssertNotEqual(store.steps.map(\.title), chineseSteps)
        XCTAssertFalse(store.steps.map(\.title).joined().containsHan, "\(store.steps.map(\.title))")
    }

    func testRelocalizedTranslatesHeldTextAndLeavesOtherTextAlone() {
        XCTAssertEqual(OasesLocalization.relocalized("认证文件", to: .english), "Auth Files")
        XCTAssertEqual(OasesLocalization.relocalized("Auth Files", to: .simplifiedChinese), "认证文件")
        XCTAssertEqual(OasesLocalization.relocalized("Auth Files", to: .english), "Auth Files")
        let chinese = OasesLocalization.localizedFormat("已切换到 %@，可重新检测环境", language: .simplifiedChinese, "VPS A")
        let english = OasesLocalization.localizedFormat("已切换到 %@，可重新检测环境", language: .english, "VPS A")
        XCTAssertEqual(OasesLocalization.relocalized(chinese, to: .english), english)
        XCTAssertEqual(OasesLocalization.relocalized(english, to: .simplifiedChinese), chinese)
        // Raw server text and user data stay as they are.
        XCTAssertEqual(OasesLocalization.relocalized("dial tcp 127.0.0.1: connection refused", to: .english), "dial tcp 127.0.0.1: connection refused")
        XCTAssertEqual(OasesLocalization.relocalized("my-vps", to: .simplifiedChinese), "my-vps")
    }

    func testFollowSystemResolvesToALanguageTheAppHas() {
        XCTAssertEqual(AppLanguage.systemLanguage(preferredLanguages: ["en-US", "zh-Hans-CN"]), .english)
        XCTAssertEqual(AppLanguage.systemLanguage(preferredLanguages: ["zh-Hant-TW", "en-US"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.systemLanguage(preferredLanguages: ["ja-JP", "zh-Hans-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.systemLanguage(preferredLanguages: ["ja-JP"]), .english)
        XCTAssertEqual(AppLanguage.english.resolved, .english)
        XCTAssertNotEqual(AppLanguage.system.resolved, .system)
        // The SwiftUI locale of "Follow System" carries the same language as the lookups.
        XCTAssertEqual(AppLanguage.system.locale.language.languageCode, Locale(identifier: AppLanguage.system.resolved.rawValue).language.languageCode)
    }

    // MARK: - Enum-backed titles in both languages

    func testEnumBackedTitlesExistInBothLanguages() {
        var rows: [(String, String, String)] = []
        func collect<T: CaseIterable>(_ type: T.Type, _ name: String, _ text: (T) -> String) {
            for value in T.allCases {
                OasesLocalization.setPreferredLanguage(.simplifiedChinese)
                let chinese = text(value)
                OasesLocalization.setPreferredLanguage(.english)
                let english = text(value)
                rows.append(("\(name).\(value)", chinese, english))
            }
        }
        collect(AppSection.self, "AppSection.title") { $0.title }
        collect(AppSection.self, "AppSection.subtitle") { $0.subtitle }
        collect(SectionGroup.self, "SectionGroup.title") { $0.title }
        collect(OasesAppearance.self, "OasesAppearance.title") { $0.title }
        collect(AuthFilesWorkbenchSort.self, "AuthFilesWorkbenchSort.title") { $0.title }
        collect(AuthFilesWorkbenchDisplayMode.self, "AuthFilesWorkbenchDisplayMode.title") { $0.title }
        collect(AuthFilesWorkbenchAttentionFilter.self, "AuthFilesWorkbenchAttentionFilter.title") { $0.title }
        collect(DeploymentTargetKind.self, "DeploymentTargetKind.title") { $0.title }
        collect(DeploymentMethod.self, "DeploymentMethod.title") { $0.title }
        collect(RuntimeDashboardRange.self, "RuntimeDashboardRange.title") { $0.title }
        collect(RuntimeUsageAnalyticsGranularity.self, "RuntimeUsageAnalyticsGranularity.title") { $0.title }
        collect(RuntimeUsageAnalyticsCacheStatus.self, "RuntimeUsageAnalyticsCacheStatus.title") { $0.title }
        collect(RuntimeAccountActionStatusFilter.self, "RuntimeAccountActionStatusFilter.title") { $0.title }
        collect(RuntimeOAuthProvider.self, "RuntimeOAuthProvider.title") { $0.title }
        collect(RuntimeCPAQuickConfigField.self, "RuntimeCPAQuickConfigField.title") { $0.title }
        collect(RuntimeCPAQuickConfigField.self, "RuntimeCPAQuickConfigField.explanation") { $0.explanation }
        collect(RuntimeCPAQuickConfigGroup.self, "RuntimeCPAQuickConfigGroup.title") { $0.title }
        collect(RuntimeCPAQuickConfigGroup.self, "RuntimeCPAQuickConfigGroup.explanation") { $0.explanation }
        collect(RuntimeUsageAnalyticsTab.self, "RuntimeUsageAnalyticsTab.title") { $0.title }
        collect(RuntimeUsageAnalyticsStatusFilter.self, "RuntimeUsageAnalyticsStatusFilter.title") { $0.title }
        collect(RuntimeAccountActionOperation.self, "RuntimeAccountActionOperation.title") { $0.title }
        collect(AppLanguage.self, "AppLanguage.displayTitle") { $0.displayTitle(in: OasesLocalization.preferredLanguage) }

        XCTAssertGreaterThan(rows.count, 100)
        for (name, chinese, english) in rows {
            XCTAssertFalse(english.containsHan, "\(name): English shows Chinese: \(english)")
            XCTAssertFalse(english.isEmpty, "\(name)")
            if chinese.containsHan {
                XCTAssertNotEqual(chinese, english, "\(name)")
            }
        }
        // The navigation titles are Title Case in English.
        for section in AppSection.allCases {
            OasesLocalization.setPreferredLanguage(.english)
            let words = section.title.split(separator: " ").filter { $0.count > 3 }
            XCTAssertTrue(words.allSatisfy { $0.first?.isUppercase == true }, "\(section): \(section.title)")
        }
    }

    /// Window and menu titles built in `OasesCPAApp` (`title("…")`) are looked up in the
    /// in-app language, so both tables must hold them.
    func testAppWindowAndMenuTitlesAreTranslated() throws {
        let chinese = try strings("zh-Hans")
        let english = try strings("en")
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OasesCPA/App/OasesCPAApp.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let call = try NSRegularExpression(pattern: #"\btitle\("((?:[^"\\]|\\.)*)"\)"#)
        let keys = call.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
        XCTAssertGreaterThanOrEqual(keys.count, 12)
        for key in keys {
            XCTAssertNotNil(chinese[key], "zh-Hans lacks \(key)")
            let value = try XCTUnwrap(english[key], "en lacks \(key)")
            XCTAssertFalse(value.containsHan, "\(key) → \(value)")
        }
        // No scene or menu title is left to the macOS language.
        let literalTitle = try NSRegularExpression(pattern: #"\b(?:Window|CommandMenu|Settings)\(\s*"\p{Han}"#)
        XCTAssertNil(literalTitle.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)))
    }

    private func strings(_ language: String) throws -> [String: String] {
        let bundle = OasesLocalization.bundle(for: language == "en" ? .english : .simplifiedChinese)
        let path = try XCTUnwrap(bundle.path(forResource: "Localizable", ofType: "strings"))
        return try XCTUnwrap(NSDictionary(contentsOfFile: path) as? [String: String])
    }
}

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

extension String {
    var containsHan: Bool {
        unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }
}
