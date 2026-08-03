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

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage(OasesAppearance.defaultsKey) private var preferredAppearanceRaw = OasesAppearance.system.rawValue
    @AppStorage(AppLanguage.defaultsKey) private var preferredLanguageRaw = AppLanguage.system.rawValue
    @StateObject private var launchAtLogin = LaunchAtLoginService()

    private var appVersion: AppVersionInfo { AppVersionInfo() }

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

                Link(destination: URL(string: "https://qingtengstudio.com/")!) {
                    Label("作者 · QingTeng Studio", systemImage: "person.crop.circle")
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
        .frame(minWidth: 560, idealWidth: 620, minHeight: 640, idealHeight: 760)
        .onAppear {
            launchAtLogin.refresh()
        }
    }
}
