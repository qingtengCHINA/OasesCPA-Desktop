import Foundation

enum RuntimeCodexInspectionTargetSelection: String, CaseIterable, Identifiable {
    case codex
    case xai
    case codexAndXAI

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .xai: "xAI"
        case .codexAndXAI: OasesLocalization.localized("Codex 和 xAI")
        }
    }

    var targetTypes: [String] {
        switch self {
        case .codex: ["codex"]
        case .xai: ["xai"]
        case .codexAndXAI: ["codex", "xai"]
        }
    }

    var includesCodex: Bool {
        targetTypes.contains("codex")
    }

    var includesXAI: Bool {
        targetTypes.contains("xai")
    }

    init(targetTypes: [String], legacyTargetType: String) {
        let normalized = Set(
            targetTypes
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { ["codex", "xai"].contains($0) }
        )
        if normalized == ["xai"] {
            self = .xai
        } else if normalized.contains("codex"), normalized.contains("xai") {
            self = .codexAndXAI
        } else if legacyTargetType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "xai" {
            self = .xai
        } else {
            self = .codex
        }
    }
}

enum RuntimeCodexInspectionScheduleMode: String, CaseIterable, Identifiable {
    case interval
    case timePoints = "time_points"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .interval: OasesLocalization.localized("每隔一段时间")
        case .timePoints: OasesLocalization.localized("每天指定时间")
        }
    }

    init(value: String, fallbackTimePoints: [String]) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == Self.timePoints.rawValue || (normalized.isEmpty && !fallbackTimePoints.isEmpty) {
            self = .timePoints
        } else {
            self = .interval
        }
    }
}

enum RuntimeCodexInspectionAutoActionMode: String, CaseIterable, Identifiable {
    case none
    case enable
    case disable
    case delete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: OasesLocalization.localized("仅记录（推荐）")
        case .enable: OasesLocalization.localized("兼容恢复模式")
        case .disable: OasesLocalization.localized("自动禁用")
        case .delete: OasesLocalization.localized("自动删除")
        }
    }

    var isMutationCapable: Bool {
        self != .none
    }

    var isDestructive: Bool {
        self == .delete
    }
}

struct RuntimeCodexInspectionPolicyDraft: Equatable {
    var scheduledEnabled: Bool
    var targetSelection: RuntimeCodexInspectionTargetSelection
    var scheduleMode: RuntimeCodexInspectionScheduleMode
    var intervalMinutes: String
    var timePoints: String
    var timeZone: String
    var usedPercentThreshold: String
    var sampleSize: String
    var workers: String
    var deleteWorkers: String
    var timeoutMilliseconds: String
    var retries: String
    var userAgent: String
    var xaiInferenceUserAgent: String
    var xaiInferenceEnabled: Bool
    var xaiInferenceModel: String
    var xaiInferencePrompt: String
    var autoActionMode: RuntimeCodexInspectionAutoActionMode
    var autoRecoverEnabled: Bool

    init(config: RuntimeCodexInspectionConfig) {
        let defaults = Self.defaultConfig()
        scheduledEnabled = config.enabled ?? false
        targetSelection = RuntimeCodexInspectionTargetSelection(
            targetTypes: config.targetTypes,
            legacyTargetType: config.targetType
        )
        scheduleMode = RuntimeCodexInspectionScheduleMode(
            value: config.schedule.mode,
            fallbackTimePoints: config.schedule.timePoints
        )
        intervalMinutes = String(max(config.schedule.intervalMinutes, 1))
        timePoints = config.schedule.timePoints.joined(separator: ", ")
        timeZone = config.schedule.timeZone
        usedPercentThreshold = Self.numberText(config.usedPercentThreshold)
        sampleSize = String(max(config.sampleSize, 0))
        workers = String(config.workers > 0 ? config.workers : defaults.workers)
        deleteWorkers = String(
            config.deleteWorkers > 0
                ? config.deleteWorkers
                : (config.workers > 0 ? config.workers : defaults.deleteWorkers)
        )
        timeoutMilliseconds = String(config.timeout > 0 ? config.timeout : defaults.timeout)
        retries = String(max(config.retries, 0))
        userAgent = Self.valueOr(config.userAgent, fallback: defaults.userAgent)
        xaiInferenceUserAgent = Self.valueOr(
            config.xaiInferenceUserAgent,
            fallback: defaults.xaiInferenceUserAgent
        )
        xaiInferenceEnabled = config.xaiInferenceEnabled
        xaiInferenceModel = Self.valueOr(
            config.xaiInferenceModel,
            fallback: defaults.xaiInferenceModel
        )
        xaiInferencePrompt = Self.valueOr(
            config.xaiInferencePrompt,
            fallback: defaults.xaiInferencePrompt
        )
        autoActionMode = RuntimeCodexInspectionAutoActionMode(
            rawValue: config.autoActionMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ) ?? .none
        autoRecoverEnabled = config.autoRecoverEnabled
    }

