import AppKit
import SwiftUI
import XCTest
@testable import OasesCPA

/// Offscreen renders of the main window, the Settings form and the auth-file toolbar in both
/// languages, including a live switch on the same hosting view (no new view identity).
/// Opt-in: runs only when `OASES_SNAPSHOT_DIR` names a directory for the PNG files; rendering
/// goes through `SnapshotSupport` (a window that is never ordered front). While it renders,
/// `Bundle.main` resolves to the app's string tables, so `Text("…")` literals follow the
/// `\.locale` environment as in the app.
@MainActor
final class LanguageSnapshotTests: XCTestCase {
    private var savedLanguage: String?
    private var outputDirectory: URL!

    override func setUp() async throws {
        outputDirectory = try SnapshotSupport.outputDirectory("language")
        savedLanguage = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
    }

    override func tearDown() async throws {
        // A skipped test (no OASES_SNAPSHOT_DIR) changed nothing: leave the language alone.
        guard outputDirectory != nil else { return }
        SnapshotSupport.reset(savedLanguage: savedLanguage)
    }

    func testMainWindowSwitchesLanguageInPlace() throws {
        let fixture = SnapshotFixture(section: .system)
        let session = try SnapshotSupport.begin(
            ContentView().snapshotEnvironment(fixture),
            size: CGSize(width: 1_180, height: 760),
            language: .simplifiedChinese,
            chrome: true
        )
        defer { session.close() }
        try session.write(name: "main-system-zh", to: outputDirectory)

        // The switch the Settings picker makes; same hosting view, same view identity.
        SnapshotSupport.setLanguage(.english)
        SnapshotSupport.settle()
        try session.write(name: "main-system-en-live", to: outputDirectory)

        for section in [AppSection.authFiles, .aiProviders, .dashboard, .accessKeys] {
            fixture.store.selectSection(section)
            SnapshotSupport.settle()
            try session.write(name: "main-\(section.rawValue)-en", to: outputDirectory)
        }

        SnapshotSupport.setLanguage(.simplifiedChinese)
        SnapshotSupport.settle()
        try session.write(name: "main-accessKeys-zh-live", to: outputDirectory)
    }

    func testSettingsFormSwitchesLanguageInPlace() throws {
        let fixture = SnapshotFixture()
        let session = try SnapshotSupport.begin(
            SettingsView().snapshotEnvironment(fixture),
            size: CGSize(width: 640, height: 1_500),
            language: .english
        )
        defer { session.close() }
        try session.write(name: "settings-en", to: outputDirectory)
        SnapshotSupport.setLanguage(.simplifiedChinese)
        SnapshotSupport.settle()
        try session.write(name: "settings-zh-live", to: outputDirectory)
    }

    func testAuthFileToolbarKeepsItsLabelsInBothLanguages() throws {
        for language in [AppLanguage.english, .simplifiedChinese] {
            let workbench = AuthFilesWorkbenchStore()
            let toolbar = ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    TextField("搜索名称、Provider、邮箱、项目或备注", text: .constant(""))
                        .textFieldStyle(.roundedBorder)
                    AuthFilesFilterBar(workbench: workbench)
                }
                VStack(alignment: .leading, spacing: 10) {
                    TextField("搜索名称、Provider、邮箱、项目或备注", text: .constant(""))
                        .textFieldStyle(.roundedBorder)
                    AuthFilesFilterBar(workbench: workbench)
                }
            }
            .padding(16)
            .frame(width: 760, alignment: .leading)
            try SnapshotSupport.render(
                toolbar,
                size: CGSize(width: 760, height: 140),
                language: language,
                name: "authfiles-toolbar-\(language.rawValue)",
                directory: outputDirectory
            )
            // The pickers keep their ideal width: their labels are never squeezed.
            let pickers = NSHostingView(rootView: AuthFilesFilterBar(workbench: workbench).environment(\.locale, language.locale))
            XCTAssertGreaterThan(pickers.fittingSize.width, 200, "\(language)")
        }
    }
}
