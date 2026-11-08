import Foundation

/// CPAMP keeps the price table as a model-ID keyed object. Keeping each price
/// as raw JSON lets this client show and retain new server fields while only
/// authoring the deliberately-simple manual price shape.
struct RuntimeModelPricePayload: Codable, Equatable, Sendable {
    var values: [String: RuntimeJSONValue]

    init(values: [String: RuntimeJSONValue] = [:]) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        values = try [String: RuntimeJSONValue](from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try values.encode(to: encoder)
    }

    func numberValue(for key: String) -> Double {
        guard case .number(let value) = values[key], value.isFinite else { return 0 }
        return value
    }

    func boolValue(for key: String) -> Bool {
        guard case .boolean(let value) = values[key] else { return false }
        return value
    }

    func stringValue(for key: String) -> String {
        guard case .string(let value) = values[key] else { return "" }
        return value
    }

    func arrayCount(for key: String) -> Int {
        guard case .array(let values) = values[key] else { return 0 }
        return values.count
    }

    var prompt: Double { numberValue(for: "prompt") }
    var completion: Double { numberValue(for: "completion") }
    var cache: Double { numberValue(for: "cache") }
    var cacheRead: Double { numberValue(for: "cacheRead") }
    var cacheCreation: Double { numberValue(for: "cacheCreation") }
    var promptConfigured: Bool { boolValue(for: "promptConfigured") }
    var completionConfigured: Bool { boolValue(for: "completionConfigured") }
    var cacheReadConfigured: Bool { boolValue(for: "cacheReadConfigured") }
    var cacheCreationConfigured: Bool { boolValue(for: "cacheCreationConfigured") }
    var source: String { stringValue(for: "source") }
    var sourceModelID: String { stringValue(for: "sourceModelId") }
    var contextTierCount: Int { arrayCount(for: "contextTiers") }
    var serviceTierCount: Int { arrayCount(for: "serviceTiers") }
    var rawMetadata: String { stringValue(for: "rawJson") }

    var isManual: Bool {
        source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "manual"
    }

    var hasAdvancedMetadata: Bool {
        contextTierCount > 0 || serviceTierCount > 0 || !rawMetadata.isEmpty || (!source.isEmpty && !isManual)
    }
}

struct RuntimeModelPricesResponse: Decodable, Sendable {
    let prices: [String: RuntimeModelPricePayload]

    init(from decoder: Decoder) throws {
        let root = try [String: RuntimeJSONValue](from: decoder)
        guard case .object(let rawPrices) = root["prices"] else {
            prices = [:]
            return
        }
        prices = rawPrices.reduce(into: [:]) { output, item in
            guard case .object(let values) = item.value else { return }
            output[item.key] = RuntimeModelPricePayload(values: values)
        }
    }
}

struct RuntimeModelPriceUsageStat: Identifiable, Equatable, Sendable {
    let model: String
    let calls: Int
    let requestedCalls: Int
    let resolvedCalls: Int

    var id: String { model }

    init(model: String, calls: Int, requestedCalls: Int, resolvedCalls: Int) {
        self.model = model
        self.calls = calls
        self.requestedCalls = requestedCalls
        self.resolvedCalls = resolvedCalls
    }

    init?(value: RuntimeJSONValue) {
        guard case .object(let object) = value else { return nil }
        let model = Self.string(object["model"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return nil }
        self.init(
            model: model,
            calls: Self.integer(object["calls"]),
            requestedCalls: Self.integer(object["requested_calls"] ?? object["requestedCalls"]),
            resolvedCalls: Self.integer(object["resolved_calls"] ?? object["resolvedCalls"])
        )
    }

    private static func string(_ value: RuntimeJSONValue?) -> String {
        guard case .some(.string(let value)) = value else { return "" }
        return value
    }

    private static func integer(_ value: RuntimeJSONValue?) -> Int {
        guard case .some(.number(let numeric)) = value, numeric.isFinite else { return 0 }
        return Int(numeric.rounded(.towardZero))
    }
}

struct RuntimeModelPriceUsageSummary: Decodable, Equatable, Sendable {
    let sampledEvents: Int
    let totalEvents: Int
    let truncated: Bool
    let models: [RuntimeModelPriceUsageStat]

    init(from decoder: Decoder) throws {
        let root = try [String: RuntimeJSONValue](from: decoder)
        sampledEvents = Self.integer(root["sampled_events"] ?? root["sampledEvents"])
        totalEvents = Self.integer(root["total_events"] ?? root["totalEvents"])
        truncated = Self.bool(root["truncated"])
        guard case .array(let items) = root["models"] else {
            models = []
            return
        }
        models = items.compactMap(RuntimeModelPriceUsageStat.init(value:))
    }

    private static func integer(_ value: RuntimeJSONValue?) -> Int {
        guard case .some(.number(let numeric)) = value, numeric.isFinite else { return 0 }
        return Int(numeric.rounded(.towardZero))
    }

