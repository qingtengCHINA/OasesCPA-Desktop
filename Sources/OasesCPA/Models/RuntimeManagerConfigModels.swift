import Foundation

struct RuntimeManagerConfigResponse: Codable, Equatable {
    var config: RuntimeManagerConfig
    var source: String?
    var cpaUsage: RuntimeCPAUsageConfig?
}

struct RuntimeManagerConfig: Codable, Equatable {
    var cpaConnection: RuntimeCPAConnectionConfig
    var collector: RuntimeManagerCollectorConfig
    var codexInspection: RuntimeCodexInspectionConfig?
    var externalUsageService: RuntimeExternalUsageServiceConfig
    var updatedAtMs: Int64?

    init(
        cpaConnection: RuntimeCPAConnectionConfig = .init(),
        collector: RuntimeManagerCollectorConfig = .init(),
        codexInspection: RuntimeCodexInspectionConfig? = nil,
        externalUsageService: RuntimeExternalUsageServiceConfig = .init(),
        updatedAtMs: Int64? = nil
    ) {
        self.cpaConnection = cpaConnection
        self.collector = collector
        self.codexInspection = codexInspection
        self.externalUsageService = externalUsageService
        self.updatedAtMs = updatedAtMs
    }

    private enum CodingKeys: String, CodingKey {
        case cpaConnection
        case collector
        case codexInspection
        case externalUsageService
        case updatedAtMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cpaConnection = try container.decodeIfPresent(RuntimeCPAConnectionConfig.self, forKey: .cpaConnection) ?? .init()
        collector = try container.decodeIfPresent(RuntimeManagerCollectorConfig.self, forKey: .collector) ?? .init()
        codexInspection = try container.decodeIfPresent(RuntimeCodexInspectionConfig.self, forKey: .codexInspection)
        externalUsageService = try container.decodeIfPresent(RuntimeExternalUsageServiceConfig.self, forKey: .externalUsageService) ?? .init()
        updatedAtMs = try container.decodeIfPresent(Int64.self, forKey: .updatedAtMs)
    }

    var isMonitoringEnabled: Bool {
        collector.enabled ?? true
    }

    var managementKey: String {
        cpaConnection.managementKey ?? ""
    }
}

struct RuntimeCPAConnectionConfig: Codable, Equatable {
    var engineBaseURL: String
    var managementKey: String?

    init(engineBaseURL: String = "", managementKey: String? = nil) {
        self.engineBaseURL = engineBaseURL
        self.managementKey = managementKey
    }

    private enum CodingKeys: String, CodingKey {
        case engineBaseURL = "cpaBaseUrl"
        case managementKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engineBaseURL = try container.decodeIfPresent(String.self, forKey: .engineBaseURL) ?? ""
        managementKey = try container.decodeIfPresent(String.self, forKey: .managementKey)
    }
}

/// Checks the address CPA Manager Plus uses to reach the engine (`cpaConnection.cpaBaseUrl`)
/// before it is saved.
///
/// Gateway topology: the engine listens on `http://127.0.0.1:18316` only (IPv4 loopback;
/// `localhost` may resolve to `::1`, where nothing listens). Pointing CPA Manager Plus at the
/// gateway (8317, 18320) or at itself (18317) breaks monitoring and usage collection.
/// Legacy topology: any http(s) address (a legacy Docker stack uses the container name).
enum ManagerUpstreamValidation {
    static let invalidAddressSource = "请输入完整的 http 地址，例如 %@。"
    /// The port is passed as text: a number argument would be shown with digit grouping
    /// ("18,317").
    static let gatewayPortSource = "%1$@ 是网关或 CPAMP 自己的端口，不是引擎；CPAMP 的上游应为 %2$@。"
    static let loopbackOnlySource = "网关部署中的引擎只监听本机 IPv4 回环地址，CPAMP 的上游应为 %@。"

    /// The localization keys of every message (tests check the English translations).
    static let messageSources = [invalidAddressSource, gatewayPortSource, loopbackOnlySource]

