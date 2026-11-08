import ServiceManagement
import SwiftUI

struct AppVersionInfo {
    let marketingVersion: String
    let buildVersion: String?

    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        marketingVersion = Self.cleanedValue(
            infoDictionary?["CFBundleShortVersionString"] as? String
        ) ?? "Development"
        buildVersion = Self.cleanedValue(
            infoDictionary?["CFBundleVersion"] as? String
        )
    }

    var versionAndBuild: String {
        guard let buildVersion else { return marketingVersion }
        return "\(marketingVersion) (\(buildVersion))"
    }

    var displayText: String {
        "Oases CPA \(versionAndBuild)"
    }

    private static func cleanedValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}

/// Reads optional build-time values (xcconfig -> Info.plist). Empty or unexpanded values are nil.
private enum BuildSetting {
    static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    /// Only https URLs with a host are accepted.
    static func httpsURL(_ value: Any?) -> URL? {
        guard let url = text(value).flatMap(URL.init(string:)),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }
}

/// The optional author line of the About section, from the `OasesAuthorName` and
/// `OasesAuthorURL` Info.plist keys (build-time configuration). Empty values hide it.
struct AppAuthorInfo {
    let name: String?
    let url: URL?

    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        name = BuildSetting.text(infoDictionary?["OasesAuthorName"])
        url = BuildSetting.httpsURL(infoDictionary?["OasesAuthorURL"])
    }
}

/// The optional privacy-policy link of the About section, from the `OasesPrivacyPolicyURL`
/// Info.plist key (`OASES_PRIVACY_POLICY_URL`). The policy belongs to whoever distributes a
/// build, so the committed configuration leaves it empty and the link is hidden.
struct AppPrivacyPolicyInfo {
    let url: URL?

    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        url = BuildSetting.httpsURL(infoDictionary?["OasesPrivacyPolicyURL"])
    }
}

/// The panes of the Settings window (⌘,), in toolbar order.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, notifications, updates, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: OasesLocalization.localized("通用")
        case .notifications: OasesLocalization.localized("通知")
        case .updates: OasesLocalization.localized("更新")
        case .about: OasesLocalization.localized("关于")
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .notifications: "bell.badge"
        case .updates: "arrow.down.circle"
        case .about: "info.circle"
        }
    }
}

