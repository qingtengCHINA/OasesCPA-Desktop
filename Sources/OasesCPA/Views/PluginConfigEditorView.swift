import Foundation
import SwiftUI

struct PluginConfigEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore

    let plugin: RuntimePlugin

    @State private var contents = ""
    @State private var initialContents = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var didLoad = false
    @State private var showSaveConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("插件") {
                        Text(plugin.displayTitle)
                    }
                    LabeledContent("标识") {
                        Text(plugin.id)
                            .font(.system(.body, design: .monospaced))
                    }
                    if let version = plugin.metadata?.version, !version.isEmpty {
                        LabeledContent("版本") { Text(version) }
                    }
                    if let author = plugin.metadata?.author, !author.isEmpty {
                        LabeledContent("作者") { Text(author) }
                    }
                } header: {
                    Text("当前目标插件")
                } footer: {
                    Text(OasesLocalization.localizedFormat("保存会完整替换当前目标 plugins.configs.%@ 的 JSON 对象。", plugin.id))
                }

                if !plugin.configFields.isEmpty {
                    Section("插件声明的配置字段") {
                        ForEach(plugin.configFields, id: \.name) { field in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 7) {
                                    Text(field.name)
                                        .font(.system(.body, design: .monospaced).weight(.semibold))
                                    Text(field.type)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.oasesBlue)
                                }
                                if !field.enumValues.isEmpty {
                                    Text(OasesLocalization.localizedFormat("可选值：%@", field.enumValues.joined(separator: "、")))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if !field.description.isEmpty {
                                    Text(field.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }

                Section {
                    HStack {
                        Text("JSON 配置")
                            .font(.headline)
                        Spacer()
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button("格式化", systemImage: "text.alignleft") {
                            formatJSON()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isLoading || contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    TextEditor(text: $contents)
                        .font(.system(.body, design: .monospaced))
                        .textEditorStyle(.plain)
                        .frame(minHeight: 420)
                        .padding(8)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.primary.opacity(0.10), lineWidth: 1)
                        }
                } header: {
                    Text("仅当前编辑会话")
                } footer: {
                    Text("配置可能包含访问令牌或其他敏感值。内容仅在本次编辑会话内保留，不会写入 App 偏好设置或日志；保存前会校验 JSON 顶层对象。")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.oasesRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("编辑插件配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving || runtimeDataStore.isSavingPlugins)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("保存") {
                        showSaveConfirmation = true
                    }
                    .buttonStyle(.oasesPrimary)
                    .disabled(!isValid || !isDirty || isLoading || isSaving || runtimeDataStore.isSavingPlugins)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Text(OasesLocalization.localizedFormat("目标：%@", deploymentStore.targetTitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(plugin.effectiveStateTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(plugin.effectiveEnabled ? Color.oasesGreen : Color.oasesOrange)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Oases.Color.surface)
            }
        }
        .frame(minWidth: 760, minHeight: 720)
        .task(id: plugin.id) {
            await load()
        }
        .confirmationDialog(
            "保存插件配置？",
            isPresented: $showSaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("保存并应用") {
                save()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会用当前 JSON 替换目标上的插件配置。若删除原有字段，CLIProxyAPI 会按新的对象保存并重载对应配置。")
        }
    }

    private var isValid: Bool {
        didLoad &&
            deploymentStore.stage == .attached &&
            RuntimePluginConfigValidator.canonicalData(from: contents) != nil
    }

    private var isDirty: Bool {
        didLoad && contents != initialContents
    }

    private func load() async {
        guard deploymentStore.stage == .attached else {
            contents = ""
            initialContents = ""
            didLoad = false
            isLoading = false
            return
        }

        isLoading = true
        didLoad = false
        errorMessage = nil
        defer { isLoading = false }
        do {
            let data = try await runtimeDataStore.pluginConfigData(
                for: plugin,
                using: deploymentStore
            )
            guard let text = RuntimePluginConfigValidator.formattedText(from: data) else {
                throw RuntimeDataStoreError.invalidPluginConfiguration
            }
            contents = text
            initialContents = text
            didLoad = true
        } catch {
            errorMessage = OasesLocalization.localizedFormat("读取插件配置失败：%@", error.localizedDescription)
        }
    }

    private func formatJSON() {
        guard let data = RuntimePluginConfigValidator.canonicalData(from: contents),
              let text = RuntimePluginConfigValidator.formattedText(from: data) else {
            errorMessage = OasesLocalization.localized("当前内容不是有效的 JSON 对象。")
            return
        }
        contents = text
        errorMessage = nil
    }

    private func save() {
        guard RuntimePluginConfigValidator.canonicalData(from: contents) != nil else {
            errorMessage = OasesLocalization.localized("当前内容不是有效的 JSON 对象。")
            return
        }

        let contentsToSave = contents
        isSaving = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await runtimeDataStore.savePluginConfig(
                    contentsToSave,
                    for: plugin,
                    using: deploymentStore
                )
                dismiss()
            } catch {
                errorMessage = OasesLocalization.localizedFormat("保存插件配置失败：%@", error.localizedDescription)
            }
            isSaving = false
        }
    }
}
