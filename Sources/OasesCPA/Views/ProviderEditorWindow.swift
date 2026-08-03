import AppKit
import SwiftUI

enum ProviderEditorWindowScene {
    static let id = "provider-editor"
}

struct UnsavedWindowState: Equatable {
    private(set) var isDirty = false
    private(set) var isConfirmationPresented = false

    mutating func setDirty(_ value: Bool) {
        isDirty = value
        if !value {
            isConfirmationPresented = false
        }
    }

    mutating func requestClose() -> Bool {
        guard isDirty else { return true }
        isConfirmationPresented = true
        return false
    }

    mutating func cancelClose() {
        isConfirmationPresented = false
    }

    mutating func confirmDiscardAndClose() -> Bool {
        isDirty = false
        isConfirmationPresented = false
        return true
    }
}

struct ProviderEditorWindow: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore
    @State private var closeState = UnsavedWindowState()

    var body: some View {
        Group {
            switch store.providerEditorRoute {
            case .some(.createOpenAICompatibility):
                OpenAICompatibilityEditorView(
                    provider: RuntimeOpenAICompatibility(name: "", baseURL: ""),
                    index: nil,
                    onClose: requestClose,
                    onDirtyChange: { closeState.setDirty($0) }
                )
                .id("create-openai-compatibility")

            case .some(.editOpenAICompatibility(let providerID)):
                if let index = runtimeDataStore.openAICompatibility.firstIndex(where: { $0.id == providerID }) {
                    OpenAICompatibilityEditorView(
                        provider: runtimeDataStore.openAICompatibility[index],
                        index: index,
                        onClose: requestClose,
                        onDirtyChange: { closeState.setDirty($0) }
                    )
                    .id(providerID)
                } else {
                    unavailableProviderView
                }

            case nil:
                ContentUnavailableView(
                    "请选择一个 AI 服务",
                    systemImage: "slider.horizontal.3",
                    description: Text("此窗口用于添加或编辑 AI 服务。")
                )
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .background(
            WindowCloseGuard {
                closeState.requestClose()
            }
        )
        .confirmationDialog(
            "舍弃未保存的 AI 服务配置？",
            isPresented: Binding(
                get: { closeState.isConfirmationPresented },
                set: { if !$0 { closeState.cancelClose() } }
            ),
            titleVisibility: .visible
        ) {
            Button("舍弃更改并关闭", role: .destructive) {
                guard closeState.confirmDiscardAndClose() else { return }
                closeWindow()
            }
            Button("继续编辑", role: .cancel) {
                closeState.cancelClose()
            }
        } message: {
            Text("关闭窗口会丢失尚未保存的服务地址、密钥、模型和路由设置。")
        }
    }

    private var unavailableProviderView: some View {
        ContentUnavailableView {
            Label("该 Provider 已不可用", systemImage: "exclamationmark.triangle")
        } description: {
            Text("它可能已在当前目标中被删除。请关闭此窗口后刷新列表。")
        } actions: {
            Button("关闭窗口") {
                closeWindow()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func closeWindow() {
        store.closeProviderEditor()
        dismiss()
    }

    private func requestClose() {
        guard closeState.requestClose() else { return }
        closeWindow()
    }
}

private struct WindowCloseGuard: NSViewRepresentable {
    let shouldClose: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(shouldClose: shouldClose)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.shouldClose = shouldClose
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldClose: () -> Bool
        private weak var window: NSWindow?
        private weak var previousDelegate: NSWindowDelegate?

        init(shouldClose: @escaping () -> Bool) {
            self.shouldClose = shouldClose
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            detach()
            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
        }

        func detach() {
            guard let window, window.delegate === self else { return }
            window.delegate = previousDelegate
            self.window = nil
            previousDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard shouldClose() else { return false }
            return previousDelegate?.windowShouldClose?(sender) ?? true
        }

        func windowWillClose(_ notification: Notification) {
            previousDelegate?.windowWillClose?(notification)
        }
    }
}
