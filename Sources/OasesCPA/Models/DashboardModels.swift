import SwiftUI

struct MetricSummary: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let caption: String
    let systemImage: String
    let tint: Color
}

struct TrafficPoint: Identifiable {
    let id = UUID()
    let label: String
    let requests: Double
    let tokens: Double
}

struct ProviderStatus: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let status: String
    let tint: Color
    let icon: String
}

struct RequestEvent: Identifiable {
    let id = UUID()
    let source: String
    let model: String
    let status: String
    let latency: String
    let time: String
    let isFailure: Bool
}

struct AccountHealth: Identifiable {
    let id = UUID()
    let name: String
    let provider: String
    let plan: String
    let remaining: Int
    let status: String
    let tint: Color
}

struct QuotaSummary: Identifiable {
    let id = UUID()
    let title: String
    let reset: String
    let remaining: Double
    let status: String
    let tint: Color
}
