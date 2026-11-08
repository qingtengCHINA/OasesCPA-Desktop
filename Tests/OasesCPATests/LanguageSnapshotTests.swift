import AppKit
import SwiftUI
import XCTest
@testable import OasesCPA

/// Offscreen renders of the main window, the Settings form and the auth-file toolbar in both
/// languages, including a live switch on the same hosting view (no new view identity).
/// Opt-in: runs only when `OASES_SNAPSHOT_DIR` names a directory for the PNG files; the
/// views are hosted in an `NSWindow` that is never ordered front.
///
/// Limitation: under `swift test` SwiftUI resolves `Text("…")` literals (`LocalizedStringKey`)
/// through the test runner's main bundle, which has no string tables, so those literals show
/// their Chinese source text in every render. In the app they follow the `\.locale`
/// environment. Everything built from `OasesLocalization` (the stale-string defect) renders
/// in the selected language and is what these snapshots check.
@MainActor
final class LanguageSnapshotTests: XCTestCase {
    private var savedLanguage: String?
    private var outputDirectory: URL!

    override func setUp() async throws {
        guard let directory = ProcessInfo.processInfo.environment["OASES_SNAPSHOT_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set OASES_SNAPSHOT_DIR to render the language snapshots.")
        }
        outputDirectory = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
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

    func testMainWindowSwitchesLanguageInPlace() throws {
        OasesLocalization.setPreferredLanguage(.simplifiedChinese)
        let store = AppStore()
        store.selectSection(.system)
        let deploymentStore = DeploymentStore(autoProbe: false)
        let runtimeDataStore = RuntimeDataStore()
        let root = SnapshotLanguageRoot {
            ContentView()
                .environmentObject(store)
                .environmentObject(deploymentStore)
                .environmentObject(runtimeDataStore)
                .environmentObject(AppUpdateService())
        }
        let host = makeHost(root, size: NSSize(width: 1_180, height: 760))
        try render(host, name: "main-system-zh")

        // The switch the Settings picker makes; same hosting view, same view identity.
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: AppLanguage.defaultsKey)
        settle()
        try render(host, name: "main-system-en-live")

        for section in [AppSection.authFiles, .aiProviders, .dashboard, .accessKeys] {
            store.selectSection(section)
            settle()
            try render(host, name: "main-\(section.rawValue)-en")
        }

        UserDefaults.standard.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.defaultsKey)
        settle()
        try render(host, name: "main-accessKeys-zh-live")
    }

    func testSettingsFormSwitchesLanguageInPlace() throws {
        OasesLocalization.setPreferredLanguage(.english)
        let root = SnapshotLanguageRoot {
            SettingsView()
                .environmentObject(AppStore())
                .environmentObject(DeploymentStore(autoProbe: false))
                .environmentObject(RuntimeDataStore())
                .environmentObject(AppUpdateService())
        }
        let host = makeHost(root, size: NSSize(width: 640, height: 1_500))
        try render(host, name: "settings-en")
        UserDefaults.standard.set(AppLanguage.simplifiedChinese.rawValue, forKey: AppLanguage.defaultsKey)
        settle()
        try render(host, name: "settings-zh-live")
    }

    func testAuthFileToolbarKeepsItsLabelsInBothLanguages() throws {
        for language in [AppLanguage.english, .simplifiedChinese] {
            OasesLocalization.setPreferredLanguage(language)
            let workbench = AuthFilesWorkbenchStore()
            let root = SnapshotLanguageRoot {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        TextField("搜索名称、Provider、邮箱、项目或备注", text: .constant(""))
                            .textFieldStyle(.roundedBorder)
                        AuthFilesWorkbenchFilterPickers(workbench: workbench)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("搜索名称、Provider、邮箱、项目或备注", text: .constant(""))
                            .textFieldStyle(.roundedBorder)
                        AuthFilesWorkbenchFilterPickers(workbench: workbench)
                    }
                }
                .padding(16)
                .frame(width: 760, alignment: .leading)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            let host = makeHost(root, size: NSSize(width: 760, height: 140))
            try render(host, name: "authfiles-toolbar-\(language.rawValue)")
            // The pickers keep their ideal width: their labels are never squeezed.
            let pickers = NSHostingView(rootView: AuthFilesWorkbenchFilterPickers(workbench: workbench).environment(\.locale, language.locale))
            XCTAssertGreaterThan(pickers.fittingSize.width, 200, "\(language)")
        }
    }

    // MARK: - Helpers

    private func makeHost<V: View>(_ view: V, size: NSSize) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        // Never ordered front: the window only provides a backing store for the render.
        settle()
        return host
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    }

    private func render<V: View>(_ host: NSHostingView<V>, name: String) throws {
        host.layoutSubtreeIfNeeded()
        let bounds = host.bounds
        let representation = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: bounds))
        host.cacheDisplay(in: bounds, to: representation)
        let data = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }
}

/// What the app's scenes do: the SwiftUI locale follows the stored language.
private struct SnapshotLanguageRoot<Content: View>: View {
    @AppStorage(AppLanguage.defaultsKey) private var languageRaw = AppLanguage.system.rawValue
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .environment(\.locale, (AppLanguage(rawValue: languageRaw) ?? .system).locale)
    }
}
