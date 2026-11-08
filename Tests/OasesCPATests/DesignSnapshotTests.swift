import AppKit
import SwiftUI
import XCTest
@testable import OasesCPA

/// Offscreen renders of the design foundation: the shared components (gallery), the window
/// shell and representative pages, each in zh-Hans / en and light / dark.
/// Opt-in: skipped unless `OASES_SNAPSHOT_DIR` is set (see `script/snapshot.sh`).
@MainActor
final class DesignSnapshotTests: XCTestCase {
    private var savedLanguage: String?
    private var directory: URL!

    /// The pages rendered through the compatibility layer, in the main window with its toolbar.
    static let pages: [AppSection] = [.dashboard, .authFiles, .system, .environments]
    static let windowSize = CGSize(width: 1_180, height: 760)

    override func setUp() async throws {
        directory = try SnapshotSupport.outputDirectory("design")
        savedLanguage = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
    }

    override func tearDown() async throws {
        // A skipped test (no OASES_SNAPSHOT_DIR) changed nothing: leave the language alone.
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

    func testGallery() throws {
        try eachVariant { language, appearance in
            let fixture = SnapshotFixture()
            try SnapshotSupport.render(
                FoundationGalleryView().snapshotEnvironment(fixture),
                size: CGSize(width: 960, height: 1_240),
                appearance: appearance,
                language: language,
                name: "gallery-\(language.rawValue)-\(appearance.rawValue)",
                directory: directory
            )
        }
    }

    /// The main window (sidebar, toolbar title and subtitle) on each representative page. The
    /// fixture is offline and idle, so pages show their not-connected states.
    func testPagesInTheWindow() throws {
        try eachVariant { language, appearance in
            for section in Self.pages {
                let fixture = SnapshotFixture(section: section)
                try SnapshotSupport.render(
                    ContentView().snapshotEnvironment(fixture),
                    size: Self.windowSize,
                    appearance: appearance,
                    language: language,
                    chrome: true,
                    name: "page-\(section.rawValue)-\(language.rawValue)-\(appearance.rawValue)",
                    directory: directory
                )
            }
        }
    }

    /// One page on request, for `script/snapshot.sh <page> <language> <appearance>`:
    /// `OASES_SNAPSHOT_PAGE` is an `AppSection` raw value (the page in the main window), or
    /// `gallery`, `sidebar` or `settings`; `OASES_SNAPSHOT_LANGUAGE` is `zh-Hans`, `en` or `all`;
    /// `OASES_SNAPSHOT_APPEARANCE` is `light`, `dark` or `all`. Skipped when no page is named.
    func testRequestedPage() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let page = environment["OASES_SNAPSHOT_PAGE"], !page.isEmpty else {
            throw XCTSkip("Set OASES_SNAPSHOT_PAGE (script/snapshot.sh) to render one page.")
        }
        let languages: [AppLanguage] = switch environment["OASES_SNAPSHOT_LANGUAGE"] ?? "all" {
        case "all": SnapshotSupport.languages
        case let raw: [try XCTUnwrap(AppLanguage(rawValue: raw), "language \(raw)")]
        }
        let appearances: [SnapshotSupport.Appearance] = switch environment["OASES_SNAPSHOT_APPEARANCE"] ?? "all" {
        case "all": SnapshotSupport.Appearance.allCases
        case let raw: [try XCTUnwrap(SnapshotSupport.Appearance(rawValue: raw), "appearance \(raw)")]
        }
        let section = AppSection(rawValue: page)
        guard section != nil || ["gallery", "sidebar", "settings"].contains(page) else {
            let pages = (["gallery", "sidebar", "settings"] + AppSection.allCases.map(\.rawValue)).joined(separator: ", ")
            XCTFail("Unknown page \(page). Pages: \(pages)")
            return
        }
        for language in languages {
            for appearance in appearances {
                let name = "\(page)-\(language.rawValue)-\(appearance.rawValue)"
                let fixture = SnapshotFixture(section: section ?? .models)
                switch page {
                case "gallery":
                    try SnapshotSupport.render(FoundationGalleryView().snapshotEnvironment(fixture), size: CGSize(width: 960, height: 1_240), appearance: appearance, language: language, name: name, directory: directory)
                case "sidebar":
                    try SnapshotSupport.render(SidebarView().snapshotEnvironment(fixture), size: CGSize(width: 240, height: 900), appearance: appearance, language: language, name: name, directory: directory)
                case "settings":
                    try SnapshotSupport.render(SettingsView().snapshotEnvironment(fixture), size: CGSize(width: 640, height: 1_500), appearance: appearance, language: language, name: name, directory: directory)
                default:
                    try SnapshotSupport.render(ContentView().snapshotEnvironment(fixture), size: Self.windowSize, appearance: appearance, language: language, chrome: true, name: name, directory: directory)
                }
            }
        }
    }