    private static func bool(_ value: RuntimeJSONValue?) -> Bool {
        guard case .some(.boolean(let value)) = value else { return false }
        return value
    }
}

struct RuntimeModelPriceSyncSourceResult: Equatable, Sendable {
    let source: String
    let models: Int
    let skipped: Int
    let error: String?

    init?(value: RuntimeJSONValue) {
        guard case .object(let object) = value else { return nil }
        guard case .string(let source) = object["source"] else { return nil }
        self.source = source
        self.models = Self.integer(object["models"])
        self.skipped = Self.integer(object["skipped"])
        if case .string(let value) = object["error"], !value.isEmpty {
            error = value
        } else {
            error = nil
        }
    }

    private static func integer(_ value: RuntimeJSONValue?) -> Int {
        guard case .some(.number(let numeric)) = value, numeric.isFinite else { return 0 }
        return Int(numeric.rounded(.towardZero))
    }
}

/// One public price the sync could not match with certainty (`modelprice.SyncCandidate`).
struct RuntimeModelPriceCandidate: Identifiable, Equatable, Sendable {
    let sourceModelID: String
    let score: Double
    let reason: String
    /// The price as CPA Manager Plus would store it (kept whole, unknown fields included).
    let price: RuntimeModelPricePayload

    var id: String { sourceModelID }
    var displaySourceModelID: String { InternalModelID.publicName(sourceModelID) }

    init?(value: RuntimeJSONValue) {
        guard case .object(let object) = value,
              case .string(let sourceModelID) = object["sourceModelId"],
              case .object(let price) = object["price"] else { return nil }
        self.sourceModelID = sourceModelID
        if case .number(let score) = object["score"], score.isFinite {
            self.score = score
        } else {
            score = 0
        }
        if case .string(let reason) = object["reason"] {
            self.reason = reason
        } else {
            reason = ""
        }
        self.price = RuntimeModelPricePayload(values: price)
    }

    /// `current` with this candidate's price stored under `model`; every other price unchanged.
    func adopted(for model: String, into current: [String: RuntimeModelPricePayload]) -> [String: RuntimeModelPricePayload] {
        var merged = current
        merged[model] = price
        return merged
    }
}

/// The candidates for one model (`modelprice.SyncCandidateSet`).
struct RuntimeModelPriceCandidateSet: Identifiable, Equatable, Sendable {
    let model: String
    let candidates: [RuntimeModelPriceCandidate]

    var id: String { model }
    var displayModel: String { InternalModelID.publicName(model) }

    init?(value: RuntimeJSONValue) {
        guard case .object(let object) = value,
              case .string(let model) = object["model"], !model.isEmpty else { return nil }
        self.model = model
        if case .array(let items) = object["candidates"] {
            candidates = items.compactMap(RuntimeModelPriceCandidate.init(value:))
        } else {
            candidates = []
        }
    }
}

struct RuntimeModelPriceSyncResponse: Decodable, Sendable {
    let prices: [String: RuntimeModelPricePayload]
    let imported: Int
    let skipped: Int
    let source: String?
    let sources: [String]
    private(set) var candidateSets: [RuntimeModelPriceCandidateSet]
    var candidateSetCount: Int { candidateSets.count }
    let unmatchedModels: [String]
    let preservedModels: [String]
    let proxyUsed: Bool
    let sourceResults: [RuntimeModelPriceSyncSourceResult]

    init(from decoder: Decoder) throws {
        let root = try [String: RuntimeJSONValue](from: decoder)
        if case .object(let rawPrices) = root["prices"] {
            prices = rawPrices.reduce(into: [:]) { output, item in
                guard case .object(let values) = item.value else { return }
                output[item.key] = RuntimeModelPricePayload(values: values)
            }
        } else {
            prices = [:]
        }
        imported = Self.integer(root["imported"])
        skipped = Self.integer(root["skipped"])
        if case .string(let value) = root["source"], !value.isEmpty {
            source = value
        } else {
            source = nil
        }
        sources = Self.strings(root["sources"])
        if case .array(let candidates) = root["candidates"] {
            candidateSets = candidates.compactMap(RuntimeModelPriceCandidateSet.init(value:))
        } else {
            candidateSets = []
        }
        unmatchedModels = Self.strings(root["unmatched"])
        preservedModels = Self.strings(root["preserved"])
        if case .boolean(let value) = root["proxyUsed"] {
            proxyUsed = value
        } else {
            proxyUsed = false
        }
        if case .array(let values) = root["sourceResults"] {
            sourceResults = values.compactMap(RuntimeModelPriceSyncSourceResult.init(value:))
        } else {
            sourceResults = []
        }
    }

    /// This result without the candidates of `model` (after one of them was adopted).
    func removingCandidateSet(for model: String) -> RuntimeModelPriceSyncResponse {
        var copy = self
        copy.candidateSets.removeAll { $0.model == model }
        return copy
    }

    private static func integer(_ value: RuntimeJSONValue?) -> Int {
        guard case .some(.number(let numeric)) = value, numeric.isFinite else { return 0 }
        return Int(numeric.rounded(.towardZero))
    }

