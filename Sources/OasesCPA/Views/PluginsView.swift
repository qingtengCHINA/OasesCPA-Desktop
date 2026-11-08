import SwiftUI

struct PluginsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore

    @State private var searchText = ""
    @State private var selectedTab: PluginWorkspaceTab = .installed
    @State private var editingPlugin: RuntimePlugin?
    @State private var pluginOAuthRequest: PluginOAuthRequest?
    @State private var deletingPlugin: RuntimePlugin?
    @State private var operationErrorMessage: String?
    @State private var restartNotice: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if deploymentStore.stage != .attached {
                    disconnectedCard
                } else if selectedTab == .store {
                    PluginStoreView()
                } else {
                    content
                }
            }
            .padding(28)
        }
        .task(id: deploymentStore.stage) {
            runtimeDataStore.refreshPlugins(using: deploymentStore)
        }
        .sheet(item: $editingPlugin) { plugin in
            PluginConfigEditorView(plugin: plugin)
        }
        .sheet(item: $pluginOAuthRequest) { request in
            PluginOAuthView(plugin: request.plugin, provider: request.provider)
        }
        .confirmationDialog(
            "删除插件？",
            isPresented: Binding(
                get: { deletingPlugin != nil },
                set: { if !$0 { deletingPlugin = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let plugin = deletingPlugin {
                Button(OasesLocalization.localizedFormat("删除 %@", plugin.displayTitle), role: .destructive) {
                    delete(plugin)
                    deletingPlugin = nil
                }
            }
            Button("取消", role: .cancel) { deletingPlugin = nil }
        } message: {
            Text("这会从当前目标的插件目录移除插件文件，并删除对应的 plugins.configs 配置。若插件正在运行，CLIProxyAPI 可能要求先重启服务。")
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            PageHeader(section: .plugins)
            Picker("插件工作区", selection: $selectedTab) {
                ForEach(PluginWorkspaceTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            Spacer()

            if deploymentStore.stage == .attached {
                Button("打开 CPAMP 插件页", systemImage: "rectangle.on.rectangle") {
                    store.selectSection(.panel)
                }
                .buttonStyle(.bordered)
                .help("在 CPAMP 面板中安装、更新或删除插件")

                Button("刷新", systemImage: "arrow.clockwise") {
                    operationErrorMessage = nil
                    runtimeDataStore.refreshPlugins(using: deploymentStore)
                }
                .buttonStyle(.oasesPrimary)
                .disabled(runtimeDataStore.isLoadingPlugins || runtimeDataStore.isSavingPlugins)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let operationErrorMessage {
            InfoBanner(
                title: "插件操作失败",
                message: operationErrorMessage,
                systemImage: "exclamationmark.triangle",
                tint: .oasesRed
            )
        }

        if let restartNotice {
            InfoBanner(
                title: "需要重启后继续",
                message: restartNotice,
                systemImage: "arrow.clockwise.circle",
                tint: .oasesOrange
            )
        }

        if let error = runtimeDataStore.pluginsErrorMessage {
            InfoBanner(
                title: "无法读取插件目录",
                message: error,
                systemImage: "exclamationmark.triangle",
                tint: .oasesRed
            )
        }

        if runtimeDataStore.isLoadingPlugins && runtimeDataStore.pluginCatalog == nil {
            loadingCard
        } else if let catalog = runtimeDataStore.pluginCatalog {
            PluginRuntimeSummaryCard(
                catalog: catalog,
                onOpenConfig: { store.selectSection(.config) }
            )

            installedPlugins(catalog)

            InfoBanner(
                title: "插件代码需要明确确认",
                message: "“插件商店”标签页可原生查看来源并安装、更新或删除插件。插件以进程内代码运行；安装与删除都会在目标主机上变更文件和配置，请只信任你已核验的来源。",
                systemImage: "shield.lefthalf.filled",
                tint: .oasesOrange
            )
        } else {
            unavailableCard
        }
    }

    private var disconnectedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(
                title: "连接后管理插件",
                subtitle: "插件列表和配置直接读取当前目标的 CLIProxyAPI Management API",
                icon: "puzzlepiece.extension"
            )
            Text("先在“连接与部署”中选择本机终端或 SSH / VPS，并完成 CLIProxyAPI 部署或接入。App 不会绑定当前项目中的 Oases dev。")
                .foregroundStyle(.secondary)
            Button("前往连接与部署", systemImage: "arrow.triangle.branch") {
                store.selectSection(.environments)
            }
            .buttonStyle(.oasesPrimary)
        }
        .padding(22)
        .oasesCard()
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 4) {
                Text("正在读取已安装插件")
                    .font(.headline)
                Text("只读取当前目标的 CLIProxyAPI 插件目录和注册状态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(22)
        .oasesCard()
    }

    private var unavailableCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(
                title: "暂时无法读取插件",
                subtitle: "确认 CLIProxyAPI 版本、Management Key 和网络连接后重试",
                icon: "exclamationmark.triangle"
            )
            Button("重新读取", systemImage: "arrow.clockwise") {
                runtimeDataStore.refreshPlugins(using: deploymentStore)
            }
            .buttonStyle(.oasesPrimary)
        }
        .padding(22)
        .oasesCard()
    }

    private func installedPlugins(_ catalog: RuntimePluginsResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                CardTitle(
                    title: "已安装与已发现插件",
                    subtitle: OasesLocalization.localizedFormat("%lld 个条目 · 启停与配置直连当前目标", catalog.plugins.count),
                    icon: "puzzlepiece.extension"
                )
                Spacer()
                TextField("筛选名称或标识", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 230)
            }

            if filteredPlugins.isEmpty {
                ContentUnavailableView(
                    searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无插件" : "没有匹配的插件",
                    systemImage: "puzzlepiece.extension",
                    description: Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "当前目标未发现已安装或已配置的插件。"
                        : "调整筛选条件后重试。")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(filteredPlugins) { plugin in
                        RuntimePluginRow(
                            plugin: plugin,
                            globallyEnabled: catalog.pluginsEnabled,
                            isSaving: runtimeDataStore.isSavingPlugins,
                            onConfigure: {
                                operationErrorMessage = nil
                                editingPlugin = plugin
                            },
                            onToggle: { enabled in
                                toggle(plugin, enabled: enabled)
                            },
                            onOAuth: plugin.resolvedOAuthProvider == nil ? nil : {
                                guard let provider = plugin.resolvedOAuthProvider else { return }
                                pluginOAuthRequest = PluginOAuthRequest(plugin: plugin, provider: provider)
                            },
                            onDelete: {
                                operationErrorMessage = nil
                                restartNotice = nil
                                deletingPlugin = plugin
                            }
                        )
                        if plugin.id != filteredPlugins.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(22)
        .oasesCard()
    }

    private var filteredPlugins: [RuntimePlugin] {
        guard let catalog = runtimeDataStore.pluginCatalog else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return catalog.plugins }
        return catalog.plugins.filter { plugin in
            plugin.displayTitle.localizedCaseInsensitiveContains(query) ||
                plugin.id.localizedCaseInsensitiveContains(query) ||
                plugin.metadata?.author.localizedCaseInsensitiveContains(query) == true
        }
    }

    private func toggle(_ plugin: RuntimePlugin, enabled: Bool) {
        operationErrorMessage = nil
        restartNotice = nil
        Task { @MainActor in
            do {
                try await runtimeDataStore.setPluginEnabled(
                    plugin,
                    enabled: enabled,
                    using: deploymentStore
                )
            } catch {
                operationErrorMessage = OasesLocalization.localizedFormat("更新 %@ 状态失败：%@", plugin.displayTitle, error.localizedDescription)
            }
        }
    }

    private func delete(_ plugin: RuntimePlugin) {
        operationErrorMessage = nil
        restartNotice = nil
        Task { @MainActor in
            do {
                let result = try await runtimeDataStore.deletePlugin(
                    plugin,
                    using: deploymentStore
                )
                if result.restartRequired {
                    restartNotice = OasesLocalization.localizedFormat("CLIProxyAPI 已要求重启后才能完成 %@ 的删除。请从“连接与部署”停止并重新启动当前目标后重试。", plugin.displayTitle)
                }
            } catch {
                operationErrorMessage = OasesLocalization.localizedFormat("删除 %@ 失败：%@", plugin.displayTitle, error.localizedDescription)
            }
        }
    }
}

private enum PluginWorkspaceTab: String, CaseIterable, Identifiable {
    case installed
    case store

    var id: String { rawValue }

    var title: String {
        switch self {
        case .installed: OasesLocalization.localized("已安装")
        case .store: OasesLocalization.localized("插件商店")
        }
    }
}

private struct PluginOAuthRequest: Identifiable {
    let plugin: RuntimePlugin
    let provider: String

    var id: String { "\(plugin.id)::\(provider)" }
}

private struct PluginRuntimeSummaryCard: View {
    let catalog: RuntimePluginsResponse
    let onOpenConfig: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                CardTitle(
                    title: "插件运行层",
                    subtitle: "全局开关与目标插件目录",
                    icon: "puzzlepiece.extension"
                )
                Spacer()
                StatusPill(
                    title: catalog.pluginsEnabled ? "全局已启用" : "全局已关闭",
                    tint: catalog.pluginsEnabled ? .oasesGreen : .oasesOrange,
                    systemImage: catalog.pluginsEnabled ? "checkmark.circle" : "pause.circle"
                )
            }

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("插件目录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(catalog.pluginsDir)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("已生效")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(catalog.plugins.filter(\.effectiveEnabled).count) / \(catalog.plugins.count)")
                        .font(.title3.weight(.semibold))
                }

                Spacer()

                if !catalog.pluginsEnabled {
                    Button("编辑全局开关", systemImage: "slider.horizontal.3") {
                        onOpenConfig()
                    }
                    .buttonStyle(.bordered)
                }
            }

            if !catalog.pluginsEnabled {
                Label("全局 plugins.enabled 当前关闭。可继续调整每个插件的启停与配置，但它们不会在网关中生效，直到你在 CLIProxyAPI config.yaml 中启用全局插件运行层。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .oasesCard()
    }
}

