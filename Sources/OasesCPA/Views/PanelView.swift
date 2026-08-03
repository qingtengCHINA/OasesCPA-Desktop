import AppKit
import SwiftUI
import WebKit

struct PanelView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @State private var reloadID = UUID()
    @State private var panelLoadState = PanelLoadState.loading

    var body: some View {
        Group {
            if deploymentStore.stage == .attached, let url = URL(string: deploymentStore.localPanelURL) {
                VStack(spacing: 0) {
                    toolbar(url: url)
                    Divider()
                    if case .failed(let message) = panelLoadState {
                        InfoBanner(
                            title: "CPAMP 面板加载失败",
                            message: message,
                            systemImage: "exclamationmark.triangle",
                            tint: .oasesRed
                        )
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                    } else if case .loading = panelLoadState {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在连接当前目标的 CPAMP 面板…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                    }
                    EmbeddedPanelView(
                        url: url,
                        apiBase: deploymentStore.cpampBaseURL.absoluteString,
                        managementKey: deploymentStore.cpampAdminKey,
                        onLoadStateChange: { state in
                            panelLoadState = state
                        }
                    )
                        .id(reloadID)
                }
        } else {
                ContentUnavailableView {
                    Label("CPAMP 面板尚未接入", systemImage: "rectangle.on.rectangle")
                } description: {
                    Text("先在“连接与部署”中完成本机或 SSH / VPS 部署，App 会自动通过回环地址或 SSH 隧道加载面板。")
                } actions: {
                    Button("前往连接与部署") {
                        store.selectSection(.environments)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func toolbar(url: URL) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CPAMP 面板")
                    .font(.headline)
                Text(url.absoluteString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusPill(
                title: panelLoadState.title,
                tint: panelLoadState.tint,
                systemImage: panelLoadState.systemImage
            )

            Button("复制管理员密钥", systemImage: "key") {
                copyAdminKey()
            }
            .disabled(deploymentStore.cpampAdminKey.isEmpty)

            Button("刷新", systemImage: "arrow.clockwise") {
                reloadPanel()
            }

            Button("浏览器打开", systemImage: "safari") {
                deploymentStore.openPanel()
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func reloadPanel() {
        panelLoadState = .loading
        reloadID = UUID()
    }

    private func copyAdminKey() {
        guard !deploymentStore.cpampAdminKey.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(deploymentStore.cpampAdminKey, forType: .string)
    }
}

enum PanelLoadState: Equatable {
    case loading
    case ready
    case failed(String)

    var title: String {
        switch self {
        case .loading: OasesLocalization.localized("连接中")
        case .ready: OasesLocalization.localized("已加载")
        case .failed: OasesLocalization.localized("无法加载")
        }
    }

    var tint: Color {
        switch self {
        case .loading: .oasesOrange
        case .ready: .oasesGreen
        case .failed: .oasesRed
        }
    }

    var systemImage: String {
        switch self {
        case .loading: "hourglass"
        case .ready: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }
}

struct EmbeddedPanelView: NSViewRepresentable {
    let url: URL
    let apiBase: String
    let managementKey: String
    let onLoadStateChange: (PanelLoadState) -> Void

    private var target: EmbeddedPanelTarget {
        EmbeddedPanelTarget(url: url, apiBase: apiBase, managementKey: managementKey)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoadStateChange: onLoadStateChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Keep the panel session scoped to this web view. The actual credential
        // remains in Keychain/App state and is injected only for this target.
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: sessionBootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.recordLoadedTarget(target)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.shouldLoad(target: target) else { return }
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.addUserScript(
            WKUserScript(
                source: sessionBootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        onLoadStateChange(.loading)
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onLoadStateChange: (PanelLoadState) -> Void
        private var loadPolicy = EmbeddedPanelLoadPolicy()

        init(onLoadStateChange: @escaping (PanelLoadState) -> Void) {
            self.onLoadStateChange = onLoadStateChange
        }

        func recordLoadedTarget(_ target: EmbeddedPanelTarget) {
            loadPolicy.recordLoadedTarget(target)
        }

        func shouldLoad(target: EmbeddedPanelTarget) -> Bool {
            loadPolicy.shouldLoad(target: target)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            onLoadStateChange(.loading)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            onLoadStateChange(.ready)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            onLoadStateChange(.failed(error.localizedDescription))
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error
        ) {
            onLoadStateChange(.failed(error.localizedDescription))
        }
    }

    private var sessionBootstrapScript: String {
        let baseLiteral = javascriptStringLiteral(apiBase)
        let keyLiteral = javascriptStringLiteral(managementKey)
        return """
        (() => {
          const apiBase = \(baseLiteral);
          const managementKey = \(keyLiteral);
          if (!apiBase || !managementKey) return;
          try {
            // Clear a previous target's persisted Zustand session in this
            // isolated store, then let CPAMP's own restoreSession flow log in.
            localStorage.removeItem('cli-proxy-auth');
            localStorage.removeItem('apiUrl');
            localStorage.removeItem('isLoggedIn');
            localStorage.setItem('apiBase', apiBase);
            localStorage.setItem('apiUrl', apiBase);
            localStorage.setItem('managementKey', managementKey);
            localStorage.setItem('isLoggedIn', 'true');
          } catch (_) {
            // The page will show its normal login screen if storage is blocked.
          }
        })();
        """
    }

    private func javascriptStringLiteral(_ value: String) -> String {
        guard
            let data = try? JSONEncoder().encode(value),
            let literal = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return literal
    }
}

struct EmbeddedPanelTarget: Equatable {
    let url: URL
    let apiBase: String
    let managementKey: String

    func withURL(_ url: URL) -> EmbeddedPanelTarget {
        EmbeddedPanelTarget(url: url, apiBase: apiBase, managementKey: managementKey)
    }

    func withAPIBase(_ apiBase: String) -> EmbeddedPanelTarget {
        EmbeddedPanelTarget(url: url, apiBase: apiBase, managementKey: managementKey)
    }

    func withManagementKey(_ managementKey: String) -> EmbeddedPanelTarget {
        EmbeddedPanelTarget(url: url, apiBase: apiBase, managementKey: managementKey)
    }
}

struct EmbeddedPanelLoadPolicy {
    private(set) var loadedTarget: EmbeddedPanelTarget?

    mutating func recordLoadedTarget(_ target: EmbeddedPanelTarget) {
        loadedTarget = target
    }

    mutating func shouldLoad(target: EmbeddedPanelTarget) -> Bool {
        guard loadedTarget != target else { return false }
        loadedTarget = target
        return true
    }
}
