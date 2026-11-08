import Foundation

/// The outcome of the latest health check of a model (Server `gateway/model-health.mjs`).
enum GatewayHealthStatus: Equatable, Sendable {
    case up
    case down
    /// The model does not answer chat requests (image, embedding, audio, …): not tested.
    case skipped
    /// A status this app does not know yet.
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "up": self = .up
        case "down": self = .down
        case "skipped": self = .skipped
        default: self = .other(rawValue)
        }
    }

    var rawValue: String {
        switch self {
        case .up: "up"
        case .down: "down"
        case .skipped: "skipped"
        case .other(let value): value
        }
    }
}

/// `{ status, latency_ms, error, tested_at }`; `tested_at` is epoch milliseconds. Unknown fields
/// are kept in `extra` and written back.
struct GatewayHealthResult: Codable, Equatable, Sendable {
    var status: GatewayHealthStatus
    var latencyMs: Int?
    /// Already cleaned by the gateway (key-like strings masked, at most 120 characters).
    var error: String?
    var testedAt: Date
    var extra: [String: RuntimeJSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case status
        case latencyMs = "latency_ms"
        case error
        case testedAt = "tested_at"
    }

    private static let known = Set(CodingKeys.allCases.map(\.rawValue))

    init(status: GatewayHealthStatus, latencyMs: Int?, error: String?, testedAt: Date, extra: [String: RuntimeJSONValue] = [:]) {
        self.status = status
        self.latencyMs = latencyMs
        self.error = error
        self.testedAt = testedAt
        self.extra = extra
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = GatewayHealthStatus(rawValue: try container.decode(String.self, forKey: .status))
        latencyMs = try container.decodeIfPresent(Int.self, forKey: .latencyMs)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        let milliseconds = try container.decodeIfPresent(Int64.self, forKey: .testedAt) ?? 0
        testedAt = GatewayDates.date(fromEpochMilliseconds: milliseconds)
        extra = try UnknownFields.capture(from: decoder, known: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status.rawValue, forKey: .status)
        try container.encode(latencyMs, forKey: .latencyMs)
        try container.encode(error, forKey: .error)
        try container.encode(GatewayDates.epochMilliseconds(from: testedAt), forKey: .testedAt)
        try UnknownFields.encode(extra, to: encoder, skipping: Self.known)
    }
}

/// A bulk run over every model (`POST …/models/test-all`); `finishedAt` is nil while it goes on.
/// Runs live in the gateway's memory only: after a gateway restart nothing is running.
struct GatewayTestRun: Codable, Equatable, Sendable {
    var id: String
    var startedAt: Date
    var finishedAt: Date?
    var total: Int
    var done: Int
    var up: Int
    var down: Int
    var skipped: Int
    var extra: [String: RuntimeJSONValue] = [:]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case total, done, up, down, skipped
    }

    private static let known = Set(CodingKeys.allCases.map(\.rawValue))

    var isFinished: Bool { finishedAt != nil }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        startedAt = GatewayDates.date(fromEpochMilliseconds: try container.decodeIfPresent(Int64.self, forKey: .startedAt) ?? 0)
        finishedAt = try container.decodeIfPresent(Int64.self, forKey: .finishedAt).map(GatewayDates.date(fromEpochMilliseconds:))
        total = try container.decodeIfPresent(Int.self, forKey: .total) ?? 0
        done = try container.decodeIfPresent(Int.self, forKey: .done) ?? 0
        up = try container.decodeIfPresent(Int.self, forKey: .up) ?? 0
        down = try container.decodeIfPresent(Int.self, forKey: .down) ?? 0
        skipped = try container.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        extra = try UnknownFields.capture(from: decoder, known: Self.known)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(GatewayDates.epochMilliseconds(from: startedAt), forKey: .startedAt)
        try container.encode(finishedAt.map(GatewayDates.epochMilliseconds(from:)), forKey: .finishedAt)
        try container.encode(total, forKey: .total)
        try container.encode(done, forKey: .done)
        try container.encode(up, forKey: .up)
        try container.encode(down, forKey: .down)
        try container.encode(skipped, forKey: .skipped)
        try UnknownFields.encode(extra, to: encoder, skipping: Self.known)
    }
}

/// `GET /cpa-admin/permissions/api/models/health`: every stored result and the latest run.
/// `models` is keyed by model id, `providers` by `"<provider name>|<model id>"`.
struct GatewayModelHealthResponse: Decodable, Sendable {
    let models: [String: GatewayHealthResult]
    let providers: [String: GatewayHealthResult]
    let run: GatewayTestRun?

    private enum CodingKeys: String, CodingKey {
        case models, providers, run
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        models = try container.decodeIfPresent([String: GatewayHealthResult].self, forKey: .models) ?? [:]
        providers = try container.decodeIfPresent([String: GatewayHealthResult].self, forKey: .providers) ?? [:]
        run = try container.decodeIfPresent(GatewayTestRun.self, forKey: .run)
    }
}

/// `POST …/models/test` answers `{ model, provider, result }`.
struct GatewayModelTestResponse: Decodable, Sendable {
    let model: String
    let provider: String?
    let result: GatewayHealthResult
}

/// `POST …/models/test-all` answers `{ run, already_running }`.
struct GatewayTestAllResponse: Decodable, Sendable {
    let run: GatewayTestRun
    let alreadyRunning: Bool

    private enum CodingKeys: String, CodingKey {
        case run
        case alreadyRunning = "already_running"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        run = try container.decode(GatewayTestRun.self, forKey: .run)
        alreadyRunning = try container.decodeIfPresent(Bool.self, forKey: .alreadyRunning) ?? false
    }
}

/// One row of the models page. `id` is a public model id (internal `pin-x/…` ids never get here);
/// `groups` are the `groupedModels` names that list it (provider names, or the engine's group).
struct GatewayModelRow: Identifiable, Equatable, Sendable {
    let id: String
    let groups: [String]
    let health: GatewayHealthResult?

    /// Rows for the public ids of `groupedModels`, sorted by id (case-insensitively).
    static func rows(groupedModels: [String: [String]], health: [String: GatewayHealthResult]) -> [GatewayModelRow] {
        var groupsByModel: [String: Set<String>] = [:]
        for (group, models) in groupedModels {
            for model in models {
                let id = model.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, InternalModelID.publicName(id) == id else { continue }
                groupsByModel[id, default: []].insert(group)
            }
        }
        return groupsByModel
            .map { id, groups in
                GatewayModelRow(
                    id: id,
                    groups: groups.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                    health: health[id]
                )
            }
            .sorted { lhs, rhs in
                let order = lhs.id.localizedCaseInsensitiveCompare(rhs.id)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            }
    }
}