    /// The whole sidebar at the minimum window height, every group visible.
    func testSidebar() throws {
        try eachVariant { language, appearance in
            let fixture = SnapshotFixture(section: .models)
            try SnapshotSupport.render(
                SidebarView().snapshotEnvironment(fixture),
                size: CGSize(width: 240, height: 900),
                appearance: appearance,
                language: language,
                name: "sidebar-\(language.rawValue)-\(appearance.rawValue)",
                directory: directory
            )
        }
    }
}

/// Every shared component the pages use, as the call sites use them (including a card nested
/// in a card), so the compatibility layer can be judged in one picture.
private struct FoundationGalleryView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                CardTitle(title: "快捷链接", subtitle: "打开项目仓库和官方文档，获取帮助与更新", icon: "link")
                Text("先连接目标环境")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("CLIProxyAPI").font(.headline)
                    Text("核心网关项目").foregroundStyle(.secondary)
                }
                .padding(14)
                .oasesCard()
            }
            .padding(20)
            .oasesCard()

            VStack(alignment: .leading, spacing: 10) {
                InfoBanner(title: "先连接目标环境", message: "连接成功后，这里会显示 CPAMP 服务、采集器、事件与数据迁移状态。", systemImage: "link.badge.plus", tint: .oasesBlue)
                InfoBanner(title: "需要处理", message: "上次部署存在，但当前服务未能自动恢复", systemImage: "exclamationmark.triangle.fill", tint: .oasesOrange)
                InfoBanner(title: "部署失败", message: "目标目录没有可信的 Oases CPA 受管标记", systemImage: "xmark.octagon.fill", tint: .oasesRed)
            }

            HStack(spacing: 12) {
                StatusPill(title: "已接入", tint: .oasesGreen)
                StatusPill(title: "连接后读取", tint: .oasesOrange, systemImage: "link.badge.plus")
                StatusPill(title: "需要处理", tint: .oasesRed)
                ToneBadge(text: "正常", tone: .success)
                ToneBadge(text: "停用", tone: .neutral)
                ToneBadge(text: "失败", tone: .danger)
                HStack(spacing: 6) {
                    StatusDot(tone: .success)
                    Text("运行中")
                }
            }

            HStack(spacing: 12) {
                MetricCard(metric: MetricSummary(title: "请求数", value: "1,284", caption: "最近 24 小时", systemImage: "arrow.left.arrow.right", tint: .oasesBlue))
                MetricCard(metric: MetricSummary(title: "成功率", value: "99.2%", caption: "最近 24 小时", systemImage: "checkmark.seal", tint: .oasesGreen))
                MetricCard(metric: MetricSummary(title: "认证文件", value: "12", caption: "3 个需处理", systemImage: "doc.badge.gearshape", tint: .oasesPurple))
            }

            HStack(spacing: 10) {
                Button("安装并启动") {}.buttonStyle(.oasesPrimary)
                Button("刷新") {}.buttonStyle(.bordered)
                Button("查看日志") {}.buttonStyle(.borderless)
                Image(systemName: "cpu")
                    .frame(width: 30, height: 30)
                    .oasesIconTile()
                OasesMonoValue(text: "http://127.0.0.1:8317/v1", copyValue: "http://127.0.0.1:8317/v1")
            }

            OasesSectionHeader(title: "系统信息", trailing: "12:04")
            OasesRowGroup {
                OasesValueRow(label: "接入地址", value: "http://127.0.0.1:8317/v1", mono: true)
                OasesValueRow(label: "状态", value: "运行中", tone: .success)
                OasesLinkRow(systemImage: "book", title: "使用文档", subtitle: "官方部署与使用文档", action: {})
            }

            OasesEmptyState(systemImage: "tray", title: "暂无数据", message: "连接后读取", actionTitle: "刷新", action: {})
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Offscreen renders of the reworked pages with sample data (the window fixture is offline, so
/// it only shows the not-connected states): tables, inspectors, sheets and the page states.
/// Opt-in like `DesignSnapshotTests`; `OASES_SNAPSHOT_ONLY=pages-keys` limits the names.
@MainActor
final class PageSnapshotTests: XCTestCase {
    private var savedLanguage: String?
    private var directory: URL!

    override func setUp() async throws {
        directory = try SnapshotSupport.outputDirectory("pages")
        savedLanguage = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey)
    }

    override func tearDown() async throws {
        guard directory != nil else { return }
        SnapshotSupport.reset(savedLanguage: savedLanguage)
    }

    /// Renders `make()` in both languages and appearances as `pages-<name>-<language>-<appearance>`.
    private func renderAll<V: View>(_ name: String, size: CGSize, chrome: Bool = false, _ make: () -> V) throws {
        for language in SnapshotSupport.languages {
            for appearance in SnapshotSupport.Appearance.allCases {
                try SnapshotSupport.render(
                    make(),
                    size: size,
                    appearance: appearance,
                    language: language,
                    chrome: chrome,
                    name: "pages-\(name)-\(language.rawValue)-\(appearance.rawValue)",
                    directory: directory
                )
            }
        }
    }

    /// Each reworked page in the window (not connected), with its toolbar.
    func testReworkedPagesInTheWindow() throws {
        for section in [AppSection.accessKeys, .models, .aiProviders, .authFiles, .system, .dashboard] {
            try renderAll("window-\(section.rawValue)", size: DesignSnapshotTests.windowSize, chrome: true) {
                ContentView().snapshotEnvironment(SnapshotFixture(section: section))
            }
        }
    }

    /// The page bodies alone (no window): on macOS 27 the window capture can leave the detail
    /// pane blank when the page adds toolbar items, so the body is judged here.
    func testReworkedPageBodies() throws {
        for section in [AppSection.accessKeys, .models, .aiProviders, .authFiles, .system, .dashboard] {
            try renderAll("body-\(section.rawValue)", size: CGSize(width: 950, height: 700)) {
                DetailWorkspaceView(section: section).snapshotEnvironment(SnapshotFixture(section: section))
            }
        }
    }

    /// Each Settings pane (the window's toolbar tabs are not part of the capture).
    func testSettingsPanes() throws {
        for pane in SettingsPane.allCases {
            try renderAll("settings-\(pane.rawValue)", size: CGSize(width: SettingsView.paneWidth, height: 440), chrome: true) {
                SettingsView(initialPane: pane).snapshotEnvironment(SnapshotFixture())
            }
        }
    }

    func testKeysPage() throws {
        let fixture = SnapshotFixture(section: .accessKeys)
        try renderAll("keys-loaded", size: CGSize(width: 980, height: 360)) {
            KeysSample(rows: SampleData.keys).snapshotEnvironment(fixture)
        }
        try renderAll("keys-legacy", size: CGSize(width: 980, height: 220)) {
            KeysSample(rows: [], availability: .needsUpgrade).snapshotEnvironment(fixture)
        }
        try renderAll("keys-empty", size: CGSize(width: 980, height: 340)) {
            KeysSample(rows: []).snapshotEnvironment(fixture)
        }
        try renderAll("keys-new-key-sheet", size: CGSize(width: 560, height: 380)) {
            GatewayNewKeySheet(key: SampleData.fullKey, baseURL: "http://127.0.0.1:8317/v1")
        }
    }

    func testProvidersPage() throws {
        let fixture = SnapshotFixture(section: .aiProviders)
        try renderAll("providers-loaded", size: CGSize(width: 1_040, height: 380)) {
            ProvidersSample().snapshotEnvironment(fixture)
        }
        try renderAll("providers-first", size: CGSize(width: 760, height: 360)) {
            FirstProviderForm()
                .padding(Oases.Space.page)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .snapshotEnvironment(fixture)
        }
    }

    func testAuthFilesPage() throws {
        try renderAll("authfiles-loaded", size: CGSize(width: 1_100, height: 380)) {
            AuthFilesSample()
        }
        try renderAll("authfiles-filterbar", size: CGSize(width: 640, height: 60)) {
            AuthFilesFilterBar(workbench: AuthFilesWorkbenchStore())
                .padding(Oases.Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func testModelsPage() throws {
        try renderAll("models-loaded", size: CGSize(width: 1_000, height: 380)) {
            ModelsSample()
        }
    }
}

/// Synthetic page data (no real keys, hosts or accounts).
@MainActor
private enum SampleData {
    static let fullKey = "oases-demo-" + String(repeating: "0", count: 24) + "4f1a"

    static var keys: [GatewayKeyRow] {
        var cursor = GatewayKeyPolicy.newKeyDefault
        cursor.label = "Cursor"
        var claude = GatewayKeyPolicy.newKeyDefault
        claude.label = "Claude Code"
        claude.enabled = false
        claude.allowedModels = ["gpt-5", "claude-sonnet-4", "deepseek-chat", "qwen3-coder"]
        claude.legacyDefaultAllow = false
        var ci = GatewayKeyPolicy.newKeyDefault
        ci.label = "CI"
        ci.expiresAt = Date(timeIntervalSince1970: 1_700_000_000)
        ci.rateLimit.requestsPerMinute = 60
        ci.rateLimit.tokensPerDay = 2_000_000
        return [
            GatewayKeyRow(key: "demo-cursor-0000000000009f2c", policy: cursor,
                          usage: GatewayKeyUsage(day: "2026-11-08", requests: 214, requestsLastMinute: 2, tokens: 1_284_000, tokensPerDay: nil, requestsPerMinute: nil)),
            GatewayKeyRow(key: "demo-claude-000000000000041aa", policy: claude, usage: nil),
            GatewayKeyRow(key: "demo-ci-00000000000000007c3d", policy: ci,
                          usage: GatewayKeyUsage(day: "2026-11-08", requests: 12, requestsLastMinute: 0, tokens: 8_400, tokensPerDay: 2_000_000, requestsPerMinute: 60)),
        ]
    }

    static var models: [GatewayModelRow] {
        let now = Date()
        return [
            GatewayModelRow(id: "claude-sonnet-4", groups: ["Claude"], health: GatewayHealthResult(status: .up, latencyMs: 812, error: nil, testedAt: now.addingTimeInterval(-180))),
            GatewayModelRow(id: "deepseek-chat", groups: ["DeepSeek", "OpenRouter"], health: GatewayHealthResult(status: .down, latencyMs: nil, error: "upstream returned 401", testedAt: now.addingTimeInterval(-3_600))),
            GatewayModelRow(id: "gpt-5", groups: ["Codex"], health: nil),
            GatewayModelRow(id: "text-embedding-3-large", groups: ["OpenRouter"], health: GatewayHealthResult(status: .skipped, latencyMs: nil, error: nil, testedAt: now.addingTimeInterval(-7_200))),
        ]
    }
}

/// The keys page body with sample rows (the page's own store needs a live gateway).
private struct KeysSample: View {
    let rows: [GatewayKeyRow]
    var availability: GatewayAvailability?
    @State private var selection: Set<GatewayKeyRow.ID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GatewayEndpointHero(baseURL: "http://127.0.0.1:8317/v1", targetKind: .local)
                .padding(Oases.Space.page)
            Divider()
            if let availability {
                GatewayUnavailableView(availability: availability) {}
                    .padding(Oases.Space.page)
                Spacer(minLength: 0)
            } else if rows.isEmpty {
                OasesEmptyState(
                    systemImage: "key.horizontal",
                    title: "还没有 API Key",
                    message: "客户端（Cursor、Claude Code 等）需要一个 Key 才能调用网关。",
                    actionTitle: "创建 Key",
                    action: {}
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GatewayKeysTable(rows: rows, selection: $selection)
            }
        }
        .onAppear { selection = [rows.first?.id].compactMap { $0 }.reduce(into: Set()) { $0.insert($1) } }
    }
}

private struct ProvidersSample: View {
    static let providers = [
        RuntimeOpenAICompatibility(name: "DeepSeek", prefix: "pin-ds", baseURL: "https://api.deepseek.com",
                                   apiKeyEntries: [RuntimeProviderAPIKey(apiKey: "demo-0000000000004f1a")],
                                   models: [RuntimeProviderModel(name: "deepseek-chat"), RuntimeProviderModel(name: "deepseek-reasoner")]),
        RuntimeOpenAICompatibility(name: "OpenRouter", prefix: "pin-or", baseURL: "https://openrouter.ai/api/v1",
                                   apiKeyEntries: [RuntimeProviderAPIKey(apiKey: "demo-0000000000009b2e"), RuntimeProviderAPIKey(apiKey: "demo-000000000000c3d4")]),
        RuntimeOpenAICompatibility(name: "Local Ollama", disabled: true, baseURL: "http://127.0.0.1:11434/v1"),
    ]
    @State private var selection: RuntimeOpenAICompatibility.ID? = ProvidersSample.providers[0].id

    var body: some View {
        DetailPaneSplit(showsPane: true, paneTitle: "提供商详情", onClose: {}) {
            ProvidersTable(providers: Self.providers, selection: $selection)
                .padding(Oases.Space.page)
        } pane: {
            ProviderInspector(provider: Self.providers[0])
        }
    }
}

private struct AuthFilesSample: View {
    static let files: [AuthFilesWorkbenchFile] = try! JSONDecoder().decode([AuthFilesWorkbenchFile].self, from: Data(#"""
    [{"name":"codex-main.json","provider":"codex","email":"main@example.com","plan":"plus","priority":10,"status":"active"},
     {"name":"claude-team.json","provider":"claude","email":"team@example.com","plan":"team","status":"error","status_message":"token expired"},
     {"name":"gemini-cli-project.json","provider":"gemini-cli","project_id":"demo-project","disabled":true}]
    """#.utf8))
    @State private var selection: Set<AuthFilesWorkbenchFile.ID> = [AuthFilesSample.files[1].id]
    @State private var sortOrder: [KeyPathComparator<AuthFilesWorkbenchFile>] = []

    var body: some View {
        DetailPaneSplit(showsPane: true, paneTitle: "认证文件详情", onClose: {}) {
            VStack(spacing: 0) {
                HStack {
                    Text(OasesLocalization.localizedFormat("已选 %lld 个", selection.count))
                    Button("启用所选") {}
                    Button("停用所选") {}
                    Button("删除…") {}
                    Spacer()
                }
                .padding(.horizontal, Oases.Space.page)
                .padding(.vertical, Oases.Space.s)
                .background(Oases.Color.wash)
                Divider()
                AuthFilesTable(files: Self.files, evidence: [:], selection: $selection, sortOrder: $sortOrder)
            }
        } pane: {
            AuthFileInspector(file: Self.files[1], evidence: nil, hasRuntimeFile: true)
        }
    }
}

private struct ModelsSample: View {
    static let run = try! JSONDecoder().decode(GatewayTestRun.self, from: Data(#"{"id":"run","started_at":1730000000000,"finished_at":null,"total":12,"done":7,"up":5,"down":1,"skipped":1}"#.utf8))
    @State private var selection: GatewayModelRow.ID? = "deepseek-chat"
    @State private var sortOrder = [KeyPathComparator(\GatewayModelRow.id)]

    var body: some View {
        DetailPaneSplit(showsPane: true, paneTitle: "模型详情", onClose: {}) {
            VStack(alignment: .leading, spacing: 0) {
                ModelTestRunLine(run: Self.run)
                    .padding(.horizontal, Oases.Space.page)
                    .padding(.vertical, Oases.Space.sm)
                Divider()
                ModelsTable(rows: SampleData.models, selection: $selection, sortOrder: $sortOrder)
            }
        } pane: {
            ModelInspector(row: SampleData.models[1])
        }
    }
}
