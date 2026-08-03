import Foundation

struct RuntimeCodexInspectionRunsResponse: Decodable, Equatable {
    let items: [RuntimeCodexInspectionRun]

    init(items: [RuntimeCodexInspectionRun] = []) {
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = (try container.decodeIfPresent([RuntimeCodexInspectionRun].self, forKey: .items) ?? [])
            .filter { $0.id > 0 }
    }
}

struct RuntimeCodexInspectionRun: Codable, Equatable, Identifiable {
    let id: Int64
    let triggerType: String
    let triggerKey: String
    let status: String
    let startedAtMs: Int64
    let finishedAtMs: Int64?
    let totalFiles: Int
    let probeSetCount: Int
    let sampledCount: Int
    let disabledCount: Int
    let enabledCount: Int
    let deleteCount: Int
    let disableCount: Int
    let enableCount: Int
    let reauthCount: Int
    let keepCount: Int
    let error: String
    let settings: RuntimeCodexInspectionConfig?
    let createdAtMs: Int64
    let updatedAtMs: Int64
    let active: Bool
    let cancellable: Bool

    init(
        id: Int64,
        triggerType: String = "",
        triggerKey: String = "",
        status: String = "",
        startedAtMs: Int64 = 0,
        finishedAtMs: Int64? = nil,
        totalFiles: Int = 0,
        probeSetCount: Int = 0,
        sampledCount: Int = 0,
        disabledCount: Int = 0,
        enabledCount: Int = 0,
        deleteCount: Int = 0,
        disableCount: Int = 0,
        enableCount: Int = 0,
        reauthCount: Int = 0,
        keepCount: Int = 0,
        error: String = "",
        settings: RuntimeCodexInspectionConfig? = nil,
        createdAtMs: Int64 = 0,
        updatedAtMs: Int64 = 0,
        active: Bool = false,
        cancellable: Bool = false
    ) {
        self.id = id
        self.triggerType = triggerType
        self.triggerKey = triggerKey
        self.status = status
        self.startedAtMs = startedAtMs
        self.finishedAtMs = finishedAtMs
        self.totalFiles = totalFiles
        self.probeSetCount = probeSetCount
        self.sampledCount = sampledCount
        self.disabledCount = disabledCount
        self.enabledCount = enabledCount
        self.deleteCount = deleteCount
        self.disableCount = disableCount
        self.enableCount = enableCount
        self.reauthCount = reauthCount
        self.keepCount = keepCount
        self.error = error
        self.settings = settings
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.active = active
        self.cancellable = cancellable
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case triggerType
        case triggerKey
        case status
        case startedAtMs
        case finishedAtMs
        case totalFiles
        case probeSetCount
        case sampledCount
        case disabledCount
        case enabledCount
        case deleteCount
        case disableCount
        case enableCount
        case reauthCount
        case keepCount
        case error
        case settings
        case createdAtMs
        case updatedAtMs
        case active
        case cancellable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        triggerType = try container.decodeIfPresent(String.self, forKey: .triggerType) ?? ""
        triggerKey = try container.decodeIfPresent(String.self, forKey: .triggerKey) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        startedAtMs = try container.decodeIfPresent(Int64.self, forKey: .startedAtMs) ?? 0
        finishedAtMs = try container.decodeIfPresent(Int64.self, forKey: .finishedAtMs)
        totalFiles = try container.decodeIfPresent(Int.self, forKey: .totalFiles) ?? 0
        probeSetCount = try container.decodeIfPresent(Int.self, forKey: .probeSetCount) ?? 0
        sampledCount = try container.decodeIfPresent(Int.self, forKey: .sampledCount) ?? 0
        disabledCount = try container.decodeIfPresent(Int.self, forKey: .disabledCount) ?? 0
        enabledCount = try container.decodeIfPresent(Int.self, forKey: .enabledCount) ?? 0
        deleteCount = try container.decodeIfPresent(Int.self, forKey: .deleteCount) ?? 0
        disableCount = try container.decodeIfPresent(Int.self, forKey: .disableCount) ?? 0
        enableCount = try container.decodeIfPresent(Int.self, forKey: .enableCount) ?? 0
        reauthCount = try container.decodeIfPresent(Int.self, forKey: .reauthCount) ?? 0
        keepCount = try container.decodeIfPresent(Int.self, forKey: .keepCount) ?? 0
        error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
        settings = try container.decodeIfPresent(RuntimeCodexInspectionConfig.self, forKey: .settings)
        createdAtMs = try container.decodeIfPresent(Int64.self, forKey: .createdAtMs) ?? 0
        updatedAtMs = try container.decodeIfPresent(Int64.self, forKey: .updatedAtMs) ?? 0
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
        cancellable = try container.decodeIfPresent(Bool.self, forKey: .cancellable) ?? false
    }