    var validationMessage: String? {
        guard parsedIntervalMinutes != nil else {
            return OasesLocalization.localized("巡检间隔必须是大于 0 的整数分钟。")
        }
        guard parsedUsedPercentThreshold != nil else {
            return OasesLocalization.localized("额度阈值必须在 0 到 100 之间。")
        }
        guard parsedSampleSize != nil else {
            return OasesLocalization.localized("采样数量必须是 0 或正整数。")
        }
        if let advancedValidationMessage {
            return advancedValidationMessage
        }
        if !timeZone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           TimeZone(identifier: timeZone.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
            return OasesLocalization.localized("时区必须是有效的 IANA 标识，例如 Asia/Shanghai。")
        }
        if scheduleMode == .timePoints {
            guard let parsedTimePoints, !parsedTimePoints.isEmpty else {
                return OasesLocalization.localized("每天指定时间需要至少一个有效时间，例如 09:00。")
            }
        }
        return nil
    }

    var parsedIntervalMinutes: Int? {
        Self.positiveInteger(intervalMinutes)
    }

    var parsedUsedPercentThreshold: Double? {
        let raw = usedPercentThreshold.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(raw), value.isFinite, (0...100).contains(value) else {
            return nil
        }
        return value
    }

    var parsedSampleSize: Int? {
        let raw = sampleSize.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(raw), value >= 0 else { return nil }
        return value
    }

    var parsedWorkers: Int? {
        Self.positiveInteger(workers)
    }

    var parsedDeleteWorkers: Int? {
        Self.positiveInteger(deleteWorkers)
    }

    var parsedTimeoutMilliseconds: Int? {
        Self.positiveInteger(timeoutMilliseconds)
    }

    var parsedRetries: Int? {
        Self.nonNegativeInteger(retries)
    }

    var hasActiveXAIInferenceProbe: Bool {
        targetSelection.includesXAI && xaiInferenceEnabled
    }

