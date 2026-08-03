import Foundation

enum RuntimeDashboardRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case sevenDays
    case thirtyDays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: OasesLocalization.localized("今天")
        case .sevenDays: OasesLocalization.localized("7 天")
        case .thirtyDays: OasesLocalization.localized("30 天")
        }
    }

    func startDate(relativeTo date: Date, calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let daysBack: Int
        switch self {
        case .today: daysBack = 0
        case .sevenDays: daysBack = 6
        case .thirtyDays: daysBack = 29
        }
        return calendar.date(byAdding: .day, value: -daysBack, to: startOfDay) ?? startOfDay
    }
}

private func decodeRuntimeString<C: KeyedDecodingContainerProtocol>(
    _ container: C,
    forKey key: C.Key
) -> String? {
    if let value = try? container.decodeIfPresent(String.self, forKey: key) {
        return value
    }
    if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
        return String(value)
    }
    if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
        return String(value)
    }
    return nil
}

struct RuntimeDashboardSummary: Decodable, Sendable {
    let generatedAtMs: Int64
    let today: RuntimeTodaySummary
    let rolling30m: RuntimeRollingSummary
    let topModelsToday: [RuntimeTopModel]?
    let modelCostRank: [RuntimeModelCostRank]?
    let trafficTimeline: [RuntimeTrafficPoint]?
    let todayRequestHealthTimeline: RuntimeRequestHealthTimeline?
    let tokenMix: [RuntimeTokenMixSegment]?
    let channelHealth: [RuntimeChannelHealth]?
    let recentFailures: [RuntimeRecentFailure]?

    private enum CodingKeys: String, CodingKey {
        case generatedAtMs
        case today
        case rolling30m = "rolling30M"
        case topModelsToday
        case modelCostRank
        case trafficTimeline
        case todayRequestHealthTimeline
        case tokenMix
        case channelHealth
        case recentFailures
    }

    var lastUpdated: Date {
        Date(timeIntervalSince1970: TimeInterval(generatedAtMs) / 1_000)
    }
}

struct RuntimeTopModel: Decodable, Sendable {
    let model: String
    let calls: Int
    let tokens: Int64
    let cost: Double
    let successRate: Double
}

struct RuntimeModelCostRank: Decodable, Sendable {
    let model: String
    let calls: Int
    let tokens: Int64
    let cost: Double
    let successRate: Double
    let costShare: Double
}

struct RuntimeTodaySummary: Decodable, Sendable {
    let totalCalls: Int
    let successCalls: Int
    let failureCalls: Int
    let successRate: Double
    let totalTokens: Int64
    let totalCost: Double
    let averageLatencyMs: Double?
    let zeroTokenCalls: Int
}

struct RuntimeRollingSummary: Decodable, Sendable {
    let rpm: Double
    let tpm: Double
    let totalCalls: Int
    let totalTokens: Int64
}

struct RuntimeTrafficPoint: Decodable, Sendable {
    let bucketMs: Int64
    let calls: Int
    let tokens: Int64
    let success: Int
    let failure: Int
}

struct RuntimeRequestHealthTimeline: Decodable, Sendable {
    let fromMs: Int64
    let toMs: Int64
    let bucketMs: Int64
    let successCalls: Int
    let failureCalls: Int
    let totalCalls: Int
    let successRate: Double
    let points: [RuntimeRequestHealthPoint]
}

struct RuntimeRequestHealthPoint: Decodable, Sendable {
    let bucketMs: Int64
    let calls: Int
    let tokens: Int64
    let success: Int
    let failure: Int
    let successRate: Double
    let failureRate: Double
    let tone: String
    let intensity: Double
    let future: Bool
}

struct RuntimeTokenMixSegment: Decodable, Sendable {
    let key: String
    let tokens: Int64
    let share: Double
}

struct RuntimeChannelHealth: Decodable, Sendable {
    let authIndex: String
    let authLabel: String?
    let account: String?
    let channel: String?
    let source: String?
    let calls: Int
    let failures: Int
    let failureRate: Double
    let successRate: Double
    let tokens: Int64
    let cost: Double
    let averageLatencyMs: Double?
    let tone: String

    private enum CodingKeys: String, CodingKey {
        case authIndex
        case authLabel
        case account
        case channel
        case source
        case calls
        case failures
        case failureRate
        case successRate
        case tokens
        case cost
        case averageLatencyMs
        case tone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authIndex = decodeRuntimeString(container, forKey: .authIndex) ?? ""
        authLabel = try container.decodeIfPresent(String.self, forKey: .authLabel)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        calls = try container.decode(Int.self, forKey: .calls)
        failures = try container.decode(Int.self, forKey: .failures)
        failureRate = try container.decode(Double.self, forKey: .failureRate)
        successRate = try container.decode(Double.self, forKey: .successRate)
        tokens = try container.decode(Int64.self, forKey: .tokens)
        cost = try container.decode(Double.self, forKey: .cost)
        averageLatencyMs = try container.decodeIfPresent(Double.self, forKey: .averageLatencyMs)
        tone = try container.decode(String.self, forKey: .tone)
    }
}

struct RuntimeRecentFailure: Decodable, Sendable {
    let timestampMs: Int64
    let model: String
    let apiKeyHash: String
    let sourceHash: String
    let authIndex: String
    let authLabel: String?
    let account: String?
    let channel: String?
    let source: String?
    let endpoint: String
    let durationMs: Double?
    let failStatusCode: Int?
    let failSummary: String?

    private enum CodingKeys: String, CodingKey {
        case timestampMs
        case model
        case apiKeyHash
        case sourceHash
        case authIndex
        case authLabel
        case account
        case channel
        case source
        case endpoint
        case durationMs
        case failStatusCode
        case failSummary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestampMs = try container.decode(Int64.self, forKey: .timestampMs)
        model = try container.decode(String.self, forKey: .model)
        apiKeyHash = try container.decode(String.self, forKey: .apiKeyHash)
        sourceHash = try container.decode(String.self, forKey: .sourceHash)
        authIndex = decodeRuntimeString(container, forKey: .authIndex) ?? ""
        authLabel = try container.decodeIfPresent(String.self, forKey: .authLabel)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        channel = try container.decodeIfPresent(String.self, forKey: .channel)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        endpoint = try container.decode(String.self, forKey: .endpoint)
        durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs)
        failStatusCode = try container.decodeIfPresent(Int.self, forKey: .failStatusCode)
        failSummary = try container.decodeIfPresent(String.self, forKey: .failSummary)
    }
}
