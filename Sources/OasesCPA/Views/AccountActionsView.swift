import SwiftUI

struct AccountActionsView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var deploymentStore: DeploymentStore
    @EnvironmentObject private var runtimeDataStore: RuntimeDataStore

    @State private var filter: RuntimeAccountActionStatusFilter = .pending
    @State private var search = ""
    @State private var evidenceCandidate: RuntimeAccountActionCandidate?
    @State private var pendingConfirmation: AccountActionConfirmation?
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom, spacing: 16) {
                    PageHeader(section: .accountActions)
                    Spacer()
                    Button("认证文件", systemImage: "doc.badge.gearshape") {
                        store.selectSection(.authFiles)
                    }
                    .buttonStyle(.bordered)

                    StatusPill(
                        title: pendingTitle,
                        tint: runtimeDataStore.accountActionPendingCount > 0 ? .oasesOrange : .oasesGreen,
                        systemImage: runtimeDataStore.accountActionPendingCount > 0
                            ? "exclamationmark.circle"
                            : "checkmark.circle"
                    )
                }

                HStack(spacing: 10) {
                    TextField("搜索账号、认证文件、错误或 Trace", text: $search)
                        .textFieldStyle(.roundedBorder)

                    Picker("状态", selection: $filter) {
                        ForEach(RuntimeAccountActionStatusFilter.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 132)

                    Button {
                        runtimeDataStore.refreshAccountActionCandidates(
                            using: deploymentStore,
                            status: filter
                        )
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(runtimeDataStore.isLoadingAccountActions || runtimeDataStore.isSavingAccountActions)
                }
                .padding(14)
                .oasesCard(cornerRadius: 14)

                InfoBanner(
                    title: "只处理已发现的认证异常",
                    message: "候选由 CPAMP 根据请求监控中的脱敏证据生成。本页不会主动请求 Provider；“重新启用”会在确认后修改目标认证文件并把待办标记为已处理。删除认证文件请从“认证文件”页面进入现有的独立确认流程。",
                    systemImage: "checkmark.shield",
                    tint: .oasesBlue
                )

                if let error = runtimeDataStore.accountActionsErrorMessage {
                    InfoBanner(
                        title: "账号待办读取或操作失败",
                        message: error,
                        systemImage: "exclamationmark.triangle",
                        tint: .oasesOrange
                    )
                }

                candidatesContent
            }
            .padding(28)
        }
        .onAppear {
            filter = runtimeDataStore.accountActionsFilter
        }
        .task(id: taskID) {
            runtimeDataStore.refreshAccountActionCandidates(
                using: deploymentStore,
                status: filter
            )
        }
        .sheet(item: $evidenceCandidate) { candidate in
            AccountActionEvidenceSheet(candidate: candidate)
        }
        .alert(
            pendingConfirmation?.title ?? "确认操作",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            presenting: pendingConfirmation
        ) { confirmation in
            Button(LocalizedStringKey(confirmation.confirmTitle)) {
                apply(confirmation)
            }
            Button("取消", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .alert("账号待办操作失败", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionError ?? "未知错误")
        }
    }

    @ViewBuilder
    private var candidatesContent: some View {
        if !isConnected {
            InfoBanner(
                title: "连接目标环境后显示账号待办",
                message: "请先连接本机或 SSH / VPS 上的 CLIProxyAPI 与 CPAMP；待办读取依赖 CPAMP Full Mode 的管理密钥。",
                systemImage: "link.badge.plus",
                tint: .oasesOrange
            )
        } else if visibleCandidates.isEmpty, !runtimeDataStore.isLoadingAccountActions {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text(LocalizedStringKey(emptyTitle))
                    .font(.headline)
                Text(LocalizedStringKey(emptyMessage))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 190)
            .padding(20)
            .oasesCard()
        } else {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    CardTitle(
                        title: "候选账号",
                        subtitle: "\(visibleCandidates.count) 项符合当前筛选 · 数据来自 CPAMP Management API",
                        icon: "person.crop.circle.badge.exclamationmark"
                    )
                    Spacer()
                    if runtimeDataStore.isLoadingAccountActions {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                ForEach(visibleCandidates) { candidate in
                    AccountActionCandidateCard(
                        candidate: candidate,
                        isBusy: runtimeDataStore.isSavingAccountActions &&
                            runtimeDataStore.accountActionMutatingID == candidate.id,
                        onShowEvidence: {
                            evidenceCandidate = candidate
                        },
                        onRequestOperation: { operation in
                            pendingConfirmation = AccountActionConfirmation(
                                candidate: candidate,
                                operation: operation
                            )
                        },
                        onShowAuthFiles: {
                            store.selectSection(.authFiles)
                        }
                    )
                }
            }
            .padding(20)
            .oasesCard()
        }
    }

    private var taskID: String {
        [
            deploymentStore.stage.rawValue,
            deploymentStore.cpampBaseURL.absoluteString,
            filter.rawValue
        ]
        .joined(separator: "|")
    }

    private var isConnected: Bool {
        deploymentStore.stage == .attached && !deploymentStore.cpampAdminKey.isEmpty
    }

    private var pendingTitle: String {
        let count = runtimeDataStore.accountActionPendingCount
        return count == 0 ? "暂无待办" : "待处理 \(count)"
    }

    private var visibleCandidates: [RuntimeAccountActionCandidate] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return runtimeDataStore.accountActionCandidates
            .filter { query.isEmpty || $0.searchText.contains(query) }
            .sorted {
                if $0.lastSeenAtMs != $1.lastSeenAtMs {
                    return $0.lastSeenAtMs > $1.lastSeenAtMs
                }
                return $0.id > $1.id
            }
    }

    private var emptyTitle: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "当前没有\(filter.title)账号待办"
            : "没有匹配的账号待办"
    }

    private var emptyMessage: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "CPAMP 会在认证异常有足够证据时创建待办；常规网络错误和单次上游 5xx 不会直接成为待办。"
            : "可以清除搜索或切换状态筛选，查看其它候选。"
    }

    private func apply(_ confirmation: AccountActionConfirmation) {
        let activeFilter = filter
        Task {
            do {
                _ = try await runtimeDataStore.mutateAccountActionCandidate(
                    confirmation.candidate,
                    operation: confirmation.operation,
                    using: deploymentStore
                )
                runtimeDataStore.refreshAccountActionCandidates(
                    using: deploymentStore,
                    status: activeFilter
                )
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

private struct AccountActionConfirmation: Identifiable {
    let candidate: RuntimeAccountActionCandidate
    let operation: RuntimeAccountActionOperation

    var id: String { "\(candidate.id)-\(operation.rawValue)" }

    var title: String {
        switch operation {
        case .ignore: "忽略这项账号待办？"
        case .resolve: "标记这项账号待办为已处理？"
        case .enable: "重新启用该认证文件？"
        }
    }

    var confirmTitle: String {
        switch operation {
        case .ignore: "确认忽略"
        case .resolve: "确认已处理"
        case .enable: "确认重新启用"
        }
    }

    var message: String {
        let file = candidate.authFileName.isEmpty ? "该认证文件" : candidate.authFileName
        switch operation {
        case .ignore:
            return "这只会把 \(file) 的当前待办标记为已忽略，不会修改认证文件或 Provider。"
        case .resolve:
            return "这只会把 \(file) 的当前待办标记为已处理，不会修改认证文件或 Provider。"
        case .enable:
            return "CPAMP 会先核对 \(file) 的稳定身份，再在当前目标重新启用该认证文件，并将待办标记为已处理。仅在你确认该账号已恢复可用时继续。"
        }
    }
}

private struct AccountActionCandidateCard: View {
    let candidate: RuntimeAccountActionCandidate
    let isBusy: Bool
    let onShowEvidence: () -> Void
    let onRequestOperation: (RuntimeAccountActionOperation) -> Void
    let onShowAuthFiles: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: actionSymbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(actionTint)
                    .frame(width: 38, height: 38)
                    .background(actionTint.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.accountTitle)
                        .font(.headline)
                    Text(accountSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 10)

                HStack(spacing: 7) {
                    StatusPill(title: candidate.actionTitle, tint: actionTint, systemImage: actionSymbol)
                    StatusPill(title: candidate.statusTitle, tint: statusTint, systemImage: statusSymbol)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(candidate.reason.isEmpty ? "CPAMP 未提供原因摘要。" : candidate.reason)
                    .font(.callout)
                if !candidate.reasonCode.isEmpty {
                    Text("原因代码：\(candidate.reasonCode)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if !candidate.lastError.isEmpty {
                    Text(candidate.lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if !headerEvidence.isEmpty {
                    Text(headerEvidence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            HStack(alignment: .top, spacing: 22) {
                AccountActionMetadata(label: "认证文件", value: candidate.authFileName.isEmpty ? "暂无" : candidate.authFileName)
                AccountActionMetadata(label: "首次发现", value: dateText(candidate.firstSeenAtMs))
                AccountActionMetadata(label: "最近发现", value: dateText(candidate.lastSeenAtMs))
                AccountActionMetadata(label: "命中", value: candidate.hitCount.formatted())
                AccountActionMetadata(label: "自动禁用", value: autoDisableText)
            }

            if candidate.actionType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "delete" {
                Label(
                    "该候选建议删除认证文件；为避免在待办列表中误删，请进入“认证文件”页面完成独立确认。",
                    systemImage: "exclamationmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("查看证据", systemImage: "doc.text.magnifyingglass", action: onShowEvidence)
                    .buttonStyle(.bordered)
                    .disabled(isBusy)

                if candidate.isPending {
                    Button("重新启用", systemImage: "checkmark.circle") {
                        onRequestOperation(.enable)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.oasesGreen)
                    .disabled(isBusy)

                    Button("标记已处理", systemImage: "checkmark") {
                        onRequestOperation(.resolve)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)

                    Button("忽略", systemImage: "eye.slash") {
                        onRequestOperation(.ignore)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }

                Spacer()

                Button("认证文件", systemImage: "arrow.right") {
                    onShowAuthFiles()
                }
                .buttonStyle(.borderless)
                .disabled(isBusy)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }

    private var accountSubtitle: String {
        [candidate.provider, candidate.authIndex, candidate.accountIDSnapshot]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var headerEvidence: String {
        let traceID = candidate.evidenceHeaderValue(for: "headerTraceId")
        let values = [
            candidate.evidenceHeaderValue(for: "headerErrorKind"),
            candidate.evidenceHeaderValue(for: "headerErrorCode"),
            traceID.isEmpty ? "" : "Trace: \(traceID)"
        ]
        .filter { !$0.isEmpty }
        return values.joined(separator: " · ")
    }

    private var autoDisableText: String {
        if let timestamp = candidate.autoDisabledAtMs {
            return "已禁用 · \(dateText(timestamp))"
        }
        return candidate.autoDisableEligible ? "可自动禁用" : "未自动禁用"
    }

    private var actionSymbol: String {
        switch candidate.actionType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "delete": "trash"
        case "reauth": "person.badge.key"
        default: "exclamationmark.shield"
        }
    }

    private var actionTint: Color {
        switch candidate.actionType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "delete": .oasesRed
        case "reauth": .oasesOrange
        default: .oasesBlue
        }
    }

    private var statusSymbol: String {
        switch candidate.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pending": "clock"
        case "ignored": "eye.slash"
        case "resolved": "checkmark.circle"
        case "deleted": "trash"
        default: "questionmark.circle"
        }
    }

    private var statusTint: Color {
        switch candidate.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pending": .oasesOrange
        case "ignored": .secondary
        case "resolved": .oasesGreen
        case "deleted": .oasesRed
        default: .secondary
        }
    }

    private func dateText(_ timestamp: Int64) -> String {
        guard timestamp > 0 else { return "暂无" }
        return Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }
}

private struct AccountActionMetadata: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(LocalizedStringKey(label))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(minWidth: 76, alignment: .leading)
    }
}

private struct AccountActionEvidenceSheet: View {
    @Environment(\.dismiss) private var dismiss

    let candidate: RuntimeAccountActionCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("脱敏证据")
                        .font(.title2.bold())
                    Text(candidate.authFileName.isEmpty ? candidate.accountTitle : candidate.authFileName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") {
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                Text(displayedEvidence)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 460)
    }

    private var displayedEvidence: String {
        let evidence = candidate.evidenceText
        let maximumLength = 24_000
        guard evidence.count > maximumLength else { return evidence }
        return String(evidence.prefix(maximumLength)) + "\n\n… 证据过长，仅显示前 \(maximumLength.formatted()) 个字符。"
    }
}