    var advancedValidationMessage: String? {
        guard parsedWorkers != nil else {
            return OasesLocalization.localized("常规并发必须是大于 0 的整数。")
        }
        guard parsedDeleteWorkers != nil else {
            return OasesLocalization.localized("删除并发必须是大于 0 的整数。")
        }
        guard parsedTimeoutMilliseconds != nil else {
            return OasesLocalization.localized("探测超时必须是大于 0 的整数毫秒。")
        }
        guard parsedRetries != nil else {
            return OasesLocalization.localized("重试次数必须是 0 或正整数。")
        }
        if hasActiveXAIInferenceProbe {
            if xaiInferenceModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return OasesLocalization.localized("启用 xAI 推理探针时必须填写模型名。")
            }
            if xaiInferencePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return OasesLocalization.localized("启用 xAI 推理探针时必须填写探测提示词。")
            }
        }
        return nil
    }

    var parsedTimePoints: [String]? {
        let raw = timePoints.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }
        let tokens = raw.split(whereSeparator: { character in
            character == "," ||
                character == ";" ||
                character == "，" ||
                character == "；" ||
                character.isWhitespace
        })
        let normalized = tokens.compactMap { Self.normalizedTimePoint(String($0)) }
        guard normalized.count == tokens.count else { return nil }
        return Array(Set(normalized)).sorted()
    }

    func applying(to existing: RuntimeCodexInspectionConfig) -> RuntimeCodexInspectionConfig {
        guard let interval = parsedIntervalMinutes,
              let threshold = parsedUsedPercentThreshold,
              let sample = parsedSampleSize,
              let workers = parsedWorkers,
              let deleteWorkers = parsedDeleteWorkers,
              let timeout = parsedTimeoutMilliseconds,
              let retries = parsedRetries else {
            return existing
        }

        var next = existing
        let defaults = Self.defaultConfig()
        next.enabled = scheduledEnabled
        next.targetTypes = targetSelection.targetTypes
        next.targetType = targetSelection.targetTypes[0]
        next.schedule.mode = scheduleMode.rawValue
        next.schedule.intervalMinutes = interval
        if let points = parsedTimePoints {
            next.schedule.timePoints = points
        }
        next.schedule.timeZone = timeZone.trimmingCharacters(in: .whitespacesAndNewlines)
        next.usedPercentThreshold = threshold
        next.sampleSize = sample
        next.workers = workers
        next.deleteWorkers = deleteWorkers
        next.timeout = timeout
        next.retries = retries
        next.userAgent = Self.valueOr(
            userAgent,
            fallback: Self.valueOr(existing.userAgent, fallback: defaults.userAgent)
        )
        next.xaiInferenceUserAgent = Self.valueOr(
            xaiInferenceUserAgent,
            fallback: Self.valueOr(
                existing.xaiInferenceUserAgent,
                fallback: defaults.xaiInferenceUserAgent
            )
        )
        next.xaiInferenceEnabled = xaiInferenceEnabled
        next.xaiInferenceModel = Self.valueOr(
            xaiInferenceModel,
            fallback: Self.valueOr(existing.xaiInferenceModel, fallback: defaults.xaiInferenceModel)
        )
        next.xaiInferencePrompt = Self.valueOr(
            xaiInferencePrompt,
            fallback: Self.valueOr(existing.xaiInferencePrompt, fallback: defaults.xaiInferencePrompt)
        )
        next.autoActionMode = autoActionMode.rawValue
        next.autoRecoverEnabled = autoRecoverEnabled
        return next
    }

    var safetySummary: String {
        switch autoActionMode {
        case .none where !autoRecoverEnabled:
            return OasesLocalization.localized("只记录巡检结果和建议，不会按策略自动修改认证文件。")
        case .none:
            return OasesLocalization.localized("不自动处理新异常，但会恢复由巡检自身禁用且已明确恢复的认证文件。")
        case .enable:
            return OasesLocalization.localized("保留 CPAMP 的兼容恢复策略；仅在服务端确认恢复条件后才可能启用认证文件。")
        case .disable:
            return autoRecoverEnabled
                ? OasesLocalization.localized("CPAMP 可能自动禁用不适合新请求的认证文件，也可能恢复由巡检自身禁用且已确认恢复的文件。")
                : OasesLocalization.localized("CPAMP 可能自动禁用不适合新请求的认证文件。")
        case .delete:
            return autoRecoverEnabled
                ? OasesLocalization.localized("CPAMP 可能自动删除明确失效且满足身份核验条件的认证文件，也可能恢复由巡检自身禁用的文件。")
                : OasesLocalization.localized("CPAMP 可能自动删除明确失效且满足身份核验条件的认证文件。")
        }
    }

    var isMutationCapable: Bool {
        autoActionMode.isMutationCapable || autoRecoverEnabled
    }

    var isDestructive: Bool {
        autoActionMode.isDestructive
    }

    static func defaultConfig() -> RuntimeCodexInspectionConfig {
        RuntimeCodexInspectionConfig(
            enabled: false,
            schedule: RuntimeCodexInspectionScheduleConfig(
                mode: "interval",
                timePoints: [],
                intervalMinutes: 60,
                timeZone: ""
            ),
            targetTypes: ["codex"],
            targetType: "codex",
            workers: 4,
            deleteWorkers: 4,
            timeout: 15_000,
            retries: 0,
            userAgent: "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal",
            xaiInferenceUserAgent: "xai-grok-workspace/0.2.101",
            xaiInferenceEnabled: false,
            xaiInferenceModel: "grok-4.5",
            xaiInferencePrompt: "Reply with exactly OK.",
            usedPercentThreshold: 100,
            sampleSize: 0,
            autoActionMode: "none",
            autoRecoverEnabled: false
        )
    }

    private static func positiveInteger(_ raw: String) -> Int? {
        guard let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            return nil
        }
        return value
    }

    private static func nonNegativeInteger(_ raw: String) -> Int? {
        guard let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else {
            return nil
        }
        return value
    }

    private static func valueOr(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func normalizedTimePoint(_ raw: String) -> String? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return String(format: "%02d:%02d", hour, minute)
    }

    private static func numberText(_ value: Double) -> String {
        guard value.isFinite else { return "100" }
        return value.rounded() == value ? String(Int(value)) : String(value)
    }
}
