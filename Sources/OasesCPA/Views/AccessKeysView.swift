import AppKit
import SwiftUI

/// The API key page: the gateway's call address and the policy-managed client keys.
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
        ScrollView {
            GatewayKeysView(store: store)
                .padding(Oases.Space.page)
        }
        .oasesCanvas()
        .task(id: reloadKey) {
            if store.isActive { store.refreshNow() } else { store.activate() }
        }
        .onDisappear { store.deactivate() }
    }

    private var reloadKey: String {
        "\(deploymentStore.stage.rawValue)|\(deploymentStore.gatewayAvailability)"
    }
}

struct GatewayEndpointCard: View {
    let baseURL: String
    let targetKind: DeploymentTargetKind
    let onCopy: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(
                title: "网关调用地址",
                subtitle: targetKind == .ssh
                    ? "当前显示的是 Oases CPA 建立的本机 SSH 隧道地址"
                    : "客户端调用 Oases 网关的地址（OpenAI 兼容）",
                icon: "link"
            )

            HStack(spacing: 10) {
                Text(baseURL)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Button("复制", systemImage: "doc.on.doc") {
                    onCopy(baseURL)
                }
                .buttonStyle(.bordered)
                Spacer()
            }

            Divider()

            Text("模型目录：GET /v1/models   ·   兼容调用：POST /v1/chat/completions")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            if targetKind == .ssh {
                Text("如需让外部客户端访问 VPS，请在 VPS 上自行配置反向代理、防火墙和 TLS；这里的 127.0.0.1 地址只供本机 App 与本机客户端使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .oasesCard()
    }
}

/// The dashboard's summary of the call address, the client keys and the model directory, read
/// through its own `GatewayKeysStore` (refreshed with the dashboard's ⌘R).
struct GatewayAccessSummaryCard: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @StateObject private var keys: GatewayKeysStore
    @State private var copiedMessage: String?

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
        VStack(alignment: .leading, spacing: Oases.Space.md) {
            HStack {
                CardTitle(
                    title: "调用接入",
                    subtitle: "当前网关 Base URL、调用 Key 与模型目录",
                    icon: "key.horizontal"
                )
                Spacer()
                if keys.phase == .loading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("管理", systemImage: "arrow.right") {
                    store.selectSection(.accessKeys)
                }
                .buttonStyle(.bordered)
            }

            if deploymentStore.stage != .attached {
                Text("连接目标环境后显示调用地址、已创建 API Key 和可用模型 ID。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 118, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: Oases.Space.s) {
                    Text("Base URL")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: Oases.Space.sm) {
                        Text(deploymentStore.endpoints.clientAPIBaseURL.absoluteString)
                            .font(.system(.caption, design: .monospaced).weight(.medium))
                            .lineLimit(1)
                            .textSelection(.enabled)
                        Button {
                            copy(deploymentStore.endpoints.clientAPIBaseURL.absoluteString, message: OasesLocalization.localized("Base URL 已复制"))
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help(OasesLocalization.localized("复制 Base URL"))
                    }
                }

                Divider()
                summary
            }
        }
        .padding(Oases.Space.l)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .oasesCard()
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
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(Oases.Color.dangerText)
                .lineLimit(2)
        case .loading:
            Text("正在读取调用 Key 与模型…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .loaded:
            HStack(spacing: Oases.Space.m) {
                StatusPill(
                    title: OasesLocalization.localizedFormat("%lld 个调用 Key", keys.rows.count),
                    tint: keys.rows.isEmpty ? Oases.Color.neutral : Oases.Color.success,
                    systemImage: "key"
                )
                StatusPill(
                    title: OasesLocalization.localizedFormat("%lld 个模型", models.count),
                    tint: models.isEmpty ? Oases.Color.warning : Oases.Color.accent,
                    systemImage: "cpu"
                )
                if let copiedMessage {
                    Text(copiedMessage)
                        .font(.caption2)
                        .foregroundStyle(Oases.Color.successText)
                }
            }

            if let first = keys.rows.first {
                Text(keys.rows.count > 1
                     ? OasesLocalization.localizedFormat("Key：%@ · 另 %lld 个", first.maskedKey, keys.rows.count - 1)
                     : OasesLocalization.localizedFormat("Key：%@", first.maskedKey))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("还没有调用 Key（网关内部使用的引擎 Key 不在这里显示）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if models.isEmpty {
                Text("网关还没有可用模型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: Oases.Space.s) {
                    ForEach(Array(models.prefix(8)), id: \.self) { model in
                        Text(model)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                            .padding(.horizontal, Oases.Space.sm)
                            .padding(.vertical, Oases.Space.xs)
                            .background(Oases.Color.wash, in: Capsule())
                    }
                }
                if models.count > 8 {
                    Text(OasesLocalization.localizedFormat("另有 %lld 个模型，可在“模型列表”查看。", models.count - 8))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    static func unavailableText(_ availability: GatewayAvailability) -> String {
        switch availability {
        case .notAttached: OasesLocalization.localized("连接目标后使用网关功能")
        case .needsUpgrade: OasesLocalization.localized("需要升级到完整版")
        case .dockerUnsupported: OasesLocalization.localized("Oases 网关只支持原生部署")
        case .credentialsRejected: OasesLocalization.localized("管理密钥被拒绝，请重新验证")
        case .ready: ""
        }
    }

    private func copy(_ value: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedMessage = message
    }
}

/// Wraps its subviews into lines (chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + (x > 0 ? spacing : 0)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
