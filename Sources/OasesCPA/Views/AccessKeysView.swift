import AppKit
import SwiftUI

/// The API key page: the gateway's call address (the hero) and the policy-managed client keys.
struct AccessKeysView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @StateObject private var store: GatewayKeysStore

    init(deploymentStore: DeploymentStore) {
        _store = StateObject(wrappedValue: GatewayKeysStore(
            provider: deploymentStore,
            packEngineKeyFingerprint: { [weak deploymentStore] in deploymentStore?.packEngineKeyFingerprint }
        ))
    }

    var body: some View {
        GatewayKeysView(store: store)
            .task(id: reloadKey) {
                if store.isActive { store.refreshNow() } else { store.activate() }
            }
            .onDisappear { store.deactivate() }
    }

    private var reloadKey: String {
        "\(deploymentStore.stage.rawValue)|\(deploymentStore.gatewayAvailability)"
    }
}

/// The call address as the page's hero: monospaced, selectable, with a copy button whose title
/// turns into "已复制" for a moment.
struct GatewayEndpointHero: View {
    let baseURL: String
    let targetKind: DeploymentTargetKind
    /// False before a target is attached: the address is shown dimmed, nothing to copy yet.
    var isAvailable = true

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.sm) {
            Text("API 接入地址")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .firstTextBaseline, spacing: Oases.Space.m) {
                Text(baseURL)
                    .font(.title3.monospaced())
                    .foregroundStyle(isAvailable ? Oases.Color.textPrimary : Oases.Color.textTertiary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(OasesLocalization.localizedFormat("接入地址 %@", baseURL))
                CopyButton(value: baseURL, accessibilityName: OasesLocalization.localized("API 接入地址"))
                    .disabled(!isAvailable)
                Spacer(minLength: 0)
            }
            Text("OpenAI 兼容 · GET /v1/models · POST /v1/chat/completions")
                .font(.caption)
                .foregroundStyle(Oases.Color.textSecondary)
            if targetKind == .ssh {
                Text("这是 App 建立的本机 SSH 隧道地址，只供这台 Mac 上的客户端使用。")
                    .font(.caption)
                    .foregroundStyle(Oases.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "复制" that becomes "已复制" for 1.5 seconds (a text swap, no motion). Secrets go through
/// `OasesPasteboard.copySecret`, which marks them concealed for clipboard managers.
struct CopyButton: View {
    let value: String
    /// What is copied, for VoiceOver ("复制接入地址").
    var accessibilityName: String
    var isSecret = false
    @State private var copied = false

    var body: some View {
        Button {
            if isSecret { OasesPasteboard.copySecret(value) } else { OasesPasteboard.copy(value) }
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Text(copied ? "已复制" : "复制")
                .frame(minWidth: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(OasesLocalization.localizedFormat("复制%@", accessibilityName))
    }
}

/// The dashboard's summary of the call address, the client keys and the model directory, read
/// through its own `GatewayKeysStore` (refreshed with the dashboard's ⌘R).
struct GatewayAccessSummaryCard: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @StateObject private var keys: GatewayKeysStore

    init(deploymentStore: DeploymentStore) {
        _keys = StateObject(wrappedValue: GatewayKeysStore(
            provider: deploymentStore,
            packEngineKeyFingerprint: { [weak deploymentStore] in deploymentStore?.packEngineKeyFingerprint },
            section: .dashboard
        ))
    }

    private var models: [String] {
        ModelMultiPicker.options(from: keys.groupedModels)
            .flatMap(\.models)
            .reduce(into: [String]()) { result, model in
                if !result.contains(model) { result.append(model) }
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.m) {
            OasesSectionHeader(title: "调用接入", onOpen: { store.selectSection(.accessKeys) })

            if deploymentStore.stage != .attached {
                Text("连接目标环境后显示调用地址、已创建 API Key 和可用模型 ID。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Oases.Space.sm) {
                    Text(deploymentStore.endpoints.clientAPIBaseURL.absoluteString)
                        .font(.body.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    CopyButton(
                        value: deploymentStore.endpoints.clientAPIBaseURL.absoluteString,
                        accessibilityName: OasesLocalization.localized("API 接入地址")
                    )
                    .controlSize(.small)
                    if keys.phase == .loading {
                        ProgressView().controlSize(.small)
                    }
                }
                summary
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: "\(deploymentStore.stage.rawValue)|\(deploymentStore.gatewayAvailability)") {
            if keys.isActive { keys.refreshNow() } else { keys.activate() }
        }
        .onDisappear { keys.deactivate() }
    }

    @ViewBuilder
    private var summary: some View {
        switch keys.phase {
        case .unavailable(let availability):
            Text(Self.unavailableText(availability))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(Oases.Color.textSecondary)
                .symbolRenderingMode(.multicolor)
                .lineLimit(2)
        case .loading:
            Text("正在读取调用 Key 与模型…")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .loaded:
            Text(OasesLocalization.localizedFormat("%lld 个调用 Key · %lld 个模型", keys.rows.count, models.count))
                .font(.callout.monospacedDigit())
                .foregroundStyle(Oases.Color.textSecondary)
            if models.isEmpty {
                Text("网关还没有可用模型")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(models.prefix(6).joined(separator: "  ·  ") + (models.count > 6 ? "  …" : ""))
                    .font(.caption.monospaced())
                    .foregroundStyle(Oases.Color.textSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    static func unavailableText(_ availability: GatewayAvailability) -> String {
        switch availability {
        case .notAttached: OasesLocalization.localized("连接目标后使用网关功能")
        case .needsUpgrade: OasesLocalization.localized("这是旧版 0.1.x 部署，网关功能需要升级。")
        case .dockerUnsupported: OasesLocalization.localized("Oases 网关只支持原生部署")
        case .credentialsRejected: OasesLocalization.localized("管理密钥被拒绝，请重新验证")
        case .ready: ""
        }
    }
}
