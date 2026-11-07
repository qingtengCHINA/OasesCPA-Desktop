import SwiftUI

struct CPAQuickConfigurationView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @StateObject private var store: CPAQuickConfigStore

    private let embeddedMode: Bool
    private let onDirtyChange: ((Bool) -> Void)?
    @State private var isShowingRiskConfirmation = false

    init(
        embedded: Bool = false,
        onDirtyChange: ((Bool) -> Void)? = nil,
        store: CPAQuickConfigStore? = nil
    ) {
        embeddedMode = embedded
        self.onDirtyChange = onDirtyChange
        _store = StateObject(wrappedValue: store ?? CPAQuickConfigStore())
    }

    var body: some View {
        Group {
            if embeddedMode {
                workbench
            } else {
                ScrollView {
                    workbench
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: contextID) {
            await loadIfPossible()
        }
        .onChange(of: store.isDirty) { _, value in
            onDirtyChange?(value)
        }
        .confirmationDialog(
            "确认应用高级设置？",
            isPresented: $isShowingRiskConfirmation,
            titleVisibility: .visible
        ) {
            Button("保存并应用") {
                save()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这些修改可能影响远程访问、代理连接或客户端兼容性。Provider、API Key 和登录凭证仍请在各自的专用页面管理。")
        }
    }

    private var workbench: some View {
        VStack(alignment: .leading, spacing: 22) {
            if !embeddedMode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CLIProxyAPI 快速配置")
                        .font(.largeTitle.weight(.bold))
                    Text("面向日常使用的常用开关。复杂的完整配置仍可在配置面板中编辑。")
                        .foregroundStyle(.secondary)
                }
            }

            contextCard

            if !store.fieldErrors.isEmpty {
                partialErrorCard
            }

            ForEach(RuntimeCPAQuickConfigGroup.allCases, id: \.self) { group in
                configGroup(group)
            }

            footerCard
        }
        .padding(embeddedMode ? 0 : 28)
        .frame(maxWidth: 1_080, alignment: .leading)
    }

    private var contextID: String {
        "\(deploymentStore.stage.rawValue)|\(deploymentStore.cpaBaseURL.absoluteString)|\(deploymentStore.managementKey)"
    }

    private var contextCard: some View {
        HStack(spacing: 12) {
            Image(systemName: deploymentStore.stage == .attached ? "checkmark.circle.fill" : "link")
                .font(.title2)
                .foregroundStyle(deploymentStore.stage == .attached ? Color.oasesGreen : Color.oasesOrange)

            VStack(alignment: .leading, spacing: 3) {
                Text(OasesLocalization.localized(
                    deploymentStore.stage == .attached ? "已连接到当前目标" : "先连接一个目标"
                ))
                    .font(.headline)
                Text(OasesLocalization.localized(
                    deploymentStore.stage == .attached
                        ? "快速设置会直接保存到 CLIProxyAPI，不会写入 App 偏好设置。"
                        : "完成本机部署或 SSH 连接后，这里会自动读取可用设置。"
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if deploymentStore.stage == .attached {
                Button("重新读取", systemImage: "arrow.clockwise") {
                    Task { await loadIfPossible(force: true) }
                }
                .buttonStyle(.bordered)
                .disabled(store.isSaving)
            }
        }
        .padding(16)
        .oasesCard(cornerRadius: 14)
    }

    private var partialErrorCard: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("有 \(store.fieldErrors.count) 项设置读取失败")
                    .font(.headline)
                Text("这通常表示目标版本暂不支持该端点；其他设置仍然可以保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.oasesOrange)
        }
        .padding(16)
        .oasesCard(cornerRadius: 14)
    }

    private func configGroup(_ group: RuntimeCPAQuickConfigGroup) -> some View {
        let fields = RuntimeCPAQuickConfigField.allCases.filter { $0.group == group }
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.title)
                    .font(.title3.weight(.semibold))
                Text(group.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(fields, id: \.self) { field in
                    configRow(field)
                    if field != fields.last {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 16)
            .oasesCard(cornerRadius: 14)
        }
    }

    @ViewBuilder
    private func configRow(_ field: RuntimeCPAQuickConfigField) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                configRowDescription(field)
                Spacer(minLength: 12)
                control(for: field)
            }
            VStack(alignment: .leading, spacing: 10) {
                configRowDescription(field)
                control(for: field)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.vertical, 13)
    }

    private func configRowDescription(_ field: RuntimeCPAQuickConfigField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Text(field.title)
                    .font(.body.weight(.medium))
                if store.changedFields.contains(field) {
                    Text("未保存")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.oasesOrange)
                }
            }
            Text(field.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = store.fieldErrors[field] {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Color.oasesRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func control(for field: RuntimeCPAQuickConfigField) -> some View {
        switch field.valueKind {
        case .bool:
            Toggle(
                "",
                isOn: Binding(
                    get: {
                        if case .bool(let value) = store.draft[field] { return value }
                        return false
                    },
                    set: { store.setValue(.bool($0), for: field) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .disabled(!store.isLoaded || store.isSaving || deploymentStore.stage != .attached)
        case .integer:
            Stepper(
                value: Binding(
                    get: {
                        if case .integer(let value) = store.draft[field] { return value }
                        return 0
                    },
                    set: { store.setValue(.integer($0), for: field) }
                ),
                in: 0...10_000
            ) {
                Text(integerValue(for: field).formatted())
                    .monospacedDigit()
                    .frame(minWidth: 52, alignment: .trailing)
            }
            .disabled(!store.isLoaded || store.isSaving || deploymentStore.stage != .attached)
        case .string:
            if field == .routingStrategy {
                Picker("", selection: Binding(
                    get: { stringValue(for: field) },
                    set: { store.setValue(.string($0), for: field) }
                )) {
                    Text("轮询（推荐）").tag("round-robin")
                    Text("加权轮询").tag("weighted-round-robin")
                    Text("优先填充").tag("fill-first")
                }
                .labelsHidden()
                .frame(width: 190)
                .disabled(!store.isLoaded || store.isSaving || deploymentStore.stage != .attached)
            } else {
                TextField("留空表示不使用", text: Binding(
                    get: { stringValue(for: field) },
                    set: { store.setValue(.string($0), for: field) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)
                .disabled(!store.isLoaded || store.isSaving || deploymentStore.stage != .attached)
            }
        }
    }

    private var footerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Provider、调用 API Key 和 OAuth 登录凭证，请分别前往“AI 提供商”“调用 API Key”和“OAuth 登录”页面管理。", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if store.isDirty {
                    Button("放弃修改") {
                        store.discardChanges()
                    }
                    .disabled(store.isSaving)
                }

                Spacer()

                if store.isSaving {
                    ProgressView("保存中…")
                        .controlSize(.small)
                }

                Button("保存设置", systemImage: "checkmark") {
                    if store.changedRiskyFields.isEmpty {
                        save()
                    } else {
                        isShowingRiskConfirmation = true
                    }
                }
                .buttonStyle(.oasesPrimary)
                .disabled(!store.isDirty || store.isSaving || deploymentStore.stage != .attached)
            }
        }
        .padding(16)
        .oasesCard(cornerRadius: 14)
    }

    private func integerValue(for field: RuntimeCPAQuickConfigField) -> Int {
        if case .integer(let value) = store.draft[field] { return value }
        return 0
    }

    private func stringValue(for field: RuntimeCPAQuickConfigField) -> String {
        if case .string(let value) = store.draft[field] { return value }
        return ""
    }

    private func loadIfPossible(force: Bool = false) async {
        guard deploymentStore.stage == .attached,
              !deploymentStore.managementKey.isEmpty else { return }
        if force || !store.isLoaded {
            await store.load(
                baseURL: deploymentStore.cpaBaseURL,
                managementKey: deploymentStore.managementKey
            )
        }
    }

    private func save() {
        guard deploymentStore.stage == .attached else { return }
        Task {
            await store.save(
                baseURL: deploymentStore.cpaBaseURL,
                managementKey: deploymentStore.managementKey
            )
        }
    }
}