    private static func strings(_ value: RuntimeJSONValue?) -> [String] {
        guard case .some(.array(let values)) = value else { return [] }
        return values.compactMap { item in
            guard case .string(let value) = item else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

struct RuntimeModelPricesReplaceRequest: Encodable, Sendable {
    let prices: [String: RuntimeModelPricePayload]
}

struct RuntimeModelPriceSyncRequest: Encodable, Sendable {
    let models: [String]
}

struct RuntimeModelPriceRecord: Identifiable, Equatable, Sendable {
    let modelID: String
    let payload: RuntimeModelPricePayload

    var id: String { modelID }
}

struct RuntimeModelPriceDraft: Equatable, Sendable {
    var modelID: String
    var prompt: String
    var completion: String
    var cache: String
    var cacheRead: String
    var cacheCreation: String

    init(
        modelID: String = "",
        prompt: String = "",
        completion: String = "",
        cache: String = "",
        cacheRead: String = "",
        cacheCreation: String = ""
    ) {
        self.modelID = modelID
        self.prompt = prompt
        self.completion = completion
        self.cache = cache
        self.cacheRead = cacheRead
        self.cacheCreation = cacheCreation
    }

    init(modelID: String, payload: RuntimeModelPricePayload?) {
        self.modelID = modelID
        guard let payload else {
            prompt = ""
            completion = ""
            cache = ""
            cacheRead = ""
            cacheCreation = ""
            return
        }
        prompt = Self.configuredValue(payload.prompt, configured: payload.promptConfigured)
        completion = Self.configuredValue(payload.completion, configured: payload.completionConfigured)
        cache = Self.numberString(payload.cache)
        cacheRead = Self.configuredValue(payload.cacheRead, configured: payload.cacheReadConfigured)
        cacheCreation = Self.configuredValue(payload.cacheCreation, configured: payload.cacheCreationConfigured)
    }

    /// New and edited prices are always stored under the public model name.
    var normalizedModelID: String {
        InternalModelID.publicName(modelID.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var validationMessage: String? {
        let model = normalizedModelID
        guard !model.isEmpty,
              model.count <= 512,
              !model.contains(where: { $0.isNewline }) else {
            return OasesLocalization.localized("模型 ID 不能为空、不能包含换行，且长度不能超过 512 个字符。")
        }

        let values = [
            (OasesLocalization.localized("输入"), prompt),
            (OasesLocalization.localized("输出"), completion),
            (OasesLocalization.localized("缓存"), cache),
            (OasesLocalization.localized("缓存读取"), cacheRead),
            (OasesLocalization.localized("缓存写入"), cacheCreation)
        ]
        guard values.contains(where: { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return OasesLocalization.localized("请至少填写一项价格；填写 0 可表示明确的零价格。")
        }
        for (label, raw) in values {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty || (Self.number(from: trimmed).map { $0 >= 0 } == true) else {
                return OasesLocalization.localizedFormat("%@价格必须是大于或等于 0 的有效数字。", label)
            }
        }
        return nil
    }

    func manualPayload() -> RuntimeModelPricePayload {
        let prompt = Self.number(from: prompt) ?? 0
        let completion = Self.number(from: completion) ?? 0
        let cache = cache.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? prompt
            : (Self.number(from: cache) ?? 0)
        let cacheRead = Self.number(from: cacheRead) ?? 0
        let cacheCreation = Self.number(from: cacheCreation) ?? 0
        return RuntimeModelPricePayload(values: [
            "prompt": .number(prompt),
            "completion": .number(completion),
            "cache": .number(cache),
            "cacheRead": .number(cacheRead),
            "cacheCreation": .number(cacheCreation),
            "promptConfigured": .boolean(!self.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
            "completionConfigured": .boolean(!self.completion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
            "cacheReadConfigured": .boolean(!self.cacheRead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
            "cacheCreationConfigured": .boolean(!self.cacheCreation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
            "source": .string("manual"),
            "contextTiers": .array([]),
            "serviceTiers": .array([])
        ])
    }

    func hasChanges(relativeTo payload: RuntimeModelPricePayload?) -> Bool {
        guard let payload else {
            return validationMessage == nil
        }
        let candidate = manualPayload()
        let sameBase =
            candidate.prompt == payload.prompt &&
            candidate.completion == payload.completion &&
            candidate.cache == payload.cache &&
            candidate.cacheRead == payload.cacheRead &&
            candidate.cacheCreation == payload.cacheCreation &&
            candidate.promptConfigured == payload.promptConfigured &&
            candidate.completionConfigured == payload.completionConfigured &&
            candidate.cacheReadConfigured == payload.cacheReadConfigured &&
            candidate.cacheCreationConfigured == payload.cacheCreationConfigured
        return !sameBase || !payload.isManual || payload.hasAdvancedMetadata
    }

    private static func configuredValue(_ value: Double, configured: Bool) -> String {
        configured || value > 0 ? numberString(value) : ""
    }

    private static func numberString(_ value: Double) -> String {
        String(value)
    }

    private static func number(from value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }
}