/// Settings: native toolbar panes, each a grouped form of fixed width; the window title is the
/// pane's name in the in-app language. Every section has at most one footer sentence.
struct SettingsView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    #if !APP_STORE
    @EnvironmentObject private var appUpdateService: AppUpdateService
    #endif
    @Environment(\.openWindow) private var openWindow
    @AppStorage(OasesAppearance.defaultsKey) private var preferredAppearanceRaw = OasesAppearance.system.rawValue
    @AppStorage(AppLanguage.defaultsKey) private var preferredLanguageRaw = AppLanguage.system.rawValue
    @StateObject private var launchAtLogin = LaunchAtLoginService()
    @State private var selection: SettingsPane

    static let paneWidth: CGFloat = 520

    init(initialPane: SettingsPane = .general) {
        _selection = State(initialValue: initialPane)
    }

    private var appVersion: AppVersionInfo { AppVersionInfo() }
    private var appAuthor: AppAuthorInfo { AppAuthorInfo() }
    private var appPrivacyPolicy: AppPrivacyPolicyInfo { AppPrivacyPolicyInfo() }
    private var interfaceLanguage: AppLanguage { AppLanguage(rawValue: preferredLanguageRaw) ?? .system }

    /// The panes with content in this build (no update pane without an update feed).
    private var panes: [SettingsPane] {
        #if !APP_STORE
        if appUpdateService.isEnabled { return SettingsPane.allCases }
        #endif
        return SettingsPane.allCases.filter { $0 != .updates }
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(panes) { pane in
                paneContent(pane)
                    .tabItem { Label(pane.title, systemImage: pane.systemImage) }
                    .tag(pane)
            }
        }
        .frame(width: Self.paneWidth)
        .background(
            AdaptiveWindowConfigurator(
                minimumContentSize: NSSize(width: Self.paneWidth, height: 200),
                title: selection.title
            )
        )
        .onAppear {
            launchAtLogin.refresh()
        }
    }

    @ViewBuilder
    private func paneContent(_ pane: SettingsPane) -> some View {
        Form {
            switch pane {
            case .general: general
            case .notifications: notifications
            case .updates: updates
            case .about: about
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - General

    @ViewBuilder
    private var general: some View {
        Section("外观") {
            Picker("颜色模式", selection: $preferredAppearanceRaw) {
                ForEach(OasesAppearance.allCases) { appearance in
                    Text(appearance.title).tag(appearance.rawValue)
                }
            }
        }

        Section {
            Picker("显示语言", selection: $preferredLanguageRaw) {
                ForEach(AppLanguage.allCases) { language in
                    Text(languageTitle(language)).tag(language.rawValue)
                }
            }
        } header: {
            Text("语言")
        } footer: {
            Text("供应商返回的原始错误信息保留原文。")
        }

        Section {
            Toggle(
                "登录时打开 Oases CPA",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                )
            )
            if launchAtLogin.status != .enabled, launchAtLogin.status != .notRegistered {
                LabeledContent("登录项状态") {
                    Text(launchAtLogin.statusTitle)
                }
            }
            if let errorMessage = launchAtLogin.errorMessage {
                InlineProblem(message: errorMessage)
            }
        } header: {
            Text("启动方式")
        } footer: {
            Text("关闭窗口后继续在菜单栏运行。")
        }
    }

    /// "跟随系统（简体中文）" for the system choice, the language's own name otherwise; always
    /// in the in-app language.
    private func languageTitle(_ language: AppLanguage) -> String {
        let title = language.displayTitle(in: interfaceLanguage)
        guard language == .system else { return title }
        return OasesLocalization.localizedFormat("%@（%@）", title, language.resolved.displayTitle(in: interfaceLanguage))
    }

    // MARK: - Notifications

    @ViewBuilder
    private var notifications: some View {
        Section {
            Toggle(
                "服务异常与恢复通知",
                isOn: Binding(
                    get: { deploymentStore.healthNotificationsEnabled },
                    set: { deploymentStore.setHealthNotificationsEnabled($0) }
                )
            )
        } footer: {
            Text("目标服务不可用或自动恢复时发送 macOS 通知；首次启用需要在系统设置中允许。")
        }
    }

    // MARK: - Updates

    @ViewBuilder
    private var updates: some View {
        #if !APP_STORE
        Section {
            LabeledContent("当前版本") {
                Text(appVersion.marketingVersion)
                    .monospacedDigit()
            }
            LabeledContent("最新版本") {
                Text(appUpdateService.latestTag ?? OasesLocalization.localized("尚未检查"))
                    .monospacedDigit()
            }
            LabeledContent("更新状态") {
                HStack(spacing: Oases.Space.s) {
                    if let tone = updateStatusTone { StatusDot(tone: tone) }
                    Text(updateStatusTitle)
                }
            }
            if let errorMessage = appUpdateService.errorMessage {
                InlineProblem(message: errorMessage)
            }
            HStack {
                Spacer()
                if appUpdateService.isUpdateAvailable {
                    Button(updateActionTitle) {
                        if appUpdateService.status == .downloaded {
                            appUpdateService.openDownloadedUpdate()
                        } else {
                            Task { await appUpdateService.downloadAvailableUpdate() }
                        }
                    }
                    .disabled(appUpdateService.status == .downloading)
                }
                Button("检查更新") {
                    Task { await appUpdateService.checkForUpdates() }
                }
                .disabled(appUpdateService.status == .checking || appUpdateService.status == .downloading)
            }
        } footer: {
            Text("新版本的 DMG 会下载到“下载”文件夹并自动打开。")
        }
        #endif
    }

    // MARK: - About

    @ViewBuilder
    private var about: some View {
        Section {
            LabeledContent("版本") {
                Text(appVersion.versionAndBuild)
                    .monospacedDigit()
                    .textSelection(.enabled)
            }
            LabeledContent("服务基线") { Text(verbatim: "CLIProxyAPI + CPA Manager Plus") }
            if let authorName = appAuthor.name {
                LabeledContent("作者") {
                    if let authorURL = appAuthor.url {
                        Link(authorName, destination: authorURL)
                    } else {
                        Text(authorName)
                    }
                }
            }
            HStack {
                Button("开源许可与致谢…") {
                    openWindow(id: OpenSourceNoticesWindow.id)
                }
                if let privacyPolicyURL = appPrivacyPolicy.url {
                    Link("隐私声明", destination: privacyPolicyURL)
                }
            }
        } header: {
            Text(verbatim: "Oases CPA for macOS")
        } footer: {
            Text("Oases CPA 独立开发，不隶属 CLIProxyAPI 或 CPA Manager Plus。")
        }
    }

    #if !APP_STORE
    private var updateStatusTitle: LocalizedStringKey {
        switch appUpdateService.status {
        case .idle: "尚未检查"
        case .checking: "正在检查…"
        case .upToDate: "已是最新版本"
        case .updateAvailable: "发现新版本"
        case .releaseWithoutDMG: "新版本暂无 DMG"
        case .downloading: "正在下载…"
        case .downloaded: "安装包已下载"
        case .failed: "检查或下载失败"
        }
    }

    private var updateStatusTone: Oases.Tone? {
        switch appUpdateService.status {
        case .updateAvailable, .downloading: .warning
        case .upToDate, .downloaded: .success
        case .releaseWithoutDMG, .failed: .danger
        default: nil
        }
    }

    private var updateActionTitle: LocalizedStringKey {
        switch appUpdateService.status {
        case .downloaded: "打开安装包"
        case .failed: "重试下载"
        default: "下载更新"
        }
    }
    #endif
}
