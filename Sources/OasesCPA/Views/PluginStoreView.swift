import Foundation
import SwiftUI

struct PluginStoreView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore

    @State private var searchText = ""
    @State private var filter: PluginStoreFilter = .all
    @State private var installingEntry: RuntimePluginStoreEntry?
    @State private var deletingEntry: RuntimePluginStoreEntry?
    @State private var operationErrorMessage: String?
    @State private var operationNotice: PluginStoreNotice?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let operationErrorMessage {
                InfoBanner(
                    title: "插件商店操作失败",
                    message: operationErrorMessage,
                    systemImage: "exclamationmark.triangle",
                    tint: .oasesRed
                )
            }

            if let operationNotice {
                InfoBanner(
                    title: operationNotice.title,
                    message: operationNotice.message,
                    systemImage: operationNotice.systemImage,
                    tint: operationNotice.tint
                )
            }

            if let error = runtimeDataStore.pluginStoreErrorMessage {
                InfoBanner(
                    title: "无法读取插件商店",
                    message: error,
                    systemImage: "exclamationmark.triangle",
                    tint: .oasesRed
                )
            }

            if runtimeDataStore.isLoadingPluginStore && runtimeDataStore.pluginStoreCatalog == nil {
                loadingCard
            } else if let catalog = runtimeDataStore.pluginStoreCatalog {
                summary(catalog)
                sourceCard(catalog)
                sourceErrors(catalog)
                entries(catalog)
            } else {
                unavailableCard
            }
        }
        .task(id: deploymentStore.stage) {
            runtimeDataStore.refreshPluginStore(using: deploymentStore)
        }
        .confirmationDialog(
            installConfirmationTitle,
            isPresented: Binding(
                get: { installingEntry != nil },
                set: { if !$0 { installingEntry = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let entry = installingEntry {
                Button(entry.installed ? "更新并启用" : "安装并启用") {
                    install(entry)
                    installingEntry = nil
                }
            }
            Button("取消", role: .cancel) { installingEntry = nil }
        } message: {
            if let entry = installingEntry {
                Text(installConfirmationMessage(for: entry))
            }
        }
        .confirmationDialog(
            "从目标删除插件？",
            isPresented: Binding(
                get: { deletingEntry != nil },
                set: { if !$0 { deletingEntry = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let entry = deletingEntry {
                Button(OasesLocalization.localizedFormat("删除 %@", entry.displayTitle), role: .destructive) {
                    delete(entry)
                    deletingEntry = nil
                }
            }
            Button("取消", role: .cancel) { deletingEntry = nil }
        } message: {
            if let entry = deletingEntry {
                Text(OasesLocalization.localizedFormat("这会移除当前目标插件目录中的 %@ 文件，并删除它的保存配置。若插件正在加载，CLIProxyAPI 会拒绝操作并要求先重启服务。", entry.displayTitle))
            }
        }
    }

    private var loadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 4) {
                Text("正在读取插件商店")
                    .font(.headline)
                Text("目标 CLIProxyAPI 会读取其配置的商店来源；App 不会代替目标主机下载任何代码。")
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
                title: "暂时无法读取插件商店",
                subtitle: "检查来源网络、Management Key 和 CLIProxyAPI 版本后重试",
                icon: "storefront"
            )
            Button("重新读取", systemImage: "arrow.clockwise") {
                runtimeDataStore.refreshPluginStore(using: deploymentStore)
            }
            .buttonStyle(.oasesPrimary)
        }
        .padding(22)
        .oasesCard()
    }

    private func summary(_ catalog: RuntimePluginStoreResponse) -> some View {
        let installed = catalog.plugins.filter(\.installed).count
        let updates = catalog.plugins.filter { $0.installed && $0.updateAvailable }.count

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                CardTitle(
                    title: "插件商店",
                    subtitle: "来源由当前目标的 CLIProxyAPI 配置决定",
                    icon: "storefront"
                )
                Spacer()
                Button("刷新商店", systemImage: "arrow.clockwise") {
                    operationErrorMessage = nil
                    runtimeDataStore.refreshPluginStore(using: deploymentStore)
                }
                .buttonStyle(.bordered)
                .disabled(runtimeDataStore.isLoadingPluginStore || runtimeDataStore.isSavingPlugins)
            }

            HStack(spacing: 24) {
                PluginStoreMetric(title: "商店条目", value: "\(catalog.plugins.count)", systemImage: "square.grid.2x2")
                PluginStoreMetric(title: "已安装", value: "\(installed)", systemImage: "puzzlepiece.extension")
                PluginStoreMetric(title: "可更新", value: "\(updates)", systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                if !catalog.pluginsEnabled {
                    Button("编辑全局开关", systemImage: "slider.horizontal.3") {
                        store.selectSection(.config)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if !catalog.pluginsEnabled {
                Label("全局 plugins.enabled 当前关闭。安装会保存并启用单个插件配置，但插件不会生效，直到在 CLIProxyAPI config.yaml 中开启全局插件运行层。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(Color.oasesOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .oasesCard()
    }

    private func sourceCard(_ catalog: RuntimePluginStoreResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(
                title: "来源与信任边界",
                subtitle: "安装前核验来源、仓库和版本；所有条目都需要明确确认",
                icon: "shield.lefthalf.filled"
            )

            if catalog.sources.isEmpty {
                Text("当前目标没有配置可读取的插件商店来源。请在 CLIProxyAPI config.yaml 中配置 plugins.store 后再刷新。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(catalog.sources, id: \.id) { source in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "network")
                                .foregroundStyle(Color.oasesBlue)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? source.id : source.name)
                                    .font(.headline)
                                Text(source.id)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if !source.url.isEmpty {
                                    Text(sanitizedDisplayURL(source.url))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        if source.id != catalog.sources.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(22)
        .oasesCard()
    }

    @ViewBuilder
    private func sourceErrors(_ catalog: RuntimePluginStoreResponse) -> some View {
        if !catalog.sourceErrors.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("部分来源不可用")
                    .font(.headline)
                ForEach(catalog.sourceErrors, id: \.self) { error in
                    Label(
                        OasesLocalization.localizedFormat("%@ 暂时无法读取。请检查目标网络、来源地址或所需授权后刷新。", error.sourceTitle.isEmpty ? OasesLocalization.localized("未命名来源") : error.sourceTitle),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.oasesOrange)
                }
            }
            .padding(18)
            .oasesCard()
        }
    }

    private func entries(_ catalog: RuntimePluginStoreResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                CardTitle(
                    title: "可用插件",
                    subtitle: "显示当前目标读取到的真实商店目录",
                    icon: "shippingbox"
                )
                Spacer()
                Picker("状态", selection: $filter) {
                    ForEach(PluginStoreFilter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize() // the label keeps its width in every language
                TextField("筛选插件", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)
            }

            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? OasesLocalization.localized("暂无匹配插件") : OasesLocalization.localized("没有匹配的插件"),
                    systemImage: "shippingbox",
                    description: Text("调整筛选条件或刷新当前目标的插件商店。")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 34)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(filteredEntries, id: \.storeID) { entry in
                        PluginStoreEntryRow(
                            entry: entry,
                            isSaving: runtimeDataStore.isSavingPlugins,
                            onInstall: {
                                operationErrorMessage = nil
                                operationNotice = nil
                                installingEntry = entry
                            },
                            onDelete: isDeleteOwner(entry, in: catalog) ? {
                                operationErrorMessage = nil
                                operationNotice = nil
                                deletingEntry = entry
                            } : nil,
                            onOpenConfiguration: {
                                store.selectSection(.config)
                            }
                        )
                        if entry.storeID != filteredEntries.last?.storeID {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(22)
        .oasesCard()
    }

    private var filteredEntries: [RuntimePluginStoreEntry] {
        guard let catalog = runtimeDataStore.pluginStoreCatalog else { return [] }
        let statusFiltered = catalog.plugins.filter { entry in
            switch filter {
            case .all: true
            case .available: !entry.installed
            case .installed: entry.installed
            case .updates: entry.installed && entry.updateAvailable
            }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return statusFiltered }
        return statusFiltered.filter { entry in
            [
                entry.id,
                entry.name,
                entry.description,
                entry.author,
                entry.repository,
                entry.sourceID,
                entry.sourceName,
                entry.license,
            ]
            .joined(separator: " ")
            .localizedCaseInsensitiveContains(query) || entry.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    private func isDeleteOwner(
        _ entry: RuntimePluginStoreEntry,
        in catalog: RuntimePluginStoreResponse
    ) -> Bool {
        guard entry.installed else { return false }
        let matches = catalog.plugins.filter { $0.id == entry.id && $0.installed }
        let owner = matches.first(where: { $0.installSourceStatus == "matched" }) ?? matches.first
        return owner?.storeID == entry.storeID
    }

    private var installConfirmationTitle: String {
        guard let entry = installingEntry else { return OasesLocalization.localized("安装插件？") }
        return entry.installed ? OasesLocalization.localized("更新插件？") : OasesLocalization.localized("安装插件？")
    }

    private func installConfirmationMessage(for entry: RuntimePluginStoreEntry) -> String {
        let action = entry.installed ? OasesLocalization.localized("更新会覆盖目标中的现有插件版本") : OasesLocalization.localized("安装会把插件代码写入目标主机")
        let source = entry.sourceTitle.isEmpty ? OasesLocalization.localized("未命名来源") : entry.sourceTitle
        let sourceURL = entry.sourceURL.isEmpty ? "" : OasesLocalization.localizedFormat("\n来源地址：%@", sanitizedDisplayURL(entry.sourceURL))
        let repository = entry.repository.isEmpty ? "" : OasesLocalization.localizedFormat("\n仓库：%@", entry.repository)
        let version = entry.version.isEmpty ? "" : OasesLocalization.localizedFormat("\n版本：%@", entry.version)
        return OasesLocalization.localizedFormat("%@，并在 CLIProxyAPI 中创建或更新该插件的启用配置。\n插件：%@\n来源：%@%@%@%@\n\n请仅在你已核验上述来源和代码时继续。", action, entry.displayTitle, source, sourceURL, repository, version)
    }

    private func install(_ entry: RuntimePluginStoreEntry) {
        operationErrorMessage = nil
        operationNotice = nil
        Task { @MainActor in
            do {
                let result = try await runtimeDataStore.installPluginFromStore(
                    entry,
                    using: deploymentStore
                )
                if result.restartRequired {
                    operationNotice = PluginStoreNotice(
                        title: "安装完成，需要重启",
                        message: OasesLocalization.localizedFormat("%@ 已写入当前目标；请从“连接与部署”停止并重新启动目标服务后再使用。", entry.displayTitle),
                        systemImage: "arrow.clockwise.circle",
                        tint: .oasesOrange
                    )
                } else {
                    operationNotice = PluginStoreNotice(
                        title: entry.installed ? OasesLocalization.localized("插件已更新") : OasesLocalization.localized("插件已安装"),
                        message: OasesLocalization.localizedFormat("%@ 已由当前目标的 CLIProxyAPI 保存并应用。状态列表正在刷新。", entry.displayTitle),
                        systemImage: "checkmark.circle",
                        tint: .oasesGreen
                    )
                }
            } catch {
                operationErrorMessage = OasesLocalization.localizedFormat(
                    entry.installed ? "更新 %@ 失败：%@" : "安装 %@ 失败：%@",
                    entry.displayTitle,
                    error.localizedDescription
                )
            }
        }
    }

    private func delete(_ entry: RuntimePluginStoreEntry) {
        operationErrorMessage = nil
        operationNotice = nil
        Task { @MainActor in
            do {
                let result = try await runtimeDataStore.deletePlugin(
                    entry.id,
                    using: deploymentStore
                )
                operationNotice = PluginStoreNotice(
                    title: result.restartRequired ? OasesLocalization.localized("需要重启后继续") : OasesLocalization.localized("插件已删除"),
                    message: result.restartRequired
                        ? OasesLocalization.localizedFormat("CLIProxyAPI 要求先重启服务，才能完成 %@ 的删除。", entry.displayTitle)
                        : OasesLocalization.localizedFormat("%@ 的目标文件和已保存配置已删除。", entry.displayTitle),
                    systemImage: result.restartRequired ? "arrow.clockwise.circle" : "checkmark.circle",
                    tint: result.restartRequired ? .oasesOrange : .oasesGreen
                )
            } catch {
                operationErrorMessage = OasesLocalization.localizedFormat("删除 %@ 失败：%@", entry.displayTitle, error.localizedDescription)
            }
        }
    }
}

private enum PluginStoreFilter: String, CaseIterable, Identifiable {
    case all
    case available
    case installed
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: OasesLocalization.localized("全部")
        case .available: OasesLocalization.localized("未安装")
        case .installed: OasesLocalization.localized("已安装")
        case .updates: OasesLocalization.localized("可更新")
        }
    }
}

private struct PluginStoreNotice {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
}

private struct PluginStoreMetric: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.oasesBlue)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.headline)
                Text(OasesLocalization.localized(title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct PluginStoreEntryRow: View {
    let entry: RuntimePluginStoreEntry
    let isSaving: Bool
    let onInstall: () -> Void
    let onDelete: (() -> Void)?
    let onOpenConfiguration: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.title3)
                .foregroundStyle(statusTint)
                .frame(width: 34, height: 34)
                .oasesIconTile()

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(entry.displayTitle)
                        .font(.headline)
                    StoreBadge(
                        title: entry.installed ? (entry.updateAvailable ? OasesLocalization.localized("可更新") : OasesLocalization.localized("已安装")) : "未安装",
                        tint: entry.updateAvailable ? .oasesOrange : (entry.installed ? .oasesGreen : .secondary)
                    )
                    if entry.installed && entry.effectiveEnabled {
                        StoreBadge(title: "已生效", tint: .oasesGreen)
                    }
                    if entry.authRequired {
                        StoreBadge(
                            title: entry.authConfigured ? OasesLocalization.localized("来源已授权") : OasesLocalization.localized("需要来源授权"),
                            tint: entry.authConfigured ? .oasesBlue : .oasesOrange
                        )
                    }
                }

                Text(entry.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if !entry.description.isEmpty {
                    Text(entry.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !entry.tags.isEmpty {
                    Text(entry.tags.prefix(6).joined(separator: " · "))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.oasesBlue)
                }

                if sourceUpdateBlocked {
                    Text("当前已安装版本来自不同或未确认的来源；为避免静默覆盖，此来源不提供更新。")
                        .font(.caption)
                        .foregroundStyle(Color.oasesOrange)
                }
            }

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 10) {
                if shouldOfferInstall && canRequestInstall {
                    Button(entry.installed ? "更新" : "安装", systemImage: entry.installed ? "arrow.triangle.2.circlepath" : "arrow.down.circle") {
                        onInstall()
                    }
                    .buttonStyle(.oasesPrimary)
                    .disabled(isSaving)
                } else if entry.authRequired && !entry.authConfigured {
                    Button("配置来源授权", systemImage: "key") {
                        onOpenConfiguration()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving)
                }

                if let onDelete {
                    Button("删除", systemImage: "trash", role: .destructive) {
                        onDelete()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSaving)
                }
            }
        }
        .padding(.vertical, 16)
    }

    private var canRequestInstall: Bool {
        (!entry.authRequired || entry.authConfigured) && !sourceUpdateBlocked
    }

    private var shouldOfferInstall: Bool {
        !entry.installed || entry.updateAvailable
    }

    private var sourceUpdateBlocked: Bool {
        entry.installed && ["different", "unknown"].contains(entry.installSourceStatus)
    }

    private var statusTint: Color {
        if entry.effectiveEnabled { return .oasesGreen }
        if entry.updateAvailable || entry.authRequired && !entry.authConfigured { return .oasesOrange }
        return entry.installed ? .oasesBlue : .secondary
    }

    private var details: [String] {
        var parts: [String] = []
        if !entry.versionSummary.isEmpty { parts.append("v\(entry.versionSummary)") }
        if !entry.author.isEmpty { parts.append(entry.author) }
        if !entry.sourceTitle.isEmpty { parts.append(OasesLocalization.localizedFormat("来源：%@", entry.sourceTitle)) }
        if !entry.installType.isEmpty { parts.append(entry.installType) }
        let platforms = entry.platforms.map(\.title).filter { !$0.isEmpty }
        if !platforms.isEmpty { parts.append(platforms.joined(separator: ", ")) }
        if !entry.license.isEmpty { parts.append(entry.license) }
        return parts
    }
}

private struct StoreBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(OasesLocalization.localized(title))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
    }
}

private func sanitizedDisplayURL(_ value: String) -> String {
    guard var components = URLComponents(string: value) else { return value }
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    return components.string ?? value
}
