import Foundation

/// Masks secrets in text that may reach the UI, logs or errors (for example a server error
/// body that echoes a key).
///
/// Two passes: first every given secret verbatim (longest first, so a secret that contains
/// another is masked whole), then every key shape the stack issues:
/// - `cpa_` + 64 hex: the engine management key (the gateway admin key) the installer writes
/// - `cpamp_` + 64 hex: the CPA Manager Plus admin key
/// - `sk-pk-` + 43 base64url: a model-pack key (gateway packs.mjs)
/// - `oases-int-` + 43 base64url: the gateway's internal engine key (gateway bootstrap.mjs)
/// - `sk-` + at least 24 key characters: a client API key; never inside a word, so text such
///   as "risk-assessment-…" is left alone
enum SecretRedactor {
    static let mask = "••••"

    /// Patterns as strings (compiled per call: redaction runs on error paths only, and this
    /// keeps the constant `Sendable` on every SDK).
    private static let keyShapes = [
        #"(?<![A-Za-z0-9_])cpamp_[0-9A-Fa-f]{64,}"#,
        #"(?<![A-Za-z0-9_])cpa_[0-9A-Fa-f]{64,}"#,
        #"(?<![A-Za-z0-9_-])sk-pk-[A-Za-z0-9_-]{43,}"#,
        #"(?<![A-Za-z0-9_-])oases-int-[A-Za-z0-9_-]{43,}"#,
        #"(?<![A-Za-z0-9_-])sk-[A-Za-z0-9_-]{24,}"#
    ]

    static func redact(_ text: String, secrets: [String]) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        let literal = secrets
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.count > $1.count }
        for secret in literal {
            result = result.replacingOccurrences(of: secret, with: mask)
        }
        for pattern in keyShapes {
            guard let shape = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = shape.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: mask)
            )
        }
        return result
    }
}
