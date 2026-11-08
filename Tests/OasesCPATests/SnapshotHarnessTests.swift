import AppKit
import SwiftUI
import XCTest
@testable import OasesCPA

/// Proves which kinds of views the offscreen harness renders faithfully (sidebar list, grouped
/// Form, Table, toolbar-like row, literal and `OasesLocalization` text in both languages).
/// Opt-in: skipped unless `OASES_SNAPSHOT_DIR` is set.
@MainActor
final class SnapshotHarnessTests: XCTestCase {
    private var savedLanguage: String?
    private var directory: URL!

    override func setUp() async throws {
        directory = try SnapshotSupport.outputDirectory("harness")
        savedLanguage = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
    }

    override func tearDown() async throws {
        // A skipped test (no OASES_SNAPSHOT_DIR) changed nothing: leave the language alone.
        guard directory != nil else { return }
        SnapshotSupport.reset(savedLanguage: savedLanguage)
    }

    func testControlKindsRenderInBothLanguagesAndAppearances() throws {
        for language in SnapshotSupport.languages {
            for appearance in SnapshotSupport.Appearance.allCases {
                try SnapshotSupport.render(
                    HarnessProbeView(),
                    size: CGSize(width: 900, height: 560),
                    appearance: appearance,
                    language: language,
                    name: "probe-\(language.rawValue)-\(appearance.rawValue)",
                    directory: directory
                )
            }
        }
    }

    func testMainWindowWithToolbarRenders() throws {
        let fixture = SnapshotFixture(section: .system)
        try SnapshotSupport.render(
            ContentView().snapshotEnvironment(fixture),
            size: CGSize(width: 1_180, height: 760),
            language: .english,
            chrome: true,
            name: "probe-window-en-light",
            directory: directory
        )
    }

    func testLiteralTextResolvesThroughTheLocaleWhileInstalled() throws {
        LocalizedMainBundle.install()
        defer { LocalizedMainBundle.uninstall() }
        let english = Bundle.main.localizedString(forKey: "刷新", value: nil, table: "Localizable")
        XCTAssertNotNil(Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en"))
        XCTAssertFalse(english.isEmpty)
    }
}

private struct HarnessProbeView: View {
    @State private var selection: AppSection? = .dashboard
    @State private var toggle = true
    @State private var picker = 0
    @State private var text = "http://127.0.0.1:8317/v1"

    private struct Row: Identifiable {
        let id: Int
        let name: String
        let provider: String
        let status: String
    }

    private let rows = [
        Row(id: 1, name: "codex-main.json", provider: "Codex", status: "正常"),
        Row(id: 2, name: "claude-team.json", provider: "Claude", status: "需处理"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section(SectionGroup.overview.title) {
                    Label(AppSection.dashboard.title, systemImage: AppSection.dashboard.systemImage)
                        .tag(AppSection.dashboard)
                    Label(AppSection.monitoring.title, systemImage: AppSection.monitoring.systemImage)
                        .tag(AppSection.monitoring)
                }
                Section(SectionGroup.accounts.title) {
                    Label(AppSection.accountActions.title, systemImage: AppSection.accountActions.systemImage)
                        .badge(3)
                        .tag(AppSection.accountActions)
                }
            }
            .listStyle(.sidebar)
            .frame(width: 220)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("刷新")
                    Text(verbatim: OasesLocalization.localized("认证文件"))
                    Picker("显示", selection: $picker) {
                        Text("卡片").tag(0)
                        Text("紧凑").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    Spacer()
                    Button("刷新") {}
                    Button("保存") {}.buttonStyle(.borderedProminent)
                }
                Form {
                    Section("外观") {
                        Toggle("登录时打开", isOn: $toggle)
                        TextField("接入地址", text: $text)
                        Picker("颜色模式", selection: $picker) {
                            Text("跟随系统").tag(0)
                            Text("浅色").tag(1)
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(height: 200)

                Table(rows) {
                    TableColumn("名称", value: \.name)
                    TableColumn("提供商", value: \.provider)
                    TableColumn("状态") { row in
                        HStack(spacing: 6) {
                            StatusDot(tone: row.id == 1 ? .success : .warning)
                            Text(LocalizedStringKey(row.status))
                        }
                    }
                }
                .frame(height: 120)
            }
            .padding(20)
        }
    }
}
