import AppKit
import SwiftUI

struct AccessKeysView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @State private var isAddingKey = false
    @State private var keyToReplace: RuntimeAPIKey?
    @State private var keyToDelete: RuntimeAPIKey?
    @State private var deleteConfirmationPresented = false
    @State private var revealedKeyIndexes = Set<Int>()
    @State private var modelSearch = ""
    @State private var copiedMessage: String?
    @State private var operationErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statusStrip
                GatewayEndpointCard(
                    baseURL: deploymentStore.cpaClientURLString,
                    targetKind: deploymentStore.targetKind,
                    onCopy: { copy($0, message: "Base URL 已复制") }
                )

                if let error = runtimeDataStore.gatewayAccessErrorMessage {
                    InfoBanner(
                        title: "调用入口读取失败",
                        message: error,
                        systemImage: "exclamationmark.triangle",
                        tint: .oasesRed
                    )
                }

                if let error = operationErrorMessage {
                    InfoBanner(
                        title: "操作未完成",
                        message: error,
                        systemImage: "exclamationmark.triangle",
                        tint: .oasesRed
                    )
                }

                apiKeysCard
                modelsCard
            }
            .padding(28)
        }
        .task(id: deploymentStore.stage) {
            runtimeDataStore.refreshGatewayAccess(using: deploymentStore)
        }
        .sheet(isPresented: $isAddingKey) {
            APIKeyEditorSheet(mode: .create)
        }
        .sheet(item: $keyToReplace) { apiKey in
            APIKeyEditorSheet(mode: .replace(apiKey))
        }
        .confirmationDialog(
            "删除调用 API Key？",
            isPresented: $deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let apiKey = keyToDelete {
                Button("删除 \(apiKey.maskedValue)", role: .destructive) {
                    delete(apiKey)
                }
            }
            Button("取消", role: .cancel) {
                keyToDelete = nil
            }
        } message: {
            Text("删除后，使用该 Key 的客户端将立即无法调用当前 CPA 网关。")
        }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            PageHeader(section: .accessKeys)
            Spacer()
            if runtimeDataStore.isLoadingGatewayAccess {
                ProgressView()
                    .controlSize(.small)
            }
            Button("刷新", systemImage: "arrow.clockwise") {
                runtimeDataStore.refreshGatewayAccess(using: deploymentStore)
            }
            .buttonStyle(.bordered)
            .disabled(deploymentStore.stage != .attached || runtimeDataStore.isLoadingGatewayAccess)

            Button("新建 API Key", systemImage: "plus") {
                operationErrorMessage = nil
                isAddingKey = true
            }
            .buttonStyle(.oasesPrimary)
            .disabled(deploymentStore.stage != .attached || runtimeDataStore.isSavingGatewayAccess)
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 10) {
            StatusPill(
                title: "\(runtimeDataStore.apiKeys.count) 个调用 Key",
                tint: runtimeDataStore.apiKeys.isEmpty ? .oasesOrange : .oasesGreen,
                systemImage: "key.horizontal"
            )
            StatusPill(
                title: "\(runtimeDataStore.gatewayModels.count) 个可用模型",
                tint: runtimeDataStore.gatewayModels.isEmpty ? .oasesOrange : .oasesBlue,
                systemImage: "cpu"
            )
            StatusPill(
                title: deploymentStore.stage == .attached ? "目标已接入" : "尚未接入",
                tint: deploymentStore.stage == .attached ? .oasesGreen : .oasesOrange,
                systemImage: deploymentStore.stage == .attached ? "link" : "link.badge.plus"
            )
            Spacer()
            if let copiedMessage {
                Label(copiedMessage, systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(Color.oasesGreen)
            }
        }
    }

    private var apiKeysCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                CardTitle(
                    title: "调用 API Key",
                    subtitle: "密钥直接写入当前目标 CLIProxyAPI；默认脱敏，仅在本次 App 会话中按需显示",
                    icon: "key.fill"
                )
                Spacer()
                Button("新建", systemImage: "plus") {
                    operationErrorMessage = nil
                    isAddingKey = true
                }
                .buttonStyle(.bordered)
                .disabled(deploymentStore.stage != .attached || runtimeDataStore.isSavingGatewayAccess)
            }

            if deploymentStore.stage != .attached {
                ContentUnavailableView {
                    Label("连接目标后管理 API Key", systemImage: "link.badge.plus")
                } description: {
                    Text("先完成本机或 SSH/VPS 部署；这里不会读取或修改其他目标的密钥。")
                }
                .frame(maxWidth: .infinity, minHeight: 170)
            } else if runtimeDataStore.apiKeys.isEmpty && !runtimeDataStore.isLoadingGatewayAccess {
                ContentUnavailableView {
                    Label("尚未创建调用 API Key", systemImage: "key.horizontal")
                } description: {
                    Text("创建第一个 Key 后，客户端即可通过 Base URL 调用 `/v1/models` 和兼容接口。")
                } actions: {
                    Button("创建第一个 Key", systemImage: "plus") {
                        isAddingKey = true
                    }
                    .buttonStyle(.oasesPrimary)
                }
                .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                VStack(spacing: 0) {
                    ForEach(runtimeDataStore.apiKeys) { apiKey in
                        apiKeyRow(apiKey)
                        if apiKey.index != runtimeDataStore.apiKeys.last?.index {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(20)
        .oasesCard()
    }

    private func apiKeyRow(_ apiKey: RuntimeAPIKey) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "key.horizontal.fill")
                .font(.title3)
                .foregroundStyle(Oases.Color.textSecondary)
                .frame(width: 36, height: 36)
                .oasesIconTile()

            VStack(alignment: .leading, spacing: 4) {
                Text("调用 Key \(apiKey.index + 1)")
                    .font(.headline)
                Text(revealedKeyIndexes.contains(apiKey.index) ? apiKey.value : apiKey.maskedValue)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(revealedKeyIndexes.contains(apiKey.index) ? .primary : .secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                Text(revealedKeyIndexes.contains(apiKey.index) ? "当前会话内已显示完整值" : "已隐藏完整值")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button(revealedKeyIndexes.contains(apiKey.index) ? "隐藏" : "显示", systemImage: revealedKeyIndexes.contains(apiKey.index) ? "eye.slash" : "eye") {
                toggleReveal(apiKey)
            }
            .buttonStyle(.bordered)

            Button("复制", systemImage: "doc.on.doc") {
                copy(apiKey.value, message: "API Key 已复制")
            }
            .buttonStyle(.bordered)

            Menu {
                Button("轮换此 Key", systemImage: "arrow.triangle.2.circlepath") {
                    operationErrorMessage = nil
                    keyToReplace = apiKey
                }
                Button("删除", systemImage: "trash", role: .destructive) {
                    keyToDelete = apiKey
                    deleteConfirmationPresented = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .help("更多操作")
        }
        .padding(.vertical, 13)
    }

    private var modelsCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top) {
                CardTitle(
                    title: "当前可调用模型 ID",
                    subtitle: "使用当前目标的第一个调用 Key 读取 `/v1/models`；这不是静态或演示目录",
                    icon: "cpu"
                )
                Spacer()
                TextField("筛选模型", text: $modelSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }

            if deploymentStore.stage != .attached {
                Text("连接目标后读取模型目录。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
            } else if runtimeDataStore.apiKeys.isEmpty && !runtimeDataStore.isLoadingGatewayAccess {
                Text("当前目标尚无调用 Key；若网关要求鉴权，请先创建 Key 后再读取模型目录。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
            } else if let error = runtimeDataStore.gatewayModelsErrorMessage {
                InfoBanner(
                    title: "模型目录读取失败",
                    message: error,
                    systemImage: "exclamationmark.triangle",
                    tint: .oasesOrange
                )
            } else if filteredModels.isEmpty && !runtimeDataStore.isLoadingGatewayAccess {
                Text(modelSearch.isEmpty ? "当前网关没有返回可调用模型。请检查认证文件、Provider 或模型映射。" : "没有匹配的模型 ID。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .center)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 230), spacing: 10)],
                    alignment: .leading,
                    spacing: 10
                ) {
                    ForEach(filteredModels) { model in
                        modelRow(model)
                    }
                }
            }
        }
        .padding(20)
        .oasesCard()
    }

    private func modelRow(_ model: RuntimeGatewayModel) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .foregroundStyle(Color.oasesPurple)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.id)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                    .lineLimit(1)
                if model.title != model.id || !(model.ownedBy ?? "").isEmpty {
                    Text([model.title == model.id ? nil : model.title, model.ownedBy]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Button {
                copy(model.id, message: "模型 ID 已复制")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("复制模型 ID")
        }
        .padding(11)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var filteredModels: [RuntimeGatewayModel] {
        let query = modelSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return runtimeDataStore.gatewayModels }
        return runtimeDataStore.gatewayModels.filter {
            $0.id.localizedCaseInsensitiveContains(query) ||
            ($0.displayName?.localizedCaseInsensitiveContains(query) ?? false) ||
            ($0.ownedBy?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func toggleReveal(_ apiKey: RuntimeAPIKey) {
        if revealedKeyIndexes.contains(apiKey.index) {
            revealedKeyIndexes.remove(apiKey.index)
        } else {
            revealedKeyIndexes.insert(apiKey.index)
        }
    }

    private func copy(_ value: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedMessage = message
    }

    private func delete(_ apiKey: RuntimeAPIKey) {
        Task {
            do {
                try await runtimeDataStore.deleteAPIKey(apiKey, using: deploymentStore)
                revealedKeyIndexes.remove(apiKey.index)
                keyToDelete = nil
                operationErrorMessage = nil
            } catch {
                operationErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct GatewayEndpointCard: View {
    let baseURL: String
    let targetKind: DeploymentTargetKind
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(
                title: "网关调用地址",
                subtitle: targetKind == .ssh
                    ? "当前显示的是 Oases CPA 建立的本机 SSH 隧道地址"
                    : "当前本机 CLIProxyAPI 的直接调用地址",
                icon: "link"
            )

            HStack(spacing: 10) {
                Text(baseURL)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Button("复制", systemImage: "doc.on.doc") {
                    onCopy(baseURL)
                }
                .buttonStyle(.bordered)
                Spacer()
            }

            Divider()

            Text("模型目录：GET /v1/models   ·   兼容调用：POST /v1/chat/completions")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            if targetKind == .ssh {
                Text("如需让外部客户端访问 VPS，请在 VPS 上自行配置反向代理、防火墙和 TLS；这里的 127.0.0.1 地址只供本机 App 与本机客户端使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .oasesCard()
    }
}

private struct APIKeyEditorSheet: View {
    enum Mode {
        case create
        case replace(RuntimeAPIKey)

        var title: String {
            switch self {
            case .create: "新建调用 API Key"
            case .replace: "轮换调用 API Key"
            }
        }

        var actionTitle: String {
            switch self {
            case .create: "创建 Key"
            case .replace: "替换 Key"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    let mode: Mode
    @State private var value: String
    @State private var errorMessage: String?

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            _value = State(initialValue: RuntimeAPIKeyGenerator.generate())
        case .replace(let apiKey):
            _value = State(initialValue: apiKey.value)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(mode.title)
                .font(.title2.weight(.bold))

            Text(modeDescription)
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("API Key")
                    .font(.headline)
                TextField("sk-cpa-…", text: $value, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)

                HStack {
                    Button("生成安全 Key", systemImage: "dice") {
                        value = RuntimeAPIKeyGenerator.generate()
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Text("不会写入 App 偏好设置或日志")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                InfoBanner(
                    title: "无法保存 API Key",
                    message: errorMessage,
                    systemImage: "exclamationmark.triangle",
                    tint: .oasesRed
                )
            }

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(mode.actionTitle) {
                    save()
                }
                .buttonStyle(.oasesPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(runtimeDataStore.isSavingGatewayAccess)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private var modeDescription: String {
        switch mode {
        case .create:
            "创建后请立即复制到密码管理器。该 Key 用于客户端调用网关，不是 CLIProxyAPI 管理密钥。"
        case .replace:
            "替换会立即使旧 Key 失效。请先更新所有使用旧 Key 的客户端。"
        }
    }

    private func save() {
        Task {
            do {
                switch mode {
                case .create:
                    try await runtimeDataStore.addAPIKey(value, using: deploymentStore)
                case .replace(let apiKey):
                    try await runtimeDataStore.replaceAPIKey(apiKey, with: value, using: deploymentStore)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct GatewayAccessSummaryCard: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @State private var copiedMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                CardTitle(
                    title: "调用接入",
                    subtitle: "当前网关 Base URL、API Key 与实际模型目录",
                    icon: "key.horizontal"
                )
                Spacer()
                if runtimeDataStore.isLoadingGatewayAccess {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("管理", systemImage: "arrow.right") {
                    store.selectSection(.accessKeys)
                }
                .buttonStyle(.bordered)
            }

            if deploymentStore.stage != .attached {
                Text("连接目标环境后显示调用地址、已创建 API Key 和可用模型 ID。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 118, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Base URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(deploymentStore.cpaClientURLString)
                            .font(.system(.caption, design: .monospaced).weight(.medium))
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Button {
                            copy(deploymentStore.cpaClientURLString, message: "Base URL 已复制")
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("复制 Base URL")
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    StatusPill(
                        title: "\(runtimeDataStore.apiKeys.count) 个 Key",
                        tint: runtimeDataStore.apiKeys.isEmpty ? .oasesOrange : .oasesGreen,
                        systemImage: "key"
                    )
                    StatusPill(
                        title: "\(runtimeDataStore.gatewayModels.count) 个模型",
                        tint: runtimeDataStore.gatewayModels.isEmpty ? .oasesOrange : .oasesBlue,
                        systemImage: "cpu"
                    )
                    if let copiedMessage {
                        Text(copiedMessage)
                            .font(.caption2)
                            .foregroundStyle(Color.oasesGreen)
                    }
                }

                if let firstKey = runtimeDataStore.apiKeys.first {
                    Text("Key：\(firstKey.maskedValue)\(runtimeDataStore.apiKeys.count > 1 ? " · 另 \(runtimeDataStore.apiKeys.count - 1) 个" : "")")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if !runtimeDataStore.isLoadingGatewayAccess {
                    Text("尚未创建调用 Key")
                        .font(.caption)
                        .foregroundStyle(Color.oasesOrange)
                }

                if runtimeDataStore.gatewayModels.isEmpty && !runtimeDataStore.isLoadingGatewayAccess {
                    Text(runtimeDataStore.gatewayModelsErrorMessage ?? "模型目录会从当前网关的 /v1/models 读取。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(Array(runtimeDataStore.gatewayModels.prefix(8))) { model in
                            Text(model.id)
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.oasesPurple.opacity(0.10), in: Capsule())
                        }
                    }
                    if runtimeDataStore.gatewayModels.count > 8 {
                        Text("另有 \(runtimeDataStore.gatewayModels.count - 8) 个模型，可在“调用 API Key”查看与复制。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .oasesCard()
    }

    private func copy(_ value: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedMessage = message
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + (x > 0 ? spacing : 0)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