    var normalizedStatus: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var statusTitle: String {
        switch normalizedStatus {
        case "running": OasesLocalization.localized("运行中")
        case "completed": OasesLocalization.localized("已完成")
        case "failed": OasesLocalization.localized("失败")
        case "cancelling": OasesLocalization.localized("正在取消")
        case "cancelled": OasesLocalization.localized("已取消")
        case "interrupted": OasesLocalization.localized("已中断")
        case "": OasesLocalization.localized("状态未知")
        default: status
        }
    }

    var triggerTitle: String {
        switch triggerType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "manual": OasesLocalization.localized("手动启动")
        case "scheduled": OasesLocalization.localized("定时启动")
        case "": OasesLocalization.localized("未知来源")
        default: triggerType
        }
    }

    var isActive: Bool {
        active && (normalizedStatus == "running" || normalizedStatus == "cancelling")
    }

    var isCancellable: Bool {
        guard isActive else { return false }
        return normalizedStatus == "cancelling" || cancellable
    }

    var isTerminal: Bool {
        ["completed", "failed", "cancelled", "interrupted"].contains(normalizedStatus)
    }

    var startedAt: Date? {
        startedAtMs > 0 ? Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1_000) : nil
    }

    var finishedAt: Date? {
        guard let finishedAtMs, finishedAtMs > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(finishedAtMs) / 1_000)
    }

    var actionCount: Int {
        deleteCount + disableCount + enableCount + reauthCount
    }
}

struct RuntimeCodexInspectionQuotaWindow: Codable, Equatable, Identifiable {
    let id: String
    let labelKey: String
    let labelParams: [String: RuntimeJSONValue]
    let usedPercent: Double?
    let resetLabel: String
    let limitWindowSeconds: Double?

    init(
        id: String = "",
        labelKey: String = "",
        labelParams: [String: RuntimeJSONValue] = [:],
        usedPercent: Double? = nil,
        resetLabel: String = "",
        limitWindowSeconds: Double? = nil
    ) {
        self.id = id
        self.labelKey = labelKey
        self.labelParams = labelParams
        self.usedPercent = usedPercent
        self.resetLabel = resetLabel
        self.limitWindowSeconds = limitWindowSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case labelKey
        case labelParams
        case usedPercent
        case resetLabel
        case limitWindowSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        labelKey = try container.decodeIfPresent(String.self, forKey: .labelKey) ?? ""
        labelParams = try container.decodeIfPresent([String: RuntimeJSONValue].self, forKey: .labelParams) ?? [:]
        usedPercent = try container.decodeIfPresent(Double.self, forKey: .usedPercent)
        resetLabel = try container.decodeIfPresent(String.self, forKey: .resetLabel) ?? ""
        limitWindowSeconds = try container.decodeIfPresent(Double.self, forKey: .limitWindowSeconds)
    }

    var title: String {
        let name = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            return name.replacingOccurrences(of: "-", with: " ").capitalized
        }
        let key = labelKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? OasesLocalization.localized("配额窗口") : key
    }

    var progress: Double? {
        guard let usedPercent else { return nil }
        return min(max(usedPercent / 100, 0), 1)
    }
}

struct RuntimeCodexInspectionResult: Codable, Equatable, Identifiable {
    let id: Int64
    let runID: Int64
    let accountKey: String
    let fileName: String
    let displayAccount: String
    let accountSnapshot: String
    let authIndex: String
    let accountID: String
    let provider: String
    let disabled: Bool
    let status: String
    let state: String
    let action: String
    let actionReason: String
    let actionStatus: String
    let executedAction: String
    let actionError: String
    let statusCode: Int?
    let usedPercent: Double?
    let isQuota: Bool
    let autoRecoverEligible: Bool
    let error: String
    let planType: String?
    let quotaWindows: [RuntimeCodexInspectionQuotaWindow]
    let errorKind: String
    let errorDetail: String
    let createdAtMs: Int64

