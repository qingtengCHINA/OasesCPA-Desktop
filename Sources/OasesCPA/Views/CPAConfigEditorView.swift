import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct CPAConfigEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore

    @State private var contents = ""
    @State private var isDirty = false
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showSaveConfirmation = false
    @State private var importingFile = false
    @State private var exportingFile = false
    @State private var exportDocument = RuntimeCPAConfigDocument()
    @State private var exportFileName = "config.yaml"
    @State private var hasLoaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Label("当前目标：\(deploymentStore.targetTitle)", systemImage: "server.rack")
                        Spacer()
                        if isLoading || runtimeDataStore.isLoadingCPAConfig {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                } header: {
                    Text("CLIProxyAPI 配置")
                } footer: {
                    Text("内容来自当前目标的 /v0/management/config.yaml；不会写入 App 偏好设置。导入或编辑后，保存会直接替换目标配置并触发 CLIProxyAPI 重新加载。")
                }

                Section {
                    TextEditor(text: $contents)
                        .font(.system(.body, design: .monospaced))
                        .textEditorStyle(.plain)
                        .frame(minHeight: 570)
                        .padding(10)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(.primary.opacity(0.10), lineWidth: 1)
                        }
                } header: {
                    HStack {
                        Text("config.yaml")
                            .font(.headline)
                        Spacer()
                        Text("原始 YAML")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("建议先导出备份再修改。管理密钥、监听端口、代理地址和 Provider 配置都可能影响连接；CLIProxyAPI 服务端会在保存时做 YAML 与配置校验。")
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
            .navigationTitle("CLIProxyAPI config.yaml")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(runtimeDataStore.isSavingCPAConfig)
                }
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button("导入", systemImage: "square.and.arrow.down") {
                        importingFile = true
                    }
                    .disabled(runtimeDataStore.isSavingCPAConfig)
                    Button("导出", systemImage: "square.and.arrow.up") {
                        exportDocument = RuntimeCPAConfigDocument(data: Data(contents.utf8))
                        exportingFile = true
                    }
                    .disabled(contents.isEmpty || runtimeDataStore.isSavingCPAConfig)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("保存") {
                        showSaveConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid || !isDirty || isLoading || runtimeDataStore.isSavingCPAConfig)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 760)
        .task(id: deploymentStore.stage) {
            load()
        }
        .onChange(of: runtimeDataStore.cpaConfigYAML) { _, value in
            guard !isDirty, let value else { return }
            contents = value
            hasLoaded = true
            isLoading = false
        }
        .onChange(of: runtimeDataStore.cpaConfigErrorMessage) { _, error in
            guard let error else { return }
            errorMessage = error
            isLoading = false
        }
        .onChange(of: contents) { _, value in
            guard hasLoaded else { return }
            isDirty = value != runtimeDataStore.cpaConfigYAML
        }
        .confirmationDialog(
            "保存 CLIProxyAPI 配置？",
            isPresented: $showSaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("保存并应用") {
                save()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会直接替换当前目标的 config.yaml。错误配置可能导致 CLIProxyAPI 无法启动；建议先导出一份备份。")
        }
        .fileImporter(
            isPresented: $importingFile,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .fileExporter(
            isPresented: $exportingFile,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: exportFileName
        ) { result in
            if case .failure(let error) = result {
                errorMessage = "导出 config.yaml 失败：\(error.localizedDescription)"
            }
        }
    }

    private var isValid: Bool {
        deploymentStore.stage == .attached &&
            !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func load() {
        guard deploymentStore.stage == .attached else {
            contents = ""
            hasLoaded = false
            isLoading = false
            isDirty = false
            return
        }

        if let value = runtimeDataStore.cpaConfigYAML, !isDirty {
            contents = value
            hasLoaded = true
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil
        hasLoaded = false
        runtimeDataStore.refreshCPAConfig(using: deploymentStore)
    }

    private func save() {
        guard isValid else { return }
        let contentsToSave = contents
        errorMessage = nil
        Task { @MainActor in
            do {
                try await runtimeDataStore.saveCPAConfig(
                    contentsToSave,
                    using: deploymentStore
                )
                isDirty = false
                dismiss()
            } catch {
                errorMessage = "保存 config.yaml 失败：\(error.localizedDescription)"
            }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorMessage = "导入 config.yaml 失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                let imported = String(decoding: data, as: UTF8.self)
                guard !imported.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                contents = imported
                exportFileName = url.lastPathComponent.isEmpty ? "config.yaml" : url.lastPathComponent
                hasLoaded = true
                isDirty = true
                errorMessage = nil
            } catch {
                errorMessage = "导入 config.yaml 失败：\(error.localizedDescription)"
            }
        }
    }
}