    static func error(for cpaBaseURL: String, topology: DeploymentTopology) -> String? {
        let engineAddress = DeploymentEndpoints(topology: topology).engineBaseURL.absoluteString
        let trimmed = cpaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty else {
            return OasesLocalization.localizedFormat(invalidAddressSource, engineAddress)
        }
        switch topology {
        case .legacy:
            guard scheme == "http" || scheme == "https" else {
                return OasesLocalization.localizedFormat(invalidAddressSource, engineAddress)
            }
            // CPA Manager Plus listens on 18317 itself: pointing it at its own loopback address
            // makes it read its own API as the engine's. Other hosts (a Docker container name)
            // stay allowed.
            if let port = components.port, port == DeploymentPorts.cpamp, Self.isLoopback(host) {
                return OasesLocalization.localizedFormat(gatewayPortSource, String(port), engineAddress)
            }
            return nil
        case .gateway:
            guard scheme == "http" else {
                return OasesLocalization.localizedFormat(invalidAddressSource, engineAddress)
            }
            guard host == "127.0.0.1",
                  components.user == nil, components.password == nil else {
                return OasesLocalization.localizedFormat(loopbackOnlySource, engineAddress)
            }
            guard let port = components.port else {
                return OasesLocalization.localizedFormat(invalidAddressSource, engineAddress)
            }
            if port == DeploymentPorts.engine,
               components.path.isEmpty || components.path == "/",
               components.query == nil, components.fragment == nil {
                return nil
            }
            if [DeploymentPorts.gatewayAPI, DeploymentPorts.gatewayAdmin, DeploymentPorts.cpamp].contains(port) {
                return OasesLocalization.localizedFormat(gatewayPortSource, String(port), engineAddress)
            }
            return OasesLocalization.localizedFormat(invalidAddressSource, engineAddress)
        }
    }

    /// `127.0.0.0/8`, `localhost` and `::1` (URLComponents gives the IPv6 host without brackets).
    static func isLoopback(_ host: String) -> Bool {
        let lowered = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if lowered == "localhost" || lowered == "::1" || lowered == "0:0:0:0:0:0:0:1" { return true }
        let octets = lowered.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4 && octets[0] == "127" && octets.allSatisfy { UInt8($0) != nil }
    }
}

struct RuntimeManagerCollectorConfig: Codable, Equatable {
    var enabled: Bool?
    var collectorMode: String
    var queue: String
    var popSide: String
    var batchSize: Int
    var pollIntervalMs: Int
    var queryLimit: Int
    var tlsSkipVerify: Bool

    init(
        enabled: Bool? = true,
        collectorMode: String = "auto",
        queue: String = "usage",
        popSide: String = "right",
        batchSize: Int = 100,
        pollIntervalMs: Int = 500,
        queryLimit: Int = 50_000,
        tlsSkipVerify: Bool = false
    ) {
        self.enabled = enabled
        self.collectorMode = collectorMode
        self.queue = queue
        self.popSide = popSide
        self.batchSize = batchSize
        self.pollIntervalMs = pollIntervalMs
        self.queryLimit = queryLimit
        self.tlsSkipVerify = tlsSkipVerify
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case collectorMode
        case queue
        case popSide
        case batchSize
        case pollIntervalMs
        case queryLimit
        case tlsSkipVerify
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        collectorMode = try container.decodeIfPresent(String.self, forKey: .collectorMode) ?? "auto"
        queue = try container.decodeIfPresent(String.self, forKey: .queue) ?? "usage"
        popSide = try container.decodeIfPresent(String.self, forKey: .popSide) ?? "right"
        batchSize = try container.decodeIfPresent(Int.self, forKey: .batchSize) ?? 100
        pollIntervalMs = try container.decodeIfPresent(Int.self, forKey: .pollIntervalMs) ?? 500
        queryLimit = try container.decodeIfPresent(Int.self, forKey: .queryLimit) ?? 50_000
        tlsSkipVerify = try container.decodeIfPresent(Bool.self, forKey: .tlsSkipVerify) ?? false
    }
}

struct RuntimeExternalUsageServiceConfig: Codable, Equatable {
    var enabled: Bool
    var serviceBase: String

    init(enabled: Bool = false, serviceBase: String = "") {
        self.enabled = enabled
        self.serviceBase = serviceBase
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case serviceBase
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        serviceBase = try container.decodeIfPresent(String.self, forKey: .serviceBase) ?? ""
    }
}