    init(
        id: Int64,
        runID: Int64 = 0,
        accountKey: String = "",
        fileName: String = "",
        displayAccount: String = "",
        accountSnapshot: String = "",
        authIndex: String = "",
        accountID: String = "",
        provider: String = "",
        disabled: Bool = false,
        status: String = "",
        state: String = "",
        action: String = "",
        actionReason: String = "",
        actionStatus: String = "",
        executedAction: String = "",
        actionError: String = "",
        statusCode: Int? = nil,
        usedPercent: Double? = nil,
        isQuota: Bool = false,
        autoRecoverEligible: Bool = false,
        error: String = "",
        planType: String? = nil,
        quotaWindows: [RuntimeCodexInspectionQuotaWindow] = [],
        errorKind: String = "",
        errorDetail: String = "",
        createdAtMs: Int64 = 0
    ) {
        self.id = id
        self.runID = runID
        self.accountKey = accountKey
        self.fileName = fileName
        self.displayAccount = displayAccount
        self.accountSnapshot = accountSnapshot
        self.authIndex = authIndex
        self.accountID = accountID
        self.provider = provider
        self.disabled = disabled
        self.status = status
        self.state = state
        self.action = action
        self.actionReason = actionReason
        self.actionStatus = actionStatus
        self.executedAction = executedAction
        self.actionError = actionError
        self.statusCode = statusCode
        self.usedPercent = usedPercent
        self.isQuota = isQuota
        self.autoRecoverEligible = autoRecoverEligible
        self.error = error
        self.planType = planType
        self.quotaWindows = quotaWindows
        self.errorKind = errorKind
        self.errorDetail = errorDetail
        self.createdAtMs = createdAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case runID = "runId"
        case accountKey
        case fileName
        case displayAccount
        case accountSnapshot
        case authIndex
        case accountID = "accountId"
        case provider
        case disabled
        case status
        case state
        case action
        case actionReason
        case actionStatus
        case executedAction
        case actionError
        case statusCode
        case usedPercent
        case isQuota
        case autoRecoverEligible
        case error
        case planType
        case quotaWindows
        case errorKind
        case errorDetail
        case createdAtMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        runID = try container.decodeIfPresent(Int64.self, forKey: .runID) ?? 0
        accountKey = try container.decodeIfPresent(String.self, forKey: .accountKey) ?? ""
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? ""
        displayAccount = try container.decodeIfPresent(String.self, forKey: .displayAccount) ?? ""
        accountSnapshot = try container.decodeIfPresent(String.self, forKey: .accountSnapshot) ?? ""
        authIndex = try container.decodeIfPresent(String.self, forKey: .authIndex) ?? ""
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID) ?? ""
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
        disabled = try container.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        action = try container.decodeIfPresent(String.self, forKey: .action) ?? ""
        actionReason = try container.decodeIfPresent(String.self, forKey: .actionReason) ?? ""
        let decodedActionStatus = try container.decodeIfPresent(String.self, forKey: .actionStatus) ?? ""
        if decodedActionStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalizedAction = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            actionStatus = ["delete", "disable", "enable"].contains(normalizedAction)
                ? "pending"
                : "none"
        } else {
            actionStatus = decodedActionStatus
        }
        executedAction = try container.decodeIfPresent(String.self, forKey: .executedAction) ?? ""
        actionError = try container.decodeIfPresent(String.self, forKey: .actionError) ?? ""
        statusCode = try container.decodeIfPresent(Int.self, forKey: .statusCode)
        usedPercent = try container.decodeIfPresent(Double.self, forKey: .usedPercent)
        isQuota = try container.decodeIfPresent(Bool.self, forKey: .isQuota) ?? false
        autoRecoverEligible = try container.decodeIfPresent(Bool.self, forKey: .autoRecoverEligible) ?? false
        error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        quotaWindows = try container.decodeIfPresent([RuntimeCodexInspectionQuotaWindow].self, forKey: .quotaWindows) ?? []
        errorKind = try container.decodeIfPresent(String.self, forKey: .errorKind) ?? ""
        errorDetail = try container.decodeIfPresent(String.self, forKey: .errorDetail) ?? ""
        createdAtMs = try container.decodeIfPresent(Int64.self, forKey: .createdAtMs) ?? 0
    }

    var normalizedAction: String {
        action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var normalizedActionStatus: String {
        let normalized = actionStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalized.isEmpty {
            return normalized
        }
        return ["delete", "disable", "enable"].contains(normalizedAction) ? "pending" : "none"
    }

    var actionTitle: String {
        switch normalizedAction {
        case "keep": OasesLocalization.localized("保留")
        case "delete": OasesLocalization.localized("建议删除")
        case "disable": OasesLocalization.localized("建议禁用")
        case "enable": OasesLocalization.localized("建议启用")
        case "reauth": OasesLocalization.localized("需要重新授权")
        case "review": OasesLocalization.localized("人工复核")
        case "": OasesLocalization.localized("未给出建议")
        default: action
        }
    }

    var actionStatusTitle: String {
        switch normalizedActionStatus {
        case "pending": OasesLocalization.localized("待处理")
        case "success": OasesLocalization.localized("已执行")
        case "failed": OasesLocalization.localized("执行失败")
        case "skipped": OasesLocalization.localized("已跳过")
        case "needs_review": OasesLocalization.localized("需人工复核")
        case "none", "": OasesLocalization.localized("无需操作")
        default: actionStatus
        }
    }

    var stateTitle: String {
        disabled ? OasesLocalization.localized("已禁用") : OasesLocalization.localized("已启用")
    }

    var accountTitle: String {
        let account = displayAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        if !account.isEmpty { return account }
        let file = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return file.isEmpty ? OasesLocalization.localized("未命名认证文件") : file
    }

    var actionRequiresAuthFileReview: Bool {
        ["delete", "disable", "enable", "reauth", "review"].contains(normalizedAction) &&
            normalizedActionStatus != "success"
    }

    var progress: Double? {
        guard let usedPercent else { return nil }
        return min(max(usedPercent / 100, 0), 1)
    }

    var failureMessage: String {
        [errorDetail, actionError, error]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? ""
    }

    var searchText: String {
        [
            accountKey,
            fileName,
            displayAccount,
            accountSnapshot,
            authIndex,
            accountID,
            provider,
            status,
            state,
            action,
            actionReason,
            actionStatus,
            errorKind,
            errorDetail,
            error
        ]
        .joined(separator: " ")
        .lowercased()
    }
}

