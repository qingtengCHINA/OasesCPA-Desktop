import Foundation
import XCTest
@testable import OasesCPA

/// The embedded CPA Manager Plus web panel is gone: every capability it offered has a native
/// page (or was dropped on purpose), and nothing in the app links to, loads or names it.
final class PanelRemovalTests: XCTestCase {
    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testPanelSectionIsGoneAndEverySectionBelongsToAGroup() {
        XCTAssertNil(AppSection(rawValue: "panel"))
        for section in AppSection.allCases {
            let groups = SectionGroup.allCases.filter { $0.sections.contains(section) }
            XCTAssertEqual(groups.count, 1, "\(section) is in exactly one sidebar group")
        }
        XCTAssertEqual(
            SectionGroup.allCases.flatMap(\.sections).count,
            AppSection.allCases.count,
            "no section is listed twice"
        )
    }

    func testNoSourceImportsWebKit() throws {
        let sources = repositoryRoot.appendingPathComponent("Sources/OasesCPA")
        let forbidden = [
            "import WebKit", "WKWebView", "management.html", "PanelView", "EmbeddedPanel",
            "localPanelURL", "openPanel(", "selectSection(.panel)", "case .panel", "case panel",
            "GenericWorkspaceView"
        ]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for term in forbidden {
                XCTAssertFalse(text.contains(term), "\(file.lastPathComponent) contains \(term)")
            }
            // `Oases.Radius.panel` is a design token and unrelated; no other `.panel` remains.
            let withoutToken = text.replacingOccurrences(of: "Radius.panel", with: "")
            XCTAssertNil(withoutToken.range(of: #"\.panel\b"#, options: .regularExpression), "\(file.lastPathComponent) refers to .panel")
            scanned += 1
        }
        XCTAssertGreaterThan(scanned, 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sources.appendingPathComponent("Views/PanelView.swift").path))
        // The app does not link WebKit either.
        for manifest in ["project.yml", "Package.swift"] {
            let text = try String(contentsOf: repositoryRoot.appendingPathComponent(manifest), encoding: .utf8)
            XCTAssertFalse(text.contains("WebKit"), manifest)
        }
    }

    func testNoLocalizationKeyMentionsTheWebPanel() throws {
        let chineseTerms = ["CPAMP 面板", "高级面板", "完整面板", "打开 CPAMP", "网页面板", "浏览器面板", "浏览器打开", "管理面板"]
        let englishTerms = ["cpamp panel", "web panel", "advanced panel", "open cpamp", "embedded panel", "browser panel"]
        for language in ["zh-Hans", "en"] {
            let url = try XCTUnwrap(
                Self.resourceBundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language)
                    ?? Self.resourceBundle.path(forResource: language, ofType: "lproj")
                        .map { URL(fileURLWithPath: $0).appendingPathComponent("Localizable.strings") }
            )
            let strings = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
            for (key, value) in strings {
                for term in chineseTerms {
                    XCTAssertFalse(key.contains(term), "\(language) key: \(key)")
                    XCTAssertFalse(value.contains(term), "\(language) value: \(value)")
                }
                for term in englishTerms {
                    XCTAssertFalse(value.lowercased().contains(term), "\(language) value: \(value)")
                }
            }
        }
    }

    func testReadmeNamesTheFourLoopbackPortsAndNoWebPanel() throws {
        let readme = try String(contentsOf: repositoryRoot.appendingPathComponent("README.md"), encoding: .utf8)
        for term in ["CPAMP 面板", "高级网页面板", "management.html"] {
            XCTAssertFalse(readme.contains(term), term)
        }
        XCTAssertFalse(readme.contains("管理端口 `8317` / `18317`"), "the old two-port line")
        for port in ["`8317`", "`18320`", "`18316`", "`18317`"] {
            XCTAssertTrue(readme.contains(port), port)
        }
    }
}
