import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A native, focused auth-file workbench. It deliberately owns list state so
/// it can evolve independently from the legacy auth-file page.
struct AuthFilesWorkbenchView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @StateObject private var workbench = AuthFilesWorkbenchStore()

    @State private var modelFile: AuthFilesWorkbenchFile?
    @State private var metadataFile: AuthFilesWorkbenchFile?
    @State private var editingRuntimeFile: RuntimeAuthFile?
    @State private var importingFile = false
    @State private var pendingImportName: String?
    @State private var pendingImportData: Data?
    @State private var importConfirmationPresented = false
    @State private var deleteSelectionConfirmationPresented = false
    @State private var deleteAllConfirmationPresented = false
    @State private var exportingFile = false
    @State private var exportDocument = RuntimeAuthJSONDocument()
    @State private var exportFileName = "auth.json"
    @State private var operationError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if deploymentStore.stage != .attached {
                    workbenchBanner(
                        title: "连接后读取认证文件",
                        message: "先在连接与部署中连接本机或 SSH/VPS；认证文件只从当前目标环境读取。",
                        systemImage: "lock.shield",
                        tint: .oasesOrange
                    )
                } else {
                    filters
                    selectionBar
                    if let error = workbench.errorMessage ?? operationError {
                        workbenchBanner(
                            title: "认证文件操作失败",
                            message: error,
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .oasesRed
                        )
                    }
                    content
                }
            }
            .padding(28)
        }
        .task(id: deploymentStore.stage) {
            await refresh()
        }
        .sheet(item: $modelFile) { file in
            AuthFilesWorkbenchModelSheet(
                file: file,
                loadModels: { try await loadModels(for: file) }
            )
        }
        .sheet(item: $metadataFile) { file in
            AuthFilesWorkbenchMetadataEditor(
                file: file,
                save: { priority, note, projectID in
                    await patchMetadata(file, priority: priority, note: note, projectID: projectID)
                }
            )
        }
        .sheet(item: $editingRuntimeFile) { file in
            AuthFileEditorView(file: file)
        }
        .fileImporter(
            isPresented: $importingFile,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: handleImport
        )
        .fileExporter(
            isPresented: $exportingFile,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFileName
        ) { result in
            if case .failure(let error) = result {
                operationError = "导出认证文件失败：\(error.localizedDescription)"
            }
        }
        .confirmationDialog(
            "删除所选认证文件？",
            isPresented: $deleteSelectionConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("删除 \(workbench.selectedIDs.count) 个文件", role: .destructive) {
                Task { await deleteSelected() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除会从当前目标的 CLIProxyAPI 认证目录移除这些 JSON 文件。请确认已保留必要的凭证备份。")
        }
        .confirmationDialog(
            "替换同名认证文件？",
            isPresented: $importConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let name = pendingImportName {
                Button("替换 \(name)", role: .destructive) {
                    guard let data = pendingImportData else { return }
                    pendingImportName = nil
                    pendingImportData = nil
                    uploadImportedFile(name: name, data: data)
                }
            }
            Button("取消", role: .cancel) {
                pendingImportName = nil
                pendingImportData = nil
            }
        } message: {
            Text("目标中已存在同名文件。替换会立即更新 CLIProxyAPI 当前使用的认证内容。")
        }
        .confirmationDialog(
            "删除全部认证文件？",
            isPresented: $deleteAllConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("确认删除全部", role: .destructive) {
                Task { await deleteAll() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这是不可逆的批量操作，会删除当前目标认证目录中的全部文件，而不仅是当前筛选结果。")
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                authFilesTitle
                Spacer()
                headerActions
            }
            VStack(alignment: .leading, spacing: 12) {
                authFilesTitle
                headerActions
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var authFilesTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("认证文件")
                .font(.largeTitle.weight(.bold))
            Text("集中查看账号状态、套餐、配额证据和支持模型")
                .foregroundStyle(.secondary)
        }
    }

    private var headerActions: some View {
        HStack(spacing: 12) {
            if workbench.isLoading || workbench.isMutating {
                ProgressView()
                    .controlSize(.small)
            }
            Button("刷新", systemImage: "arrow.clockwise") {
                Task { await refresh() }
            }
            .buttonStyle(.bordered)
            .disabled(workbench.isLoading || workbench.isMutating || deploymentStore.stage != .attached)
            Menu("更多", systemImage: "ellipsis.circle") {
                Button("导入 JSON", systemImage: "square.and.arrow.down") {
                    importingFile = true
                }
                Button("删除全部认证文件", systemImage: "trash", role: .destructive) {
                    deleteAllConfirmationPresented = true
                }
                .disabled(workbench.files.isEmpty || workbench.isMutating)
            }
            .menuStyle(.borderedButton)
        }
    }

    private var authSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索名称、Provider、邮箱、项目或备注", text: $workbench.searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var authFilterPickers: some View {
        HStack(spacing: 12) {
            Picker("排序", selection: $workbench.sort) {
                ForEach(AuthFilesWorkbenchSort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .frame(width: 140)

            Picker("显示", selection: $workbench.displayMode) {
                ForEach(AuthFilesWorkbenchDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    authSearchField
                    authFilterPickers
                }
                VStack(alignment: .leading, spacing: 10) {
                    authSearchField
                    authFilterPickers
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    providerChip("全部 Provider", selection: .all)
                    ForEach(workbench.providers, id: \.self) { provider in
                        providerChip(provider, selection: .provider(provider))
                    }
                }
            }

            Picker("状态", selection: $workbench.attentionFilter) {
                ForEach(AuthFilesWorkbenchAttentionFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 430)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func providerChip(
        _ title: String,
        selection: AuthFilesWorkbenchProviderFilter
    ) -> some View {
        let isSelected = workbench.providerFilter == selection
        return Button {
            workbench.providerFilter = selection
        } label: {
            Text(LocalizedStringKey(title))
                .font(.callout.weight(.medium))
                .foregroundStyle(isSelected ? Oases.Color.inkContrast : Oases.Color.textSecondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(isSelected ? Oases.Color.ink : Oases.Color.surface, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(isSelected ? Color.clear : Oases.Color.borderStrong, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Button {
                workbench.setVisibleSelection(workbench.selectedVisibleCount != workbench.filteredFiles.count)
            } label: {
                Label(
                    workbench.selectedVisibleCount == workbench.filteredFiles.count && !workbench.filteredFiles.isEmpty ? "取消全选" : "选择当前结果",
                    systemImage: workbench.selectedVisibleCount == workbench.filteredFiles.count && !workbench.filteredFiles.isEmpty ? "checkmark.square" : "square"
                )
            }
            .buttonStyle(.bordered)
            .disabled(workbench.filteredFiles.isEmpty)

            Text("显示 \(workbench.filteredFiles.count) / \(workbench.total ?? workbench.files.count) 个")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if !workbench.selectedIDs.isEmpty {
                Text("已选 \(workbench.selectedIDs.count) 个")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Button("删除所选", systemImage: "trash", role: .destructive) {
                    deleteSelectionConfirmationPresented = true
                }
                .buttonStyle(.bordered)
                .disabled(workbench.isMutating)
                Button("清除选择") { workbench.clearSelection() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        if workbench.filteredFiles.isEmpty {
            ContentUnavailableView(
                workbench.files.isEmpty ? "暂无认证文件" : "没有匹配结果",
                systemImage: workbench.files.isEmpty ? "doc.badge.plus" : "line.3.horizontal.decrease.circle",
                description: Text(workbench.files.isEmpty ? "可以从“更多”导入 JSON，或先在 CPAMP 面板完成 OAuth 登录。" : "试试清空搜索词或切换状态筛选。")
            )
            .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            LazyVStack(spacing: workbench.displayMode == .regular ? 12 : 6) {
                ForEach(workbench.filteredFiles) { file in
                    AuthFilesWorkbenchRow(
                        file: file,
                        evidence: runtimeDataStore.quotaEvidence[file.name],
                        isSelected: workbench.selectedIDs.contains(file.id),
                        compact: workbench.displayMode == .compact,
                        runtimeFile: runtimeDataStore.authFiles.first { $0.name == file.name },
                        onSelect: { workbench.toggleSelection(for: file) },
                        onModels: { modelFile = file },
                        onMetadata: { metadataFile = file },
                        onEdit: { editingRuntimeFile = runtimeDataStore.authFiles.first { $0.name == file.name } },
                        onExport: { exportFile(file) },
                        onToggle: { toggle(file) },
                        onDelete: {
                            workbench.selectOnly(file)
                            deleteSelectionConfirmationPresented = true
                        }
                    )
                }
            }
        }
    }

    private func workbenchBanner(
        title: String,
        message: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func refresh() async {
        guard deploymentStore.stage == .attached, !deploymentStore.managementKey.isEmpty else { return }
        await workbench.refresh(
            baseURL: deploymentStore.engineBaseURL,
            managementKey: deploymentStore.managementKey
        )
    }

    private func loadModels(for file: AuthFilesWorkbenchFile) async throws -> [AuthFilesWorkbenchModel] {
        try await workbench.loadModels(
            for: file,
            baseURL: deploymentStore.engineBaseURL,
            managementKey: deploymentStore.managementKey
        )
    }

    private func toggle(_ file: AuthFilesWorkbenchFile) {
        Task {
            await workbench.setDisabled(
                file,
                disabled: !file.isDisabled,
                baseURL: deploymentStore.engineBaseURL,
                managementKey: deploymentStore.managementKey
            )
        }
    }

    private func patchMetadata(
        _ file: AuthFilesWorkbenchFile,
        priority: Int?,
        note: String,
        projectID: String
    ) async {
        await workbench.patchFields(
            AuthFilesWorkbenchFieldsPatch(
                name: file.mutationSelector,
                priority: priority ?? 0,
                note: note,
                projectID: projectID
            ),
            baseURL: deploymentStore.engineBaseURL,
            managementKey: deploymentStore.managementKey
        )
    }

    private func deleteSelected() async {
        await workbench.deleteSelected(
            baseURL: deploymentStore.engineBaseURL,
            managementKey: deploymentStore.managementKey
        )
    }

    private func deleteAll() async {
        await workbench.deleteAll(
            baseURL: deploymentStore.engineBaseURL,
            managementKey: deploymentStore.managementKey
        )
    }

    private func exportFile(_ file: AuthFilesWorkbenchFile) {
        guard let runtimeFile = runtimeDataStore.authFiles.first(where: { $0.name == file.name }) else {
            operationError = "当前列表项还没有对应的 RuntimeAuthFile，暂时无法导出。"
            return
        }
        operationError = nil
        Task { @MainActor in
            do {
                let data = try await runtimeDataStore.downloadAuthFileData(runtimeFile, using: deploymentStore)
                exportDocument = RuntimeAuthJSONDocument(data: data)
                exportFileName = file.name
                exportingFile = true
            } catch {
                operationError = "读取认证文件失败：\(error.localizedDescription)"
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            operationError = "选择认证文件失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let name = url.lastPathComponent
                guard name.lowercased().hasSuffix(".json"), !name.contains("/"), !name.contains("\\") else {
                    throw RuntimeDataStoreError.invalidAuthFileName
                }
                let data = try Data(contentsOf: url)
                guard let canonicalData = canonicalJSONData(from: data) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if workbench.files.contains(where: { $0.name == name }) {
                    pendingImportName = name
                    pendingImportData = canonicalData
                    importConfirmationPresented = true
                } else {
                    uploadImportedFile(name: name, data: canonicalData)
                }
            } catch {
                operationError = "导入认证文件失败：\(error.localizedDescription)"
            }
        }
    }

    private func uploadImportedFile(name: String, data: Data) {
        Task { @MainActor in
            do {
                try await runtimeDataStore.uploadAuthFile(name: name, data: data, using: deploymentStore)
                await refresh()
            } catch {
                operationError = "保存导入文件失败：\(error.localizedDescription)"
            }
        }
    }

    private func canonicalJSONData(from data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              object is [String: Any],
              JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

private struct AuthFilesWorkbenchRow: View {
    let file: AuthFilesWorkbenchFile
    let evidence: RuntimeQuotaEvidence?
    let isSelected: Bool
    let compact: Bool
    let runtimeFile: RuntimeAuthFile?
    let onSelect: () -> Void
    let onModels: () -> Void
    let onMetadata: () -> Void
    let onEdit: () -> Void
    let onExport: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: onSelect) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(file.name)
                            .font(.headline.weight(.semibold))
                            .textSelection(.enabled)
                        Text(file.providerTitle)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.10), in: Capsule())
                        statusBadge
                    }
                    if let account = file.accountTitle {
                        Label(account, systemImage: "person.crop.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !compact {
                        HStack(spacing: 16) {
                            metadata("auth_index", file.authIndex)
                            metadata("套餐", file.plan)
                            metadata("项目", file.projectID ?? file.project)
                            if let priority = file.priority { metadata("优先级", String(priority)) }
                        }
                        if let note = file.note, !note.isEmpty {
                            Text(note)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                Spacer(minLength: 8)
                actionMenu
            }
            if !compact, let evidence {
                quotaEvidenceView(evidence)
            }
        }
        .padding(compact ? 10 : 16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 10 : 14, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
        }
    }

    private var statusBadge: some View {
        Text(file.displayStatus)
            .font(.caption.weight(.semibold))
            .foregroundStyle(file.needsAttention ? Color.oasesOrange : Color.oasesGreen)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((file.needsAttention ? Color.oasesOrange : Color.oasesGreen).opacity(0.11), in: Capsule())
    }

    private func metadata(_ title: String, _ value: String?) -> some View {
        Group {
            if let value, !value.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption2).foregroundStyle(.tertiary)
                    Text(value).font(.caption).textSelection(.enabled)
                }
            }
        }
    }

    private var actionMenu: some View {
        Menu {
            Button("查看支持模型", systemImage: "square.grid.2x2") { onModels() }
            Button("编辑管理字段", systemImage: "slider.horizontal.3") { onMetadata() }
            if runtimeFile != nil {
                Button("编辑 JSON", systemImage: "curlybraces") { onEdit() }
                Button("导出 JSON", systemImage: "square.and.arrow.up") { onExport() }
            }
            Divider()
            Button(file.isDisabled ? "启用认证文件" : "禁用认证文件", systemImage: file.isDisabled ? "checkmark.circle" : "pause.circle") { onToggle() }
            Button("删除认证文件", systemImage: "trash", role: .destructive) { onDelete() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
    }

    private func quotaEvidenceView(_ evidence: RuntimeQuotaEvidence) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("配额证据", systemImage: evidence.status == .success ? "checkmark.shield" : "exclamationmark.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(evidence.status == .success ? Color.oasesGreen : Color.oasesOrange)
                Spacer()
                Text(evidence.observedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(evidence.windows) { window in
                HStack(spacing: 8) {
                    Text(window.label).font(.caption).frame(width: 110, alignment: .leading)
                    ProgressView(value: (window.normalizedUsedPercent ?? 0) / 100)
                        .tint((window.normalizedUsedPercent ?? 0) > 85 ? Color.oasesOrange : Color.oasesGreen)
                    Text(window.normalizedUsedPercent.map { "\(Int($0))%" } ?? "—")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let message = evidence.message, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct AuthFilesWorkbenchModelSheet: View {
    @Environment(\.dismiss) private var dismiss
    let file: AuthFilesWorkbenchFile
    let loadModels: () async throws -> [AuthFilesWorkbenchModel]
    @State private var models: [AuthFilesWorkbenchModel] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("正在读取支持模型…")
                } else if let errorMessage {
                    ContentUnavailableView("读取失败", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else if models.isEmpty {
                    ContentUnavailableView("暂无模型", systemImage: "square.grid.2x2", description: Text("该认证文件当前没有返回可用模型。"))
                } else {
                    List(models) { model in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.id).font(.body.monospaced()).textSelection(.enabled)
                                if let displayName = model.displayName, !displayName.isEmpty {
                                    Text(displayName).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("复制") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.id, forType: .string)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle("支持模型 · \(file.name)")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 520)
        .task {
            do {
                models = try await loadModels()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

private struct AuthFilesWorkbenchMetadataEditor: View {
    @Environment(\.dismiss) private var dismiss
    let file: AuthFilesWorkbenchFile
    let save: (Int?, String, String) async -> Void
    @State private var priority: String
    @State private var note: String
    @State private var projectID: String
    @State private var isSaving = false

    init(file: AuthFilesWorkbenchFile, save: @escaping (Int?, String, String) async -> Void) {
        self.file = file
        self.save = save
        _priority = State(initialValue: file.priority.map(String.init) ?? "")
        _note = State(initialValue: file.note ?? "")
        _projectID = State(initialValue: file.projectID ?? file.project ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("路由与识别") {
                    LabeledContent("认证文件", value: file.name)
                    TextField("优先级（数字越大越优先）", text: $priority)
                    TextField("项目 ID", text: $projectID)
                }
                Section("备注") {
                    TextEditor(text: $note).frame(minHeight: 100)
                }
                Text("这些字段会直接写入当前目标的 CLIProxyAPI Management API。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("编辑管理字段")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        isSaving = true
                        Task { @MainActor in
                            await save(Int(priority.trimmingCharacters(in: .whitespacesAndNewlines)), note, projectID)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .buttonStyle(.oasesPrimary)
                    .disabled(isSaving || (Int(priority.trimmingCharacters(in: .whitespacesAndNewlines)) == nil && !priority.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}
