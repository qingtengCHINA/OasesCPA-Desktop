import SwiftUI

struct OpenAICompatibilityEditorView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @EnvironmentObject private var store: AppStore

    let provider: RuntimeOpenAICompatibility
    let index: Int?
    let onClose: () -> Void
    let onDirtyChange: (Bool) -> Void

    @State private var name: String
    @State private var baseURL: String
    @State private var prefix: String
    @State private var disabled: Bool
    @State private var disableCooling: Bool
    @State private var apiKeys: [RuntimeProviderAPIKeyDraft]
    @State private var models: [RuntimeProviderModelDraft]
    @State private var headers: [RuntimeProviderHeaderDraft]
    @State private var advancedExpanded = false
    @State private var modelsExpanded = false
    @State private var testModel: String
    @State private var isDiscoveringModels = false
    @State private var isTestingKeys = false
    @State private var discoveryMessage: String?
    @State private var discoveryFailed = false
    @State private var testMessage: String?

    init(
        provider: RuntimeOpenAICompatibility,
        index: Int? = nil,
        onClose: @escaping () -> Void,
        onDirtyChange: @escaping (Bool) -> Void
    ) {
        self.provider = provider
        self.index = index
        self.onClose = onClose
        self.onDirtyChange = onDirtyChange
        _name = State(initialValue: provider.name)
        _baseURL = State(initialValue: provider.baseURL)
        _prefix = State(initialValue: provider.prefix)
        _disabled = State(initialValue: provider.disabled)
        _disableCooling = State(initialValue: provider.disableCooling)
        let keyDrafts = provider.apiKeyEntries.map { RuntimeProviderAPIKeyDraft(entry: $0) }
        _apiKeys = State(initialValue: keyDrafts.isEmpty ? [RuntimeProviderAPIKeyDraft()] : keyDrafts)
        _models = State(initialValue: provider.models.map { RuntimeProviderModelDraft(model: $0) })
        _headers = State(initialValue: provider.headers.keys.sorted().map {
            RuntimeProviderHeaderDraft(key: $0, value: provider.headers[$0] ?? "")
        })
        _testModel = State(initialValue: provider.models.first?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    editorHeader

                    ProviderEditorSection(
                        title: "填写服务信息",
                        subtitle: "通常只需要名称和服务地址。地址示例：https://api.example.com/v1",
                        systemImage: "link"
                    ) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 280), spacing: 16)],
                            alignment: .leading,
                            spacing: 16
                        ) {
                            EditorField(title: "显示名称", detail: "起一个自己容易认出的名字") {
                                TextField("例如：我的中转服务", text: $name)
                                    .textFieldStyle(.roundedBorder)
                            }
                            EditorField(title: "服务地址", detail: "支持 http 或 https") {
                                TextField("https://api.example.com/v1", text: $baseURL)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                            }
                        }
                    }

                    ProviderEditorSection(
                        title: "添加 API Key",
                        subtitle: "可以添加多把密钥。测试结果会显示在每把密钥旁边。",
                        systemImage: "key"
                    ) {
                        ForEach(Array(apiKeys.indices), id: \.self) { keyIndex in
                            ProviderAPIKeyEditorCard(
                                entry: $apiKeys[keyIndex],
                                number: keyIndex + 1,
                                canDelete: apiKeys.count > 1,
                                canTest: canTestKey(at: keyIndex),
                                isBusy: isDiscoveringModels || isTestingKeys,
                                onTest: { testSingleKey(at: keyIndex) },
                                onDelete: { removeKey(at: keyIndex) }
                            )
                        }

                        Button("再添加一把密钥", systemImage: "plus") {
                            apiKeys.append(RuntimeProviderAPIKeyDraft())
                        }
                        .buttonStyle(.bordered)
                        .disabled(isDiscoveringModels || isTestingKeys)
                    }

                    ProviderEditorSection(
                        title: "自动检测",
                        subtitle: "先从 /models 读取可用模型，再用选中的模型向 /chat/completions 发送一条最短测试消息。",
                        systemImage: "wand.and.stars"
                    ) {
                        HStack(spacing: 12) {
                            Button("检测并添加模型", systemImage: "arrow.down.circle") {
                                discoverModels()
                            }
                            .buttonStyle(.oasesPrimary)
                            .disabled(!canDiscoverModels || isDiscoveringModels || isTestingKeys)

                            if isDiscoveringModels {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在读取模型…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 0)

                            if !models.isEmpty {
                                StatusPill(
                                    title: OasesLocalization.localizedFormat("已添加 %lld 个模型", Int64(models.count)),
                                    tint: .oasesGreen,
                                    systemImage: "checkmark"
                                )
                            }
                        }

                        if let discoveryMessage {
                            Label {
                                Text(LocalizedStringKey(discoveryMessage))
                            } icon: {
                                Image(systemName: discoveryFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            }
                            .font(.callout)
                            .foregroundStyle(discoveryFailed ? Color.oasesOrange : Color.oasesGreen)
                            .fixedSize(horizontal: false, vertical: true)
                        }

                        if !models.isEmpty {
                            Divider()
                            HStack(alignment: .center, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("连通性测试")
                                        .font(.subheadline.weight(.semibold))
                                    Text("会产生一次很小的模型请求，可能计入供应商用量。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Picker("测试模型", selection: $testModel) {
                                    ForEach(configuredModelNames, id: \.self) { modelName in
                                        Text(modelName).tag(modelName)
                                    }
                                }
                                .labelsHidden()
                                .frame(minWidth: 220, maxWidth: 340)

                                Button("测试全部密钥", systemImage: "bolt.horizontal.circle") {
                                    testAllKeys()
                                }
                                .buttonStyle(.bordered)
                                .disabled(isTestingKeys || isDiscoveringModels || testModel.isEmpty || !hasTestableKeys)
                            }
                        }

                        if let testMessage {
                            Text(LocalizedStringKey(testMessage))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    DisclosureGroup(isExpanded: $advancedExpanded) {
                        VStack(alignment: .leading, spacing: 18) {
                            advancedRoutingSection
                            Divider()
                            advancedHeadersSection
                            Divider()
                            advancedModelsSection
                        }
                        .padding(.top, 16)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("高级设置", systemImage: "slider.horizontal.3")
                                .font(.headline)
                            Text("前缀、路由策略、自定义请求头、密钥权重与模型别名")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(20)
                    .oasesCard()
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onClose() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("保存") { save() }
                        .buttonStyle(.oasesPrimary)
                        .disabled(!isValid || runtimeDataStore.isSavingProviders || isDiscoveringModels || isTestingKeys)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .onAppear {
            onDirtyChange(false)
        }
        .onChange(of: editorDraftSignature) { _, _ in
            onDirtyChange(true)
        }
        .onChange(of: diagnosticsSignature) { _, _ in
            resetDiagnostics()
        }
    }

    private var editorHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: index == nil ? "plus.circle.fill" : "slider.horizontal.3")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Oases.Color.textSecondary)
                .frame(width: 52, height: 52)
                .oasesIconTile()

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(index == nil ? "添加 AI 服务" : "调整 AI 服务"))
                    .font(.title2.weight(.bold))
                Text("填写服务地址和密钥，Oases CPA 会帮你读取模型并检查连接。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Label(deploymentStore.targetTitle, systemImage: "server.rack")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Oases.Color.surface, in: Capsule())
                .lineLimit(1)
        }
        .padding(20)
        .oasesCard()
    }

    private var advancedRoutingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("路由与密钥策略")
                .font(.headline)

            EditorField(title: "模型前缀", detail: "可选，例如 team-a；普通用户建议留空") {
                TextField("例如：relay", text: $prefix)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            ProviderEditorToggle(
                title: "停用此服务",
                detail: "保留配置，但不让 CLIProxyAPI 选择它。",
                isOn: $disabled
            )
            ProviderEditorToggle(
                title: "停用自动冷却",
                detail: "失败后仍继续尝试这项服务；一般不建议开启。",
                isOn: $disableCooling
            )

            if !apiKeys.isEmpty {
                Text("每把密钥的高级设置")
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 4)
                ForEach(Array(apiKeys.indices), id: \.self) { index in
                    ProviderKeyAdvancedFields(entry: $apiKeys[index], number: index + 1)
                }
            }
        }
    }

    private var advancedHeadersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("自定义请求头")
                        .font(.headline)
                    Text("只有供应商明确要求时才需要填写。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加请求头", systemImage: "plus") {
                    headers.append(RuntimeProviderHeaderDraft())
                }
                .buttonStyle(.bordered)
            }

            if headers.isEmpty {
                Text("未配置自定义请求头")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($headers) { header in
                    HStack(spacing: 10) {
                        TextField("Header 名称", text: header.key)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        SecureField("Header 值", text: header.value)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button("删除", systemImage: "trash", role: .destructive) {
                            let id = header.wrappedValue.id
                            headers.removeAll { $0.id == id }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var advancedModelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("模型与别名")
                        .font(.headline)
                    Text("可手动添加模型，或调整自动读取到的别名和模态。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("手动添加模型", systemImage: "plus") {
                    models.append(RuntimeProviderModelDraft())
                    modelsExpanded = true
                }
                .buttonStyle(.bordered)
            }

            if models.isEmpty {
                EmptyEditorState(
                    title: "尚未添加模型",
                    detail: "返回上方点击“检测并添加模型”，或在这里手动添加。",
                    systemImage: "square.stack.3d.up.slash"
                )
            } else {
                DisclosureGroup(isExpanded: $modelsExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach($models) { model in
                            ProviderModelEditorCard(
                                model: model,
                                onDelete: {
                                    let id = model.wrappedValue.id
                                    models.removeAll { $0.id == id }
                                    normalizeTestModel()
                                }
                            )
                        }
                    }
                    .padding(.top, 12)
                } label: {
                    Text("管理 \(models.count) 个模型")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private var configuredModelNames: [String] {
        var seen: Set<String> = []
        return models.compactMap { model in
            let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            return name
        }
    }

    private var configuredHeaders: [String: String] {
        headers.reduce(into: [:]) { result, header in
            let key = header.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = header.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { result[key] = value }
        }
    }

    private var hasAuthorizationHeader: Bool {
        configuredHeaders.keys.contains {
            $0.caseInsensitiveCompare("Authorization") == .orderedSame
        }
    }

    private var diagnosticsSignature: String {
        let headerPart = configuredHeaders.keys.sorted().map {
            "\($0.lowercased())=\(configuredHeaders[$0] ?? "")"
        }.joined(separator: "|")
        let keyPart = apiKeys.map {
            "\($0.apiKey)|\($0.authIndex ?? "")"
        }.joined(separator: "|")
        return [baseURL, testModel, headerPart, keyPart].joined(separator: "||")
    }

    private var editorDraftSignature: String {
        let keyPart = apiKeys.map {
            [$0.apiKey, $0.weightText, $0.proxyURL, $0.authIndex ?? ""]
                .joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
        let modelPart = models.map {
            [
                $0.name,
                $0.alias,
                $0.displayName,
                $0.forceMapping.map(String.init) ?? "",
                $0.image.map(String.init) ?? "",
                $0.inputModalitiesText,
                $0.outputModalitiesText
            ].joined(separator: "\u{1F}")
        }.joined(separator: "\u{1E}")
        let headerPart = headers.map { [$0.key, $0.value].joined(separator: "\u{1F}") }
            .joined(separator: "\u{1E}")
        return [
            name,
            baseURL,
            prefix,
            String(disabled),
            String(disableCooling),
            keyPart,
            modelPart,
            headerPart
        ].joined(separator: "\u{1D}")
    }

    private var hasTestableKeys: Bool {
        apiKeys.indices.contains(where: canTestKey(at:))
    }

    private var canDiscoverModels: Bool {
        guard validHTTPURL(baseURL) else { return false }
        return hasAuthorizationHeader
            || provider.authIndex?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || apiKeys.contains(where: { !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.authIndex != nil })
    }

    private func canTestKey(at index: Int) -> Bool {
        guard apiKeys.indices.contains(index), validHTTPURL(baseURL), !testModel.isEmpty else { return false }
        let entry = apiKeys[index]
        return hasAuthorizationHeader
            || !entry.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || entry.authIndex?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func validHTTPURL(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return false }
        return true
    }

    private func removeKey(at index: Int) {
        guard apiKeys.count > 1, apiKeys.indices.contains(index) else { return }
        apiKeys.remove(at: index)
        testMessage = nil
    }

    private func resetDiagnostics() {
        for index in apiKeys.indices {
            apiKeys[index].testStatus = .idle
            apiKeys[index].testMessage = ""
        }
        testMessage = nil
    }

    private func discoverModels() {
        guard canDiscoverModels,
              let credential = apiKeys.first(where: {
                  !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.authIndex != nil
              }) ?? apiKeys.first else { return }

        isDiscoveringModels = true
        discoveryMessage = nil
        discoveryFailed = false

        Task { @MainActor in
            defer { isDiscoveringModels = false }
            do {
                let request = try RuntimeProviderDraftDiagnosticsFactory.modelsRequest(
                    baseURL: baseURL,
                    apiKey: credential.apiKey,
                    authIndex: credential.authIndex ?? provider.authIndex,
                    headers: configuredHeaders
                )
                let response = try await ManagementAPIClient().apiCall(
                    request,
                    baseURL: deploymentStore.engineBaseURL,
                    managementKey: deploymentStore.managementKey
                )
                let discovered = try RuntimeProviderDraftDiagnosticsParser.models(from: response)
                guard !discovered.isEmpty else {
                    discoveryFailed = true
                    discoveryMessage = "服务已响应，但没有返回可识别的模型。"
                    return
                }

                var existingNames = Set(models.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
                var added = 0
                for item in discovered where existingNames.insert(item.name.lowercased()).inserted {
                    models.append(RuntimeProviderModelDraft(discovered: item))
                    added += 1
                }
                normalizeTestModel()
                discoveryMessage = added > 0
                    ? OasesLocalization.localizedFormat("已从 /models 读取 %lld 个模型，并新添加 %lld 个。", Int64(discovered.count), Int64(added))
                    : OasesLocalization.localizedFormat("已从 /models 读取 %lld 个模型；当前列表已经包含它们。", Int64(discovered.count))
            } catch let error as RuntimeProviderDraftDiagnosticsError {
                discoveryFailed = true
                discoveryMessage = error.safeMessage
            } catch {
                discoveryFailed = true
                discoveryMessage = "无法读取模型，请检查服务地址、密钥和目标网络。"
            }
        }
    }

    private func testSingleKey(at index: Int) {
        guard canTestKey(at: index), !isTestingKeys else { return }
        isTestingKeys = true
        testMessage = nil
        Task { @MainActor in
            let succeeded = await runKeyTest(at: index)
            isTestingKeys = false
            testMessage = succeeded
                ? OasesLocalization.localizedFormat("这把密钥可以正常调用 %@。", testModel)
                : OasesLocalization.localized("这把密钥未通过测试，请查看它旁边的状态。")
        }
    }

    private func testAllKeys() {
        guard !isTestingKeys else { return }
        let indexes = apiKeys.indices.filter { canTestKey(at: $0) }
        guard !indexes.isEmpty else { return }

        isTestingKeys = true
        testMessage = OasesLocalization.localizedFormat("正在测试 %lld 把密钥…", Int64(indexes.count))
        Task { @MainActor in
            var successCount = 0
            for index in indexes {
                if await runKeyTest(at: index) { successCount += 1 }
            }
            isTestingKeys = false
            if successCount == indexes.count {
                testMessage = OasesLocalization.localizedFormat("全部 %lld 把密钥均可正常调用 %@。", Int64(successCount), testModel)
            } else if successCount == 0 {
                testMessage = OasesLocalization.localized("没有密钥通过测试；请检查地址、模型名称、密钥或服务器网络。")
            } else {
                testMessage = OasesLocalization.localizedFormat("%lld 把可用，%lld 把需要处理。", Int64(successCount), Int64(indexes.count - successCount))
            }
        }
    }

    @MainActor
    private func runKeyTest(at index: Int) async -> Bool {
        guard apiKeys.indices.contains(index) else { return false }
        apiKeys[index].testStatus = .running
        apiKeys[index].testMessage = OasesLocalization.localized("正在连接…")
        let entry = apiKeys[index]

        do {
            let request = try RuntimeProviderDraftDiagnosticsFactory.chatCompletionsRequest(
                baseURL: baseURL,
                apiKey: entry.apiKey,
                authIndex: entry.authIndex ?? provider.authIndex,
                headers: configuredHeaders,
                model: testModel
            )
            let response = try await ManagementAPIClient().apiCall(
                request,
                baseURL: deploymentStore.engineBaseURL,
                managementKey: deploymentStore.managementKey
            )
            let outcome = RuntimeProviderDraftDiagnosticsParser.safeOutcome(
                from: response,
                kind: .chatCompletions
            )
            apiKeys[index].testStatus = outcome.isSuccess ? .success : .failed
            apiKeys[index].testMessage = outcome.message
            return outcome.isSuccess
        } catch let error as RuntimeProviderDraftDiagnosticsError {
            apiKeys[index].testStatus = .failed
            apiKeys[index].testMessage = error.safeMessage
            return false
        } catch {
            apiKeys[index].testStatus = .failed
            apiKeys[index].testMessage = OasesLocalization.localized("无法完成请求，请检查网络和服务配置。")
            return false
        }
    }

    private func normalizeTestModel() {
        let names = configuredModelNames
        if !names.contains(testModel) { testModel = names.first ?? "" }
    }

    private var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, validHTTPURL(baseURL) else { return false }
        guard apiKeys.allSatisfy({ entry in
            let value = entry.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return entry.proxyURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !entry.appearsRedacted else { return false }
            guard !entry.weightText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            guard let weight = Int(entry.weightText), (1...1_000_000).contains(weight) else { return false }
            return true
        }) else { return false }
        guard headers.allSatisfy({ draft in
            let key = draft.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = draft.value.trimmingCharacters(in: .whitespacesAndNewlines)
            return (!key.isEmpty && !value.isEmpty) || (key.isEmpty && value.isEmpty)
        }) else { return false }
        return models.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func save() {
        guard isValid else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyPayloads = apiKeys
            .filter { !$0.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.payload)
        let modelPayloads = models.map(\.payload)

        if let index {
            runtimeDataStore.patchOpenAICompatibility(
                name: provider.name,
                index: index,
                value: RuntimeOpenAICompatibilityPatch(
                    name: trimmedName,
                    prefix: trimmedPrefix,
                    disabled: disabled,
                    disableCooling: disableCooling,
                    baseURL: trimmedBaseURL,
                    apiKeyEntries: keyPayloads,
                    models: modelPayloads,
                    headers: configuredHeaders
                ),
                using: deploymentStore
            )
        } else {
            runtimeDataStore.createOpenAICompatibility(
                RuntimeOpenAICompatibilityWrite(
                    name: trimmedName,
                    priority: provider.priority,
                    disabled: disabled,
                    prefix: trimmedPrefix,
                    baseURL: trimmedBaseURL,
                    apiKeyEntries: keyPayloads,
                    models: modelPayloads,
                    headers: configuredHeaders,
                    disableCooling: disableCooling
                ),
                using: deploymentStore
            )
        }
        onDirtyChange(false)
        onClose()
    }
}

private struct ProviderEditorSection<Content: View>: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let content: Content

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(Oases.Color.textSecondary)
                    .frame(width: 32, height: 32)
                    .oasesIconTile()

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(title))
                        .font(.headline)
                    Text(LocalizedStringKey(subtitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
        .padding(20)
        .oasesCard()
    }
}

private struct EditorField<Content: View>: View {
    let title: String
    let detail: String
    let content: Content

    init(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(LocalizedStringKey(title))
                .font(.subheadline.weight(.semibold))
            content
            Text(LocalizedStringKey(detail))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ProviderEditorToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline.weight(.semibold))
                Text(LocalizedStringKey(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }
}

private struct EmptyEditorState: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(title))
                    .font(.subheadline.weight(.medium))
                Text(LocalizedStringKey(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ProviderAPIKeyEditorCard: View {
    @Binding var entry: RuntimeProviderAPIKeyDraft
    let number: Int
    let canDelete: Bool
    let canTest: Bool
    let isBusy: Bool
    let onTest: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProviderKeyStatusIcon(status: entry.testStatus)
                Text("密钥 \(number)")
                    .font(.subheadline.weight(.semibold))
                SecureField("粘贴完整 API Key", text: $entry.apiKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Button("测试", systemImage: "bolt.horizontal.circle", action: onTest)
                    .buttonStyle(.bordered)
                    .disabled(!canTest || isBusy)
                if canDelete {
                    Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                }
            }

            if !entry.testMessage.isEmpty {
                Text(LocalizedStringKey(entry.testMessage))
                    .font(.caption)
                    .foregroundStyle(entry.testStatus == .failed ? Color.oasesOrange : .secondary)
                    .padding(.leading, 30)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct ProviderKeyStatusIcon: View {
    let status: RuntimeProviderKeyTestStatus

    var body: some View {
        Group {
            switch status {
            case .idle:
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
            case .running:
                ProgressView()
                    .controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.oasesGreen)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.oasesOrange)
            }
        }
        .frame(width: 20, height: 20)
    }
}

private struct ProviderKeyAdvancedFields: View {
    @Binding var entry: RuntimeProviderAPIKeyDraft
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("密钥 \(number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 230), spacing: 14)],
                alignment: .leading,
                spacing: 12
            ) {
                EditorField(title: "权重", detail: "留空即为默认值 1") {
                    TextField("1", text: $entry.weightText)
                        .textFieldStyle(.roundedBorder)
                }
                EditorField(title: "单密钥代理地址", detail: "只让这把密钥经指定代理访问") {
                    TextField("https://proxy.example.com", text: $entry.proxyURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ProviderModelEditorCard: View {
    @Binding var model: RuntimeProviderModelDraft
    let onDelete: () -> Void

    private var forceMapping: Binding<Bool> {
        Binding(
            get: { model.forceMapping ?? false },
            set: { model.forceMapping = $0 }
        )
    }

    private var imageModel: Binding<Bool> {
        Binding(
            get: { model.image ?? false },
            set: { model.image = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("模型映射", systemImage: "arrow.triangle.branch")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 230), spacing: 16)],
                alignment: .leading,
                spacing: 14
            ) {
                EditorField(title: "上游模型名", detail: "必填") {
                    TextField("例如：glm-4.6", text: $model.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                EditorField(title: "客户端别名", detail: "可选") {
                    TextField("例如：glm-4.6-proxy", text: $model.alias)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                EditorField(title: "展示名称", detail: "可选") {
                    TextField("例如：GLM-4.6", text: $model.displayName)
                        .textFieldStyle(.roundedBorder)
                }
                EditorField(title: "输入模态", detail: "例如：text,image") {
                    TextField("text,image", text: $model.inputModalitiesText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                EditorField(title: "输出模态", detail: "例如：text") {
                    TextField("text", text: $model.outputModalitiesText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }

            HStack(spacing: 22) {
                Toggle("强制映射", isOn: forceMapping)
                Toggle("图像模型", isOn: imageModel)
            }
            .toggleStyle(.switch)
            .font(.subheadline)
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private enum RuntimeProviderKeyTestStatus: Equatable {
    case idle
    case running
    case success
    case failed
}

private struct RuntimeProviderAPIKeyDraft: Identifiable {
    let id = UUID()
    var apiKey: String
    var weightText: String
    var proxyURL: String
    var authIndex: String?
    var testStatus: RuntimeProviderKeyTestStatus = .idle
    var testMessage = ""

    init(entry: RuntimeProviderAPIKey? = nil) {
        apiKey = entry?.apiKey ?? ""
        weightText = entry?.weight.map(String.init) ?? ""
        proxyURL = entry?.proxyURL ?? ""
        authIndex = entry?.authIndex
    }

    var appearsRedacted: Bool {
        RuntimeProviderAPIKey(apiKey: apiKey).appearsRedacted
    }

    var redacted: String {
        RuntimeProviderAPIKey(apiKey: apiKey).redacted
    }

    var payload: RuntimeProviderAPIKey {
        RuntimeProviderAPIKey(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            weight: Int(weightText.trimmingCharacters(in: .whitespacesAndNewlines)),
            proxyURL: proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

private struct RuntimeProviderHeaderDraft: Identifiable {
    let id = UUID()
    var key: String
    var value: String

    init(key: String = "", value: String = "") {
        self.key = key
        self.value = value
    }
}

private struct RuntimeProviderModelDraft: Identifiable {
    let id = UUID()
    var name: String
    var alias: String
    var displayName: String
    var forceMapping: Bool?
    var image: Bool?
    var inputModalitiesText: String
    var outputModalitiesText: String
    let thinking: RuntimeJSONValue?

    init(model: RuntimeProviderModel? = nil) {
        name = model?.name ?? ""
        alias = model?.alias ?? ""
        displayName = model?.displayName ?? ""
        forceMapping = model?.forceMapping
        image = model?.image
        inputModalitiesText = model?.inputModalities?.joined(separator: ",") ?? ""
        outputModalitiesText = model?.outputModalities?.joined(separator: ",") ?? ""
        thinking = model?.thinking
    }

    init(discovered: RuntimeDiscoveredProviderModel) {
        name = discovered.name
        alias = discovered.alias ?? ""
        displayName = discovered.description ?? ""
        forceMapping = nil
        image = nil
        inputModalitiesText = ""
        outputModalitiesText = ""
        thinking = nil
    }

    var payload: RuntimeProviderModel {
        RuntimeProviderModel(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            alias: alias.trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            forceMapping: forceMapping,
            image: image,
            inputModalities: modalities(from: inputModalitiesText),
            outputModalities: modalities(from: outputModalitiesText),
            thinking: thinking
        )
    }

    private func modalities(from text: String) -> [String]? {
        let values = text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values
    }
}