struct RuntimeCodexInspectionConfig: Codable, Equatable {
    var enabled: Bool?
    var schedule: RuntimeCodexInspectionScheduleConfig
    var targetTypes: [String]
    var targetType: String
    var workers: Int
    var deleteWorkers: Int
    var timeout: Int
    var retries: Int
    var userAgent: String
    var xaiInferenceUserAgent: String
    var xaiInferenceEnabled: Bool
    var xaiInferenceModel: String
    var xaiInferencePrompt: String
    var usedPercentThreshold: Double
    var sampleSize: Int
    var autoActionMode: String
    var autoRecoverEnabled: Bool

    init(
        enabled: Bool? = nil,
        schedule: RuntimeCodexInspectionScheduleConfig = .init(),
        targetTypes: [String] = [],
        targetType: String = "",
        workers: Int = 0,
        deleteWorkers: Int = 0,
        timeout: Int = 0,
        retries: Int = 0,
        userAgent: String = "",
        xaiInferenceUserAgent: String = "",
        xaiInferenceEnabled: Bool = false,
        xaiInferenceModel: String = "",
        xaiInferencePrompt: String = "",
        usedPercentThreshold: Double = 0,
        sampleSize: Int = 0,
        autoActionMode: String = "none",
        autoRecoverEnabled: Bool = false
    ) {
        self.enabled = enabled
        self.schedule = schedule
        self.targetTypes = targetTypes
        self.targetType = targetType
        self.workers = workers
        self.deleteWorkers = deleteWorkers
        self.timeout = timeout
        self.retries = retries
        self.userAgent = userAgent
        self.xaiInferenceUserAgent = xaiInferenceUserAgent
        self.xaiInferenceEnabled = xaiInferenceEnabled
        self.xaiInferenceModel = xaiInferenceModel
        self.xaiInferencePrompt = xaiInferencePrompt
        self.usedPercentThreshold = usedPercentThreshold
        self.sampleSize = sampleSize
        self.autoActionMode = autoActionMode
        self.autoRecoverEnabled = autoRecoverEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case schedule
        case targetTypes
        case targetType
        case workers
        case deleteWorkers
        case timeout
        case retries
        case userAgent
        case xaiInferenceUserAgent
        case xaiInferenceEnabled
        case xaiInferenceModel
        case xaiInferencePrompt
        case usedPercentThreshold
        case sampleSize
        case autoActionMode
        case autoRecoverEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
        schedule = try container.decodeIfPresent(RuntimeCodexInspectionScheduleConfig.self, forKey: .schedule) ?? .init()
        targetTypes = try container.decodeIfPresent([String].self, forKey: .targetTypes) ?? []
        targetType = try container.decodeIfPresent(String.self, forKey: .targetType) ?? ""
        workers = try container.decodeIfPresent(Int.self, forKey: .workers) ?? 0
        deleteWorkers = try container.decodeIfPresent(Int.self, forKey: .deleteWorkers) ?? 0
        timeout = try container.decodeIfPresent(Int.self, forKey: .timeout) ?? 0
        retries = try container.decodeIfPresent(Int.self, forKey: .retries) ?? 0
        userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent) ?? ""
        xaiInferenceUserAgent = try container.decodeIfPresent(String.self, forKey: .xaiInferenceUserAgent) ?? ""
        xaiInferenceEnabled = try container.decodeIfPresent(Bool.self, forKey: .xaiInferenceEnabled) ?? false
        xaiInferenceModel = try container.decodeIfPresent(String.self, forKey: .xaiInferenceModel) ?? ""
        xaiInferencePrompt = try container.decodeIfPresent(String.self, forKey: .xaiInferencePrompt) ?? ""
        usedPercentThreshold = try container.decodeIfPresent(Double.self, forKey: .usedPercentThreshold) ?? 0
        sampleSize = try container.decodeIfPresent(Int.self, forKey: .sampleSize) ?? 0
        autoActionMode = try container.decodeIfPresent(String.self, forKey: .autoActionMode) ?? "none"
        autoRecoverEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoRecoverEnabled) ?? false
    }

    /// The supported targets as CPA Manager Plus normalises them
    /// (`NormalizeCodexInspectionTargetTypes`): lower-cased, de-duplicated, in the order
    /// codex, xai.
    static func normalizedTargetTypes(_ values: [String]) -> [String] {
        let selected = Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return ["codex", "xai"].filter(selected.contains)
    }

    /// The `targetTypes` a save sends. CPA Manager Plus v1.14.10 refuses an explicit empty list
    /// with HTTP 500 "at least one inspection target type is required", and a fresh deployment's
    /// configuration has only the legacy `targetType` (no `targetTypes`, decoded here as `[]`).
    /// An empty list is therefore derived from `targetType`, as the server does for a missing
    /// list; nil (the key is left out, the server keeps or derives its own value) when that
    /// gives nothing either. A non-empty list is sent as it is.
    var targetTypesForSaving: [String]? {
        if !targetTypes.isEmpty { return targetTypes }
        let derived = Self.normalizedTargetTypes([targetType])
        return derived.isEmpty ? nil : derived
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(enabled, forKey: .enabled)
        try container.encode(schedule, forKey: .schedule)
        try container.encodeIfPresent(targetTypesForSaving, forKey: .targetTypes)
        try container.encode(targetType, forKey: .targetType)
        try container.encode(workers, forKey: .workers)
        try container.encode(deleteWorkers, forKey: .deleteWorkers)
        try container.encode(timeout, forKey: .timeout)
        try container.encode(retries, forKey: .retries)
        try container.encode(userAgent, forKey: .userAgent)
        try container.encode(xaiInferenceUserAgent, forKey: .xaiInferenceUserAgent)
        try container.encode(xaiInferenceEnabled, forKey: .xaiInferenceEnabled)
        try container.encode(xaiInferenceModel, forKey: .xaiInferenceModel)
        try container.encode(xaiInferencePrompt, forKey: .xaiInferencePrompt)
        try container.encode(usedPercentThreshold, forKey: .usedPercentThreshold)
        try container.encode(sampleSize, forKey: .sampleSize)
        try container.encode(autoActionMode, forKey: .autoActionMode)
        try container.encode(autoRecoverEnabled, forKey: .autoRecoverEnabled)
    }
}

