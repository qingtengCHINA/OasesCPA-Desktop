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
