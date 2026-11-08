import Foundation
import SwiftUI

struct AuthFileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore

    let file: RuntimeAuthFile?

    @State private var fileName: String
    @State private var jsonText: String
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var didLoad = false
    @State private var errorMessage: String?

    init(file: RuntimeAuthFile?) {
        self.file = file
        _fileName = State(initialValue: file?.name ?? "auth.json")
        _jsonText = State(initialValue: file == nil ? "{\n  \n}\n" : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("文件名", text: $fileName)
                        .font(.system(.body, design: .monospaced))
                        .disabled(file != nil)
                } header: {
                    Text(file == nil ? "新建认证文件" : "认证文件")
                } footer: {
                    Text(file == nil ? "必须使用 .json 文件名；如果同名文件已存在，保存会替换它。" : "文件名由当前目标返回；保存会替换目标上的 JSON 内容。")
                }

                Section {
                    HStack {
                        Text("JSON 内容")
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
                        .disabled(isLoading || jsonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    TextEditor(text: $jsonText)
                        .font(.system(.body, design: .monospaced))
                        .textEditorStyle(.plain)
                        .frame(minHeight: 500)
                        .padding(8)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.primary.opacity(0.10), lineWidth: 1)
                        }
                } header: {
                    Text("敏感配置")
                } footer: {
                    Text("认证文件只在当前编辑会话内加载；不会写入 App 偏好设置。请确认 JSON 内含 CLIProxyAPI 支持的认证字段，保存前 App 会校验顶层对象格式。")
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
            .navigationTitle(file == nil ? "新建认证文件" : "编辑认证文件")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("保存") { save() }
                        .buttonStyle(.oasesPrimary)
                        .disabled(!isValid || isLoading || isSaving || runtimeDataStore.isSavingAuthFiles)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Text(OasesLocalization.localizedFormat("目标：%@", deploymentStore.targetTitle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let file {
                        Text(file.displayStatus)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(file.statusTint == .healthy ? Color.oasesGreen : Color.oasesOrange)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Oases.Color.surface)
            }
        }
        .frame(minWidth: 720, minHeight: 720)
        .task {
            await loadFileIfNeeded()
        }
    }

    private var isValid: Bool {
        guard deploymentStore.stage == .attached,
              !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fileName.lowercased().hasSuffix(".json"),
              !fileName.contains("/"),
              !fileName.contains("\\") else { return false }
        if file != nil && !didLoad { return false }
        return canonicalJSONData() != nil
    }

    private func loadFileIfNeeded() async {
        guard let file, !didLoad else {
            didLoad = true
            return
        }

        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await runtimeDataStore.downloadAuthFileData(file, using: deploymentStore)
            jsonText = formattedJSON(from: data) ?? String(decoding: data, as: UTF8.self)
            didLoad = true
            errorMessage = nil
        } catch {
            errorMessage = OasesLocalization.localizedFormat("读取认证文件失败：%@", error.localizedDescription)
            didLoad = true
        }
    }

    private func formatJSON() {
        guard let data = canonicalJSONData() else {
            errorMessage = "当前内容不是有效的 JSON 对象。"
            return
        }
        jsonText = formattedJSON(from: data) ?? jsonText
        errorMessage = nil
    }

    private func save() {
        guard let data = canonicalJSONData() else {
            errorMessage = "当前内容不是有效的 JSON 对象。"
            return
        }

        let trimmedName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try await runtimeDataStore.uploadAuthFile(
                    name: trimmedName,
                    data: data,
                    using: deploymentStore
                )
                dismiss()
            } catch {
                errorMessage = OasesLocalization.localizedFormat("保存认证文件失败：%@", error.localizedDescription)
            }
            isSaving = false
        }
    }

    private func canonicalJSONData() -> Data? {
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(jsonText.utf8),
            options: [.fragmentsAllowed]
        ),
        object is [String: Any],
        JSONSerialization.isValidJSONObject(object) else {
            return nil
        }

        return try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private func formattedJSON(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ),
        object is [String: Any],
        JSONSerialization.isValidJSONObject(object),
        let formatted = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return nil
        }
        return String(decoding: formatted, as: UTF8.self) + "\n"
    }
}
