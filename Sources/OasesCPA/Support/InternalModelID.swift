import Foundation

/// Internal, provider-pinned model ids (`pin-<slug>/<model>`) and the public names shown for them.
///
/// The gateway rewrites a request that pins a provider to `<prefix>/<model>` before it reaches the
/// engine, and a single-provider health check uses the same form, so the engine's usage records and
/// everything CPA Manager Plus derives from them (analytics, monitoring, dashboard) can contain
/// `pin-x/…` names. Every model name that reaches the interface from the engine or CPA Manager Plus
/// goes through `publicName(_:)`. Only the configuration screens (a compatible provider's prefix
/// field, the YAML editor) show prefixes as they are.
///
/// Prefixes a user chose that do not start with `pin-` (for example `team-a/…`) are routing
/// prefixes too, but they are the user's own configuration and are shown as they are.
enum InternalModelID {
    /// `^pin-[^/]+/`, the panel's `INTERNAL_PREFIX_PATTERN` (`utils/internalPrefix.ts`).
    static func isInternal(_ id: String) -> Bool {
        internalHeadLength(of: Substring(id)) != nil
    }

    /// Removes every leading `pin-<x>/` segment; a `cc-` directly in front of an internal id goes
    /// with it ("cc-pin-a/glm-5" → "glm-5"). Anything else is returned unchanged.
    static func publicName(_ id: String) -> String {
        var rest = Substring(id)
        var stripped = false
        while true {
            if let length = internalHeadLength(of: rest) {
                rest = rest.dropFirst(length)
                stripped = true
                continue
            }
            if rest.hasPrefix("cc-"), let length = internalHeadLength(of: rest.dropFirst(3)) {
                rest = rest.dropFirst(3 + length)
                stripped = true
                continue
            }
            break
        }
        return stripped ? String(rest) : id
    }

    /// Free text (an error summary, a log line) with every internal head removed from the model ids
    /// it mentions: "model pin-a/glm-5 failed" → "model glm-5 failed". A head counts only at the
    /// start of a word, so "my-pin-x/model" stays as it is.
    static func publicText(_ text: String) -> String {
        guard text.contains("pin-") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return internalHeadInText.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// The names under which usage of `model` may be recorded: the bare id first, then
    /// `<prefix>/<model>` for every non-empty prefix, without duplicates (iOS `analyticsModels`).
    static func queryVariants(for model: String, prefixes: [String]) -> [String] {
        var result = [model]
        for prefix in prefixes {
            let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let variant = "\(trimmed)/\(model)"
            if !result.contains(variant) { result.append(variant) }
        }
        return result
    }

    /// Rows with the same public name folded into one with `merge`, in the order in which each
    /// public name first appears. `merge` receives the accumulated row and the next one.
    static func mergeByPublicName<Row>(_ rows: [Row], name: (Row) -> String, merge: (Row, Row) -> Row) -> [Row] {
        var order: [String] = []
        var merged: [String: Row] = [:]
        for row in rows {
            let key = publicName(name(row))
            if let existing = merged[key] {
                merged[key] = merge(existing, row)
            } else {
                order.append(key)
                merged[key] = row
            }
        }
        return order.compactMap { merged[$0] }
    }

    /// Every entry of `options` whose public name is `publicName`, with the public name itself
    /// first (a filter on the public name must also match the internal ids it stands for).
    static func rawNames(matching publicName: String, in options: [String]) -> [String] {
        var result = [publicName]
        for option in options where Self.publicName(option) == publicName && !result.contains(option) {
            result.append(option)
        }
        return result
    }

    /// Public names, without duplicates, in the order of their first appearance.
    static func publicNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let value = publicName(name)
            if seen.insert(value).inserted { result.append(value) }
        }
        return result
    }

    // MARK: - Internals

    /// The length of a `pin-<x>/` head at the start of `value` (`<x>` is at least one character
    /// and contains no "/"), or nil.
    private static func internalHeadLength(of value: Substring) -> Int? {
        guard value.hasPrefix("pin-") else { return nil }
        let afterPin = value.dropFirst(4)
        guard let slash = afterPin.firstIndex(of: "/"), slash > afterPin.startIndex else { return nil }
        return 4 + afterPin.distance(from: afterPin.startIndex, to: slash) + 1
    }

    /// Repeated `(cc-)?pin-<x>/` heads at the start of a word.
    private static let internalHeadInText = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_\-./])(?:(?:cc-)?pin-[^/\s]+/)+"#
    )
}