struct RuntimeCodexInspectionLog: Codable, Equatable, Identifiable {
    let id: Int64
    let runID: Int64
    let level: String
    let message: String
    let detail: RuntimeJSONValue?
    let createdAtMs: Int64

    init(
        id: Int64,
        runID: Int64 = 0,
        level: String = "",
        message: String = "",
        detail: RuntimeJSONValue? = nil,
        createdAtMs: Int64 = 0
    ) {
        self.id = id
        self.runID = runID
        self.level = level
        self.message = message
        self.detail = detail
        self.createdAtMs = createdAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case runID = "runId"
        case level
        case message
        case detail
        case createdAtMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id) ?? 0
        runID = try container.decodeIfPresent(Int64.self, forKey: .runID) ?? 0
        level = try container.decodeIfPresent(String.self, forKey: .level) ?? ""
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        detail = try container.decodeIfPresent(RuntimeJSONValue.self, forKey: .detail)
        createdAtMs = try container.decodeIfPresent(Int64.self, forKey: .createdAtMs) ?? 0
    }

    var createdAt: Date? {
        createdAtMs > 0 ? Date(timeIntervalSince1970: TimeInterval(createdAtMs) / 1_000) : nil
    }

    var normalizedLevel: String {
        level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var levelTitle: String {
        switch normalizedLevel {
        case "success", "info": OasesLocalization.localized("信息")
        case "warning", "warn": OasesLocalization.localized("警告")
        case "error", "failed": OasesLocalization.localized("错误")
        case "": OasesLocalization.localized("日志")
        default: level
        }
    }

    var detailText: String? {
        guard let detail else { return nil }
        let text = detail.inspectionDisplayText
        return text.isEmpty ? nil : text
    }
}

struct RuntimeCodexInspectionRunDetail: Decodable, Equatable {
    let run: RuntimeCodexInspectionRun
    let results: [RuntimeCodexInspectionResult]
    let logs: [RuntimeCodexInspectionLog]

    init(
        run: RuntimeCodexInspectionRun,
        results: [RuntimeCodexInspectionResult] = [],
        logs: [RuntimeCodexInspectionLog] = []
    ) {
        self.run = run
        self.results = results
        self.logs = logs
    }

    private enum CodingKeys: String, CodingKey {
        case run
        case results
        case logs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRun = try container.decode(RuntimeCodexInspectionRun.self, forKey: .run)
        guard decodedRun.id > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .run,
                in: container,
                debugDescription: "Codex inspection run id is required"
            )
        }
        run = decodedRun
        results = (try container.decodeIfPresent([RuntimeCodexInspectionResult].self, forKey: .results) ?? [])
            .filter { $0.id > 0 }
        logs = (try container.decodeIfPresent([RuntimeCodexInspectionLog].self, forKey: .logs) ?? [])
            .filter { $0.id > 0 }
    }
}

private extension RuntimeJSONValue {
    var inspectionDisplayText: String {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            if value.isFinite,
               value.rounded() == value,
               value >= Double(Int64.min),
               value <= Double(Int64.max) {
                return String(Int64(value))
            }
            return String(value)
        case .boolean(let value):
            return value ? "true" : "false"
        case .null:
            return ""
        case .array(let values):
            return values.map(\.inspectionDisplayText)
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        case .object(let values):
            return values
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { key, value in
                    let rendered = value.inspectionDisplayText
                    return rendered.isEmpty ? key : "\(key): \(rendered)"
                }
                .joined(separator: " · ")
        }
    }
}
