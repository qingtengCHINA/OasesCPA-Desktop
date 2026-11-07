import Foundation

enum RuntimeOAuthProvider: String, CaseIterable, Identifiable, Sendable {
    case codex
    case anthropic
    case antigravity
    case kimi
    case xai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .anthropic: "Anthropic Claude"
        case .antigravity: "Google Antigravity"
        case .kimi: "Kimi"
        case .xai: "xAI / Grok"
        }
    }

    var subtitle: String {
        switch self {
        case .codex: OasesLocalization.localized("浏览器 OAuth + PKCE")
        case .anthropic: OasesLocalization.localized("浏览器 OAuth + PKCE")
        case .antigravity: OasesLocalization.localized("浏览器 OAuth")
        case .kimi: OasesLocalization.localized("设备授权码")
        case .xai: OasesLocalization.localized("设备授权码")
        }
    }

    var systemImage: String {
        switch self {
        case .codex: "sparkles"
        case .anthropic: "brain"
        case .antigravity: "wand.and.stars"
        case .kimi: "moon.stars"
        case .xai: "bolt.horizontal.circle"
        }
    }

    var sendsWebUIFlag: Bool {
        switch self {
        case .codex, .anthropic, .antigravity, .xai: true
        case .kimi: false
        }
    }

    var supportsManualCallback: Bool {
        switch self {
        case .codex, .anthropic, .antigravity: true
        case .kimi, .xai: false
        }
    }
}

struct RuntimeOAuthStartResponse: Decodable, Sendable {
    let url: String
    let state: String?
}

enum RuntimeOAuthStatus: String, Decodable, Sendable {
    case ok
    case wait
    case error
    case unknown

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self).lowercased()
        self = RuntimeOAuthStatus(rawValue: value) ?? .unknown
    }
}

struct RuntimeOAuthStatusResponse: Decodable, Sendable {
    let status: RuntimeOAuthStatus
    let error: String?
}

struct RuntimeOAuthCallbackResponse: Decodable, Sendable {
    let status: RuntimeOAuthStatus
    let error: String?
}
