import SwiftUI

/// One model: its providers in the engine's order (drag to reorder; a dry run comes first), the
/// last 7 days of calls, success rate and cost over every name its usage is recorded under, and
/// the newest calls. Internal `pin-x/…` names never reach this page.
struct ModelDetailView: View {
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var appStore: AppStore
    @StateObject private var store: ModelDetailStore
    @State private var providerToTest: GatewayModelProvider?

    init(modelID: String, deploymentStore: DeploymentStore) {
        _store = StateObject(wrappedValue: ModelDetailStore(
            modelID: modelID,
            provider: deploymentStore,
            cpamp: { [weak deploymentStore] in
                guard let deploymentStore else { return nil }
                return (deploymentStore.endpoints.cpampBaseURL, deploymentStore.cpampAdminKey)
            }
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Oases.Space.l) {
                header
                content
            }
            .padding(Oases.Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .oasesCanvas()
        .navigationTitle(store.modelID)
        .task(id: reloadKey) {
            if store.isActive { store.refreshNow() } else { store.activate() }
        }
        .onDisappear { store.deactivate() }
        .sheet(isPresented: Binding(get: { store.pendingPlan != nil }, set: { if !$0 { store.discardPendingPlan() } })) {
            if let plan = store.pendingPlan {
                DryRunConfirmSheet(
                    plan: plan,
                    onConfirm: { Task { await store.confirmPendingPlan() } },
                    onCancel: { store.discardPendingPlan() }
                )
            }
        }
        .confirmationDialog(
            OasesLocalization.localizedFormat("只通过 %@ 测试？", providerToTest?.name ?? ""),
            isPresented: Binding(get: { providerToTest != nil }, set: { if !$0 { providerToTest = nil } }),
            titleVisibility: .visible
        ) {
            Button("测试") {
                if let provider = providerToTest {
                    Task { await store.testProvider(provider.name) }
                }
                providerToTest = nil
            }
            Button("取消", role: .cancel) { providerToTest = nil }
        } message: {
            Text("测活会向上游发送真实请求并产生费用")
        }
    }

    private var reloadKey: String {
        "\(deploymentStore.stage.rawValue)|\(deploymentStore.gatewayAvailability)"
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Oases.Space.xs) {
                Text(store.modelID)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Oases.Color.textPrimary)
                    .textSelection(.enabled)
                Text("供应商顺序、近 7 天调用与花费")
                    .font(.callout)
                    .foregroundStyle(Oases.Color.textSecondary)
            }
            Spacer()
            if store.phase == .loading || store.isMutating {
                ProgressView().controlSize(.small)
            }
            Button("刷新", systemImage: "arrow.clockwise") { store.refreshNow() }
                .buttonStyle(.bordered)
                .disabled(store.phase == .loading || store.isMutating)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .unavailable(let availability):
            GatewayUnavailableView(availability: availability) { store.retryAuthentication() }
        case .loading:
            HStack(spacing: Oases.Space.sm) {
                ProgressView().controlSize(.small)
                Text("正在读取模型详情…")
                    .foregroundStyle(Oases.Color.textSecondary)
            }
        case .failed(let message):
            GatewayLoadFailedView(message: message) { store.refreshNow() }
        case .loaded:
            loaded
        }
    }

    @ViewBuilder
    private var loaded: some View {
        if let error = store.actionError {
            InfoBanner(title: "操作没有完成", message: error, systemImage: "exclamationmark.triangle", tint: Oases.Color.danger)
        }
        if let notice = store.appliedPlanNotice {
            VStack(alignment: .trailing, spacing: Oases.Space.xs) {
                InfoBanner(title: "应用的顺序与确认时不同", message: notice, systemImage: "exclamationmark.arrow.triangle.2.circlepath", tint: Oases.Color.warning)
                Button("知道了") { store.dismissAppliedPlanNotice() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        statistics
        providersSection
        recentCallsSection
    }

    // MARK: - Statistics

    @ViewBuilder
    private var statistics: some View {
        OasesSectionHeader(title: "近 7 天")
        if let summary = store.summary {
            HStack(spacing: Oases.Space.m) {
                statistic(title: "调用", value: summary.calls.formatted())
                statistic(title: "成功率", value: summary.successRate.map { $0.formatted(.percent.precision(.fractionLength(0...1))) } ?? "—")
                VStack(alignment: .leading, spacing: Oases.Space.xs) {
                    Text("花费")
                        .font(.caption)
                        .foregroundStyle(Oases.Color.textSecondary)
                    if summary.hasPrice {
                        Text(summary.totalCost.formatted(.currency(code: "USD").precision(.fractionLength(2...4))))
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Oases.Color.textPrimary)
                    } else {
                        Text("未配置价格")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Oases.Color.warningText)
                        Button("前往成本与价格") { appStore.selectSection(.modelPrices) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                .padding(Oases.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .oasesCard()
            }
        } else if let error = store.statisticsError {
            InfoBanner(title: "无法读取调用统计", message: error, systemImage: "chart.bar.xaxis", tint: Oases.Color.warning)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func statistic(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Oases.Space.xs) {
            Text(LocalizedStringKey(title))
                .font(.caption)
                .foregroundStyle(Oases.Color.textSecondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(Oases.Color.textPrimary)
        }
        .padding(Oases.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .oasesCard()
    }

    // MARK: - Providers

    @ViewBuilder
    private var providersSection: some View {
        OasesSectionHeader(title: "供应商顺序", trailing: store.isReordering ? "正在检查新顺序…" : nil)
        if store.providers.isEmpty {
            OasesEmptyState(systemImage: "server.rack", title: "没有供应商提供这个模型", message: "在“AI 提供商”里添加提供它的供应商后，这里会列出它们。")
        } else {
            ReorderableProviderList(
                providers: store.providers,
                isDisabled: store.isReordering || store.isMutating || store.pendingPlan != nil,
                testResults: store.providerTests,
                onReorder: { order in Task { await store.proposeOrder(order) } },
                onTest: { providerToTest = $0 }
            )
            Text("拖动调整顺序；先预演，只有会同时改变其他模型时才需要确认。登录账号的位置固定。")
                .font(.caption)
                .foregroundStyle(Oases.Color.textTertiary)
        }
    }

    // MARK: - Recent calls

    @ViewBuilder
    private var recentCallsSection: some View {
        OasesSectionHeader(title: "最近调用")
        if store.summary == nil && store.statisticsError != nil {
            EmptyView()
        } else if store.recentCalls.isEmpty {
            OasesEmptyState(systemImage: "clock", title: "近 7 天没有调用")
        } else {
            OasesRowGroup {
                ForEach(store.recentCalls) { event in
                    HStack(spacing: Oases.Space.m) {
                        StatusDot(tone: event.failed ? .danger : .success, size: 8)
                        Text(Date(timeIntervalSince1970: TimeInterval(event.timestampMs) / 1_000).formatted(date: .abbreviated, time: .standard))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Oases.Color.textSecondary)
                            .frame(width: 170, alignment: .leading)
                        Text(event.displayModel)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(Oases.Color.textPrimary)
                            .lineLimit(1)
                        if event.failed {
                            Text(SecretRedactor.redact(event.displayFailSummary, secrets: []))
                                .font(.caption)
                                .foregroundStyle(Oases.Color.dangerText)
                                .lineLimit(1)
                        }
                        Spacer(minLength: Oases.Space.sm)
                        Text(OasesLocalization.localizedFormat("%lld Token", event.totalTokens))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Oases.Color.textSecondary)
                        if let latency = event.latencyMs {
                            Text("\(latency) ms")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Oases.Color.textSecondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, Oases.Space.md)
                    .padding(.vertical, Oases.Space.sm)
                }
            }
        }
    }
}