struct RuntimeCodexInspectionScheduleConfig: Codable, Equatable {
    var mode: String
    var timePoints: [String]
    var intervalMinutes: Int
    var timeZone: String

    init(
        mode: String = "interval",
        timePoints: [String] = [],
        intervalMinutes: Int = 60,
        timeZone: String = ""
    ) {
        self.mode = mode
        self.timePoints = timePoints
        self.intervalMinutes = intervalMinutes
        self.timeZone = timeZone
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case timePoints
        case intervalMinutes
        case timeZone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "interval"
        timePoints = try container.decodeIfPresent([String].self, forKey: .timePoints) ?? []
        intervalMinutes = try container.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 60
        timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone) ?? ""
    }
}

struct RuntimeCPAUsageConfig: Codable, Equatable {
    var usageStatisticsEnabled: Bool
    var redisUsageQueueRetentionSeconds: Int
    var retentionSourceDefault: Bool?
}

struct RuntimeManagerConfigPayload: Encodable {
    let config: RuntimeManagerConfig

    private enum CodingKeys: String, CodingKey {
        case config
    }

    private enum ConfigKeys: String, CodingKey {
        case cpaConnection
        case collector
        case codexInspection
        case updatedAtMs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var configContainer = container.nestedContainer(keyedBy: ConfigKeys.self, forKey: .config)

        // CPAMP merges a decoded ManagerConfig instead of a JSON patch. Sending
        // an omitted inspection object would arrive as zero values and can
        // reset fields such as auto recovery, xAI inference, retries and
        // sample size. The app always starts from the latest complete config,
        // then submits that full inspection snapshot so advanced fields remain
        // intact when the user edits only relay or collector settings.
        try configContainer.encode(config.cpaConnection, forKey: .cpaConnection)
        try configContainer.encode(config.collector, forKey: .collector)
        try configContainer.encode(
            config.codexInspection ?? RuntimeCodexInspectionPolicyDraft.defaultConfig(),
            forKey: .codexInspection
        )
        // The version this config was read at: the oases fork of CPA Manager Plus compares it
        // (compare-and-set, 409 when stale); upstream ignores it.
        try configContainer.encodeIfPresent(config.updatedAtMs, forKey: .updatedAtMs)
    }
}