private struct RuntimePluginRow: View {
    let plugin: RuntimePlugin
    let globallyEnabled: Bool
    let isSaving: Bool
    let onConfigure: () -> Void
    let onToggle: (Bool) -> Void
    let onOAuth: (() -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "puzzlepiece.extension")
                .font(.title3)
                .foregroundStyle(statusTint)
                .frame(width: 34, height: 34)
                .oasesIconTile()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(plugin.displayTitle)
                        .font(.headline)
                    if let version = plugin.metadata?.version, !version.isEmpty {
                        Text(version)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    StatusPill(
                        title: plugin.effectiveStateTitle,
                        tint: statusTint,
                        systemImage: plugin.effectiveEnabled ? "checkmark.circle" : "circle.dashed"
                    )
                }

                Text(plugin.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if !detailParts.isEmpty {
                    Text(detailParts.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !globallyEnabled && plugin.enabled {
                    Text("单插件已启用，但全局插件运行层关闭，因此当前不会生效。")
                        .font(.caption)
                        .foregroundStyle(Color.oasesOrange)
                }
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 10) {
                Toggle(
                    OasesLocalization.localizedFormat("启用 %@", plugin.displayTitle),
                    isOn: Binding(
                        get: { plugin.enabled },
                        set: { onToggle($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(isSaving)
                .help(plugin.enabled ? "停用此插件" : "启用此插件")

                HStack(spacing: 8) {
                    Button("配置", systemImage: "slider.horizontal.3") {
                        onConfigure()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving)

                    if let onOAuth, let provider = plugin.resolvedOAuthProvider {
                        Button("OAuth：\(provider)", systemImage: "person.badge.key") {
                            onOAuth()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isSaving)
                    }

                    if let onDelete {
                        Menu {
                            Button("删除插件", systemImage: "trash", role: .destructive) {
                                onDelete()
                            }
                        } label: {
                            Label("更多操作", systemImage: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .disabled(isSaving)
                    }
                }
            }
        }
        .padding(.vertical, 16)
    }

    private var statusTint: Color {
        if plugin.effectiveEnabled { return .oasesGreen }
        if plugin.enabled || plugin.configured { return .oasesOrange }
        return .secondary
    }

    private var detailParts: [String] {
        var parts: [String] = []
        if let author = plugin.metadata?.author, !author.isEmpty { parts.append(author) }
        if !plugin.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("已发现") }
        if plugin.configured { parts.append("已配置") }
        if plugin.registered { parts.append("已注册") }
        if !plugin.configFields.isEmpty { parts.append(OasesLocalization.localizedFormat("%lld 个配置字段", plugin.configFields.count)) }
        if !plugin.menus.isEmpty { parts.append(OasesLocalization.localizedFormat("%lld 个菜单", plugin.menus.count)) }
        return parts
    }
}
