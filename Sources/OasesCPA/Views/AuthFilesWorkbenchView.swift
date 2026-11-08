import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Auth files as a dense native table: sortable columns, a provider menu and a status filter,
/// search in the toolbar, a selection bar for bulk actions, and a detail pane for one selected
/// file. Import is the toolbar action; destructive actions are confirmed.
struct AuthFilesWorkbenchView: View {
    @EnvironmentObject private var store: AppStore
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
    @State private var sortOrder: [KeyPathComparator<AuthFilesWorkbenchFile>] = []

    private var isAttached: Bool { deploymentStore.stage == .attached }

    var body: some View {
        DetailPaneSplit(
            showsPane: selectedFile != nil,
            paneTitle: "认证文件详情",
            onClose: { workbench.clearSelection() }
        ) {
            page
        } pane: {
            if let file = selectedFile {
                AuthFileInspector(
                    file: file,
                    evidence: runtimeDataStore.quotaEvidence[file.name],
                    hasRuntimeFile: runtimeFile(for: file) != nil,
                    isMutating: workbench.isMutating,
                    onModels: { modelFile = file },
                    onMetadata: { metadataFile = file },
                    onEdit: { editingRuntimeFile = runtimeFile(for: file) },
                    onExport: { exportFile(file) },
                    onToggle: { toggle(file) },
                    onDelete: { deleteSelectionConfirmationPresented = true }
                )
            }
        }
        .searchable(text: $workbench.searchText, placement: .toolbar, prompt: Text("搜索名称、Provider、邮箱、项目或备注"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("导入…") { importingFile = true }
                    Divider()
                    Button("删除全部认证文件…", role: .destructive) {
                        deleteAllConfirmationPresented = true
                    }
                    .disabled(workbench.files.isEmpty || workbench.isMutating)
                } label: {
                    Label("导入…", systemImage: "square.and.arrow.down")
                } primaryAction: {
                    importingFile = true
                }
                .disabled(!isAttached)
                .help(isAttached ? OasesLocalization.localized("导入 JSON 认证文件") : OasesLocalization.localized("请先连接一个目标环境。"))
            }
        }
        .task(id: deploymentStore.stage) {
            await refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .oasesRefreshCurrentSection)) { notification in
            guard notification.userInfo?["section"] as? String == AppSection.authFiles.rawValue else { return }
            Task { await refresh() }
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
                operationError = OasesLocalization.localizedFormat("导出认证文件失败：%@", error.localizedDescription)
            }
        }
        .confirmationDialog(
            "删除所选认证文件？",
            isPresented: $deleteSelectionConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(OasesLocalization.localizedFormat("删除 %lld 个文件", workbench.selectedIDs.count), role: .destructive) {
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
                Button(OasesLocalization.localizedFormat("替换 %@", name), role: .destructive) {
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

    // MARK: - Page

    @ViewBuilder
    private var page: some View {
        if !isAttached {
            GatewayStateLine(
                systemImage: "link",
                message: "先在“连接与部署”接入本机或 SSH / VPS 目标，这一页才有数据。",
                actionTitle: "打开连接与部署",
                action: { store.selectSection(.environments) }
            )
            .padding(Oases.Space.page)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Oases.Space.m) {
                    AuthFilesFilterBar(workbench: workbench)
                    Spacer(minLength: Oases.Space.sm)
                    if workbench.isLoading || workbench.isMutating {
                        ProgressView().controlSize(.small)
                    }
                    Text(OasesLocalization.localizedFormat("显示 %lld / %lld 个", workbench.filteredFiles.count, workbench.total ?? workbench.files.count))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(Oases.Color.textSecondary)
                }
                .padding(.horizontal, Oases.Space.page)
                .padding(.vertical, Oases.Space.sm)
                if let error = workbench.errorMessage ?? operationError {
                    InlineProblem(message: error)
                        .padding(.horizontal, Oases.Space.page)
                        .padding(.bottom, Oases.Space.sm)
                }
                if !workbench.selectedIDs.isEmpty {
                    selectionBar
                }
                Divider()
                content
            }
        }
    }

    /// Shown only while at least one file is selected.
    private var selectionBar: some View {
        HStack(spacing: Oases.Space.sm) {
            Text(OasesLocalization.localizedFormat("已选 %lld 个", workbench.selectedIDs.count))
                .monospacedDigit()
            Button("启用所选") { setSelectedDisabled(false) }
                .disabled(workbench.isMutating)
            Button("停用所选") { setSelectedDisabled(true) }
                .disabled(workbench.isMutating)
            Button("删除…") { deleteSelectionConfirmationPresented = true }
                .disabled(workbench.isMutating)
            Spacer()
            Button("取消选择") { workbench.clearSelection() }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, Oases.Space.page)
        .padding(.vertical, Oases.Space.s)
        .background(Oases.Color.wash)
    }

    @ViewBuilder
    private var content: some View {
        if workbench.files.isEmpty, workbench.isLoading {
            GatewayLoadingView(title: "正在读取认证文件…")
        } else if workbench.files.isEmpty {
            OasesEmptyState(
                systemImage: "doc.badge.plus",
                title: "还没有认证文件",
                message: "用“导入…”添加 JSON，或在“OAuth”中授权。",
                actionTitle: "导入…",
                action: { importingFile = true }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if workbench.filteredFiles.isEmpty {
            Text("没有匹配的认证文件。")
                .foregroundStyle(Oases.Color.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            AuthFilesTable(
                files: workbench.filteredFiles.sorted(using: sortOrder),
                evidence: runtimeDataStore.quotaEvidence,
                selection: Binding(get: { workbench.selectedIDs }, set: { workbench.setSelection($0) }),
                sortOrder: $sortOrder,
                isMutating: workbench.isMutating,
                onModels: { modelFile = $0 },
                onMetadata: { metadataFile = $0 },
                onToggle: { toggle($0) },
                onDelete: { file in
                    if !workbench.selectedIDs.contains(file.id) { workbench.selectOnly(file) }
                    deleteSelectionConfirmationPresented = true
                }
            )
        }
    }

    private var selectedFile: AuthFilesWorkbenchFile? {
        guard workbench.selectedIDs.count == 1, let id = workbench.selectedIDs.first else { return nil }
        return workbench.files.first { $0.id == id }
    }

    private func runtimeFile(for file: AuthFilesWorkbenchFile) -> RuntimeAuthFile? {
        runtimeDataStore.authFiles.first { $0.name == file.name }
    }

    private func setSelectedDisabled(_ disabled: Bool) {
        let targets = workbench.files.filter { workbench.selectedIDs.contains($0.id) && $0.isDisabled != disabled }
        Task {
            for file in targets {
                await workbench.setDisabled(
                    file,
                    disabled: disabled,
                    baseURL: deploymentStore.engineBaseURL,
                    managementKey: deploymentStore.managementKey
                )
            }
        }
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
            operationError = OasesLocalization.localized("当前列表项还没有对应的 RuntimeAuthFile，暂时无法导出。")
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
                operationError = OasesLocalization.localizedFormat("读取认证文件失败：%@", error.localizedDescription)
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            operationError = OasesLocalization.localizedFormat("选择认证文件失败：%@", error.localizedDescription)
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
                operationError = OasesLocalization.localizedFormat("导入认证文件失败：%@", error.localizedDescription)
            }
        }
    }

    private func uploadImportedFile(name: String, data: Data) {
        Task { @MainActor in
            do {
                try await runtimeDataStore.uploadAuthFile(name: name, data: data, using: deploymentStore)
                await refresh()
            } catch {
                operationError = OasesLocalization.localizedFormat("保存导入文件失败：%@", error.localizedDescription)
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

/// The auth files table. Columns sort through their headers; checkboxes are the table's own
/// multi-selection; the context menu acts on the clicked row.
struct AuthFilesTable: View {
    let files: [AuthFilesWorkbenchFile]
    let evidence: [String: RuntimeQuotaEvidence]
    @Binding var selection: Set<AuthFilesWorkbenchFile.ID>
    @Binding var sortOrder: [KeyPathComparator<AuthFilesWorkbenchFile>]
    var isMutating = false
    var onModels: (AuthFilesWorkbenchFile) -> Void = { _ in }
    var onMetadata: (AuthFilesWorkbenchFile) -> Void = { _ in }
    var onToggle: (AuthFilesWorkbenchFile) -> Void = { _ in }
    var onDelete: (AuthFilesWorkbenchFile) -> Void = { _ in }

    var body: some View {
        Table(files, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("名称", value: \.name) { file in
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.name)
            }
            .width(min: 140, ideal: 220)
            TableColumn("提供商", value: \.providerTitle) { file in
                Text(file.providerTitle).lineLimit(1)
            }
            .width(min: 70, ideal: 90)
            TableColumn("登录账号", value: \.accountSortKey) { file in
                Text(file.accountTitle ?? "—")
                    .foregroundStyle(Oases.Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 100, ideal: 170)
            TableColumn("套餐", value: \.planSortKey) { file in
                Text(file.plan ?? "—")
                    .foregroundStyle(file.plan == nil ? Oases.Color.textTertiary : Oases.Color.textPrimary)
                    .lineLimit(1)
            }
            .width(min: 50, ideal: 70)
            TableColumn("额度") { file in
                Text(AuthFileTexts.quota(evidence[file.name]))
                    .monospacedDigit()
                    .foregroundStyle(Oases.Color.textSecondary)
            }
            .width(min: 50, ideal: 70)
            TableColumn("优先级", value: \.prioritySortKey) { file in
                Text(file.priority.map(String.init) ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(Oases.Color.textSecondary)
            }
            .width(min: 50, ideal: 60)
            TableColumn("状态", value: \.statusRank) { file in
                AuthFileStatusLabel(file: file)
            }
            .width(min: 80, ideal: 110)
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: AuthFilesWorkbenchFile.ID.self) { ids in
            if ids.count == 1, let file = files.first(where: { $0.id == ids.first }) {
                Button("查看支持模型") { onModels(file) }
                Button("编辑管理字段…") { onMetadata(file) }.disabled(isMutating)
                Button(file.isDisabled ? "启用认证文件" : "禁用认证文件") { onToggle(file) }.disabled(isMutating)
                Divider()
                Button("删除…", role: .destructive) { onDelete(file) }.disabled(isMutating)
            }
        } primaryAction: { ids in
            if ids.count == 1, let file = files.first(where: { $0.id == ids.first }) { onMetadata(file) }
        }
    }
}

extension AuthFilesWorkbenchFile {
    var accountSortKey: String { accountTitle ?? "" }
    var planSortKey: String { plan ?? "" }
    var prioritySortKey: Int { priority ?? Int.min }
    /// Needs attention first, then disabled, then normal.
    var statusRank: Int { isDisabled ? 1 : (needsAttention ? 0 : 2) }
}

enum AuthFileTexts {
    /// The highest used percentage of the file's quota windows, or "—" without evidence.
    static func quota(_ evidence: RuntimeQuotaEvidence?) -> String {
        guard let used = evidence?.windows.compactMap(\.normalizedUsedPercent).max() else { return "—" }
        return "\(Int(used.rounded()))%"
    }
}

/// Status dot and the status word.
struct AuthFileStatusLabel: View {
    let file: AuthFilesWorkbenchFile

    private var tone: Oases.Tone {
        if file.isDisabled { return .neutral }
        return file.needsAttention ? .warning : .success
    }

    var body: some View {
        HStack(spacing: Oases.Space.s) {
            StatusDot(tone: tone)
            Text(file.displayStatus)
                .lineLimit(1)
        }
        .help(file.statusMessage ?? file.displayStatus)
        .accessibilityElement(children: .combine)
    }
}

/// The provider menu and the status filter of the auth files page. Both keep their ideal
/// width (`fixedSize`), so a label is never squeezed to zero width (the letters of a squeezed
/// English label used to stack vertically).
struct AuthFilesFilterBar: View {
    @ObservedObject var workbench: AuthFilesWorkbenchStore

    var body: some View {
        HStack(spacing: Oases.Space.m) {
            Picker(OasesLocalization.localized("提供商"), selection: $workbench.providerFilter) {
                Text("全部").tag(AuthFilesWorkbenchProviderFilter.all)
                ForEach(workbench.providers, id: \.self) { provider in
                    Text(verbatim: provider).tag(AuthFilesWorkbenchProviderFilter.provider(provider))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()

            Picker(OasesLocalization.localized("状态"), selection: $workbench.attentionFilter) {
                ForEach(AuthFilesWorkbenchAttentionFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// One selected auth file: label-above-value rows, quota evidence as plain rows, and the file's
/// actions (the destructive one last, behind a menu).
struct AuthFileInspector: View {
    let file: AuthFilesWorkbenchFile
    let evidence: RuntimeQuotaEvidence?
    var hasRuntimeFile = false
    var isMutating = false
    var onModels: () -> Void = {}
    var onMetadata: () -> Void = {}
    var onEdit: () -> Void = {}
    var onExport: () -> Void = {}
    var onToggle: () -> Void = {}
    var onDelete: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Oases.Space.md) {
                InspectorField(label: "名称") {
                    Text(file.name).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                InspectorField(label: "状态") { AuthFileStatusLabel(file: file) }
                if let message = file.statusMessage, !message.isEmpty {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(Oases.Color.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                InspectorField(label: "提供商") { Text(file.providerTitle) }
                if let account = file.accountTitle {
                    InspectorField(label: "登录账号") { Text(account).textSelection(.enabled) }
                }
                if let plan = file.plan, !plan.isEmpty {
                    InspectorField(label: "套餐") { Text(plan) }
                }
                if let project = file.projectID ?? file.project, !project.isEmpty {
                    InspectorField(label: "项目") { Text(project).font(.body.monospaced()).textSelection(.enabled) }
                }
                if let priority = file.priority {
                    InspectorField(label: "优先级") { Text(String(priority)).monospacedDigit() }
                }
                if let note = file.note, !note.isEmpty {
                    InspectorField(label: "备注") { Text(note).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                }
                if let evidence {
                    InspectorField(label: "配额证据") {
                        VStack(alignment: .leading, spacing: Oases.Space.xs) {
                            ForEach(evidence.windows) { window in
                                HStack {
                                    Text(window.label)
                                    Spacer()
                                    Text(window.normalizedUsedPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                                        .monospacedDigit()
                                        .foregroundStyle(Oases.Color.textSecondary)
                                }
                            }
                            Text(OasesLocalization.localizedFormat("记录于 %@", evidence.observedAt.oasesShortDateTime))
                                .font(.caption)
                                .foregroundStyle(Oases.Color.textSecondary)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: Oases.Space.sm) {
                    Button("查看支持模型", action: onModels)
                    Button("编辑管理字段…", action: onMetadata).disabled(isMutating)
                    if hasRuntimeFile {
                        HStack {
                            Button("编辑 JSON", action: onEdit)
                            Button("导出 JSON", action: onExport)
                        }
                    }
                }
                HStack {
                    Button(file.isDisabled ? "启用认证文件" : "禁用认证文件", action: onToggle)
                        .disabled(isMutating)
                    Spacer()
                    Menu {
                        Button("删除…", role: .destructive, action: onDelete)
                    } label: {
                        Text("更多")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(isMutating)
                }
            }
            .padding(Oases.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                                OasesPasteboard.copy(model.id)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .navigationTitle(OasesLocalization.localizedFormat("支持模型 · %@", file.name))
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
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || (Int(priority.trimmingCharacters(in: .whitespacesAndNewlines)) == nil && !priority.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}
