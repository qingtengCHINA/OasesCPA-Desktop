import SwiftUI

/// A compact, opt-in health check for the configured upstream providers.
/// The UI intentionally exposes summaries only; response bodies, response
/// headers, API keys, auth indexes, and request headers stay out of view.
struct ProviderConnectivityCard: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore

    @State private var confirmationPresented = false
    @State private var confirmationPreview = RuntimeProviderConnectivityPreview(
        targetCount: 0,
        outboundRequestUpperBound: 0,
        skippedCount: 0
    )

    private var preview: RuntimeProviderConnectivityPreview {
        runtimeDataStore.providerConnectivityPreview()
    }

    private var completedCount: Int {
        runtimeDataStore.providerConnectivityResults.filter {
            switch $0.status {
            case .success, .failed, .skipped, .cancelled:
                true
            case .pending, .running:
                false
            }
        }.count
    }

    private var successfulCount: Int {
        runtimeDataStore.providerConnectivityResults.filter { $0.status == .success }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                CardTitle(
                    title: "上游连通性检查",
                    subtitle: "仅在确认后检查已配置的模型发现接口",
                    icon: "network.badge.shield.half.filled"
                )
                Spacer()

                if runtimeDataStore.isCheckingProviderConnectivity {
                    ProgressView()
                        .controlSize(.small)
                    Button("取消检查", systemImage: "xmark.circle") {
                        runtimeDataStore.cancelProviderConnectivityCheck()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("检查上游", systemImage: "stethoscope") {
                        confirmationPreview = preview
                        confirmationPresented = true
                    }
                    .buttonStyle(.oasesPrimary)
                    .disabled(
                        deploymentStore.stage != .attached
                            || preview.targetCount == 0
                            || runtimeDataStore.isLoadingDirectProviders
                            || runtimeDataStore.isLoadingProviders
                    )
                }
            }

            if deploymentStore.stage != .attached {
                InfoBanner(
                    title: "连接目标后再检查",
                    message: "连接本机终端或 SSH / VPS 目标后，App 才能读取该目标已配置的 Provider 并发起明确确认过的只读检查。",
                    systemImage: "link.badge.plus",
                    tint: .oasesOrange
                )
            } else if runtimeDataStore.isLoadingDirectProviders || runtimeDataStore.isLoadingProviders {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在读取当前目标的 Provider 配置…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if preview.targetCount == 0 {
                InfoBanner(
                    title: "没有可检查的上游配置",
                    message: "先添加内置上游凭证或兼容 Provider；刷新配置后就可以在这里验证连通性。",
                    systemImage: "slider.horizontal.3",
                    tint: .oasesOrange
                )
            } else if runtimeDataStore.providerConnectivityResults.isEmpty {
                readyState
            } else {
                results
            }

            if let error = runtimeDataStore.providerConnectivityErrorMessage {
                InfoBanner(
                    title: "无法开始检查",
                    message: error,
                    systemImage: "exclamationmark.triangle",
                    tint: .oasesRed
                )
            }

            InfoBanner(
                title: "检查范围与数据保护",
                message: "确认后仅对当前配置的上游发送 GET /models；Gemini 只读取首个模型列表页，Vertex 最多尝试两个候选路径。不会生成推理调用、保存或显示密钥和原始响应，也不会自动启停或改写 Provider。上游仍可能记录这类请求。",
                systemImage: "lock.shield",
                tint: .oasesBlue
            )
        }
        .padding(20)
        .oasesCard()
        .confirmationDialog(
            "开始上游连通性检查？",
            isPresented: $confirmationPresented,
            titleVisibility: .visible
        ) {
            Button("开始检查", systemImage: "stethoscope") {
                runtimeDataStore.startProviderConnectivityCheck(using: deploymentStore)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmationMessage(for: confirmationPreview))
        }
    }

    private var readyState: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark.shield")
                .font(.title2)
                .foregroundStyle(Oases.Color.textSecondary)
                .frame(width: 40, height: 40)
                .oasesIconTile()

            VStack(alignment: .leading, spacing: 5) {
                Text(OasesLocalization.localizedFormat("准备检查 %lld 个配置", preview.targetCount))
                    .font(.headline)
                Text(OasesLocalization.localized(readyStateDetail))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var readyStateDetail: String {
        if preview.outboundRequestUpperBound == 0 {
            return OasesLocalization.localized("现有配置缺少可安全使用的认证信息；开始后只会显示未发起原因。")
        }
        let skipped = preview.skippedCount > 0 ? OasesLocalization.localizedFormat("，其中 %lld 个只会给出未发起原因", preview.skippedCount) : ""
        return OasesLocalization.localizedFormat("将最多发起 %lld 次只读模型发现请求%@。", preview.outboundRequestUpperBound, skipped)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                StatusPill(
                    title: OasesLocalization.localizedFormat("%lld/%lld 已完成", completedCount, runtimeDataStore.providerConnectivityResults.count),
                    tint: runtimeDataStore.isCheckingProviderConnectivity ? .oasesBlue : .oasesGreen,
                    systemImage: runtimeDataStore.isCheckingProviderConnectivity
                        ? "arrow.triangle.2.circlepath"
                        : "checkmark.circle"
                )
                if successfulCount > 0 {
                    StatusPill(
                        title: OasesLocalization.localizedFormat("%lld 个可连接", successfulCount),
                        tint: .oasesGreen,
                        systemImage: "checkmark.seal"
                    )
                }
                Spacer()
                if let date = runtimeDataStore.providerConnectivityLastCheckedAt {
                    Text(OasesLocalization.localizedFormat("最近检查 %@", date.formatted(date: .omitted, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                ForEach(runtimeDataStore.providerConnectivityResults) { result in
                    ProviderConnectivityResultRow(result: result)
                    if result.id != runtimeDataStore.providerConnectivityResults.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 18)
            .oasesCard()
        }
    }

    private func confirmationMessage(
        for preview: RuntimeProviderConnectivityPreview
    ) -> String {
        guard preview.outboundRequestUpperBound > 0 else {
            return OasesLocalization.localizedFormat("当前 %lld 个配置都缺少可安全使用的认证信息或已被停用。开始后不会发送任何上游请求，只会显示未发起原因。", preview.targetCount)
        }
        let skipped = preview.skippedCount > 0
            ? OasesLocalization.localizedFormat("另有 %lld 个配置不会发起请求。", preview.skippedCount)
            : ""
        return OasesLocalization.localizedFormat("将为 %lld 个配置，最多发送 %lld 次 GET /models 请求。不会生成推理调用、保存或显示密钥和原始响应，也不会自动启停或改写 Provider。上游可能记录这类请求。%@", preview.outboundTargetCount, preview.outboundRequestUpperBound, skipped)
    }
}

private struct ProviderConnectivityResultRow: View {
    let result: RuntimeProviderConnectivityResult

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: result.target.systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .oasesIconTile()

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(result.target.providerTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(result.target.providerKind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("\(result.target.host) · \(result.target.endpointLabel)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(result.message)
                    .font(.caption)
                    .foregroundStyle(messageTint)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                StatusPill(
                    title: result.status.title,
                    tint: tint,
                    systemImage: statusSystemImage
                )
                HStack(spacing: 7) {
                    if let modelCount = result.modelCount {
                        Text(OasesLocalization.localizedFormat("%lld 个模型", modelCount))
                    }
                    if let statusCode = result.statusCode {
                        Text("HTTP \(statusCode)")
                    }
                    if let duration = result.durationMilliseconds {
                        Text("\(duration) ms")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 13)
    }

    private var tint: Color {
        switch result.status {
        case .success:
            .oasesGreen
        case .failed:
            .oasesRed
        case .skipped, .cancelled:
            .oasesOrange
        case .pending, .running:
            .oasesBlue
        }
    }

    private var messageTint: Color {
        switch result.status {
        case .failed:
            .oasesRed
        case .skipped, .cancelled:
            .oasesOrange
        case .pending, .running, .success:
            .secondary
        }
    }

    private var statusSystemImage: String {
        switch result.status {
        case .pending:
            "clock"
        case .running:
            "arrow.triangle.2.circlepath"
        case .success:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .skipped:
            "arrow.uturn.forward.circle"
        case .cancelled:
            "xmark.circle"
        }
    }
}
