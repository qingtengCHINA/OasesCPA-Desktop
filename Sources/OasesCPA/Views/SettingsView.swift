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

/// The optional author line of the About section, from the `OasesAuthorName` and
/// `OasesAuthorURL` Info.plist keys (build-time configuration). Empty values hide it.
struct AppAuthorInfo {
    let name: String?
    let url: URL?

    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        name = Self.cleanedValue(infoDictionary?["OasesAuthorName"] as? String)
        url = Self.cleanedValue(infoDictionary?["OasesAuthorURL"] as? String)
            .flatMap(URL.init(string:))
            .flatMap { $0.scheme?.lowercased() == "https" && $0.host?.isEmpty == false ? $0 : nil }
    }

    private static func cleanedValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    #if !APP_STORE
    @EnvironmentObject private var appUpdateService: AppUpdateService
    #endif
    @Environment(\.openWindow) private var openWindow
    @AppStorage(OasesAppearance.defaultsKey) private var preferredAppearanceRaw = OasesAppearance.system.rawValue
    @AppStorage(AppLanguage.defaultsKey) private var preferredLanguageRaw = AppLanguage.system.rawValue
    @StateObject private var launchAtLogin = LaunchAtLoginService()

    private var appVersion: AppVersionInfo { AppVersionInfo() }
    private var appAuthor: AppAuthorInfo { AppAuthorInfo() }

    var body: some View {
        VStack(spacing: 0) {
            Form {
            Section("连接与部署") {
                LabeledContent("CLIProxyAPI Base URL") {
                    Text(deploymentStore.cpaClientURLString)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Text("地址由本机部署或 SSH 隧道自动管理，App 不要求用户手动维护固定 Base URL。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LabeledContent("当前模式") {
                    StatusPill(
                        title: deploymentStore.stage == .attached ? "已接入" : store.connectionLabel,
                        tint: deploymentStore.stage == .attached ? .oasesGreen : .oasesOrange,
                        systemImage: deploymentStore.stage == .attached ? "checkmark.circle" : "shippingbox"
                    )
                }

                LabeledContent("目标环境") {
                    Text(deploymentStore.targetTitle)
                }

                LabeledContent("CPA 管理 API") {
                    Text(deploymentStore.cpaManagementURL)
                        .font(.system(.caption, design: .monospaced))
                }

                LabeledContent("CPAMP 面板") {
                    Text(deploymentStore.localPanelURL)
                        .font(.system(.caption, design: .monospaced))
                }

                Text("管理密钥和 SSH 私钥内容使用 macOS Keychain；普通偏好设置只保存目标地址、端口和安装目录。启动 App 或切换已保存目标时不会读取钥匙串，只有点击“连接已保存目标”后才会访问凭据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("后台提醒") {
                Toggle(
                    "服务异常与恢复通知",
                    isOn: Binding(
                        get: { deploymentStore.healthNotificationsEnabled },
                        set: { deploymentStore.setHealthNotificationsEnabled($0) }
                    )
                )

                Text("启用后，当保持运行的目标服务不可用或自动恢复时，Oases CPA 会发送 macOS 通知。首次启用需要在系统通知设置中授权。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("后台运行") {
                Toggle(
                    "登录时启动 Oases CPA",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )

                LabeledContent("登录项状态") {
                    Text(launchAtLogin.statusTitle)
                        .foregroundStyle(launchAtLogin.isEnabled ? Color.oasesGreen : Color.secondary)
                }

                if let errorMessage = launchAtLogin.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Color.oasesRed)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("启用后，用户重新登录 Mac 时 App 会启动并显示上次目标；它不会自动读取钥匙串、建立 SSH 隧道或启动服务。用户点击“连接已保存目标”后才会恢复连接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("关闭主窗口后，Oases CPA 会继续在菜单栏运行。点击菜单栏中的 App 图标可以查看 CLIProxyAPI 状态或重新打开窗口。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("外观") {
                Picker("颜色模式", selection: $preferredAppearanceRaw) {
                    ForEach(OasesAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }

                Text("此设置会立即应用到主窗口、独立编辑窗口和设置页；选择“跟随系统”会恢复 macOS 的外观设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("语言") {
                Picker("显示语言", selection: $preferredLanguageRaw) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayTitle(in: AppLanguage(rawValue: preferredLanguageRaw) ?? .system))
                            .tag(language.rawValue)
                    }
                }

                Text("语言会立即应用到 Oases CPA 的主窗口、菜单栏和设置；部分来自 CLIProxyAPI 或供应商的原始错误信息会保留原文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            #if !APP_STORE
            if appUpdateService.isEnabled {
                Section("软件更新") {
                    LabeledContent("当前版本") {
                        Text(appVersion.marketingVersion)
                            .monospacedDigit()
                    }

                    LabeledContent("最新版本") {
                        Text(appUpdateService.latestTag ?? OasesLocalization.localized("尚未检查"))
                            .monospacedDigit()
                    }

                    LabeledContent("更新状态") {
                        Text(updateStatusTitle)
                            .foregroundStyle(updateStatusColor)
                    }

                    HStack {
                        Button("检查更新", systemImage: "arrow.clockwise") {
                            Task { await appUpdateService.checkForUpdates() }
                        }
                        .disabled(appUpdateService.status == .checking || appUpdateService.status == .downloading)

                        if appUpdateService.isUpdateAvailable {
                            Button(updateActionTitle, systemImage: "arrow.down.circle") {
                                if appUpdateService.status == .downloaded {
                                    appUpdateService.openDownloadedUpdate()
                                } else {
                                    Task { await appUpdateService.downloadAvailableUpdate() }
                                }
                            }
                            .disabled(appUpdateService.status == .downloading)
                        }
                    }

                    if let errorMessage = appUpdateService.errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(Color.oasesRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Oases CPA 会定期读取官方 GitHub Releases。发现新版本后，下载的 DMG 会保存到“下载”文件夹并自动打开。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            #endif

            Section("关于") {
                LabeledContent("产品") { Text("Oases CPA for macOS") }
                LabeledContent("服务基线") { Text("CLIProxyAPI + CPA Manager Plus") }
                LabeledContent("版本") { Text(appVersion.versionAndBuild) }

                Button("开源许可与致谢…", systemImage: "curlybraces.square") {
                    openWindow(id: OpenSourceNoticesWindow.id)
                }

                Link(destination: URL(string: "https://www.freeprivacypolicy.com/live/e016e69e-1613-454a-83cb-411674f7d303")!) {
                    Label("隐私声明", systemImage: "hand.raised")
                }

                if let authorName = appAuthor.name {
                    if let authorURL = appAuthor.url {
                        Link(destination: authorURL) {
                            Label("作者 · \(authorName)", systemImage: "person.crop.circle")
                        }
                    } else {
                        Label("作者 · \(authorName)", systemImage: "person.crop.circle")
                    }
                }

                Text("Oases CPA 独立开发，不隶属 CLIProxyAPI 或 CPA Manager Plus；完整 MIT 许可证和上游链接可在“开源许可与致谢”中查看。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
            .formStyle(.grouped)
            .padding(24)

            Text(appVersion.displayText)
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .textSelection(.enabled)
                .padding(.bottom, 12)
                .accessibilityLabel("版本 \(appVersion.versionAndBuild)")
        }
        .frame(minWidth: 520, idealWidth: 620, minHeight: 520, idealHeight: 720)
        .onAppear {
            launchAtLogin.refresh()
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

    private var updateStatusColor: Color {
        switch appUpdateService.status {
        case .updateAvailable, .downloading: .oasesOrange
        case .upToDate, .downloaded: .oasesGreen
        case .releaseWithoutDMG, .failed: .oasesRed
        default: .secondary
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
