import CryptoKit
import Foundation

/// Routing prefixes for openai-compatibility providers. A provider with a prefix of its own can
/// be pinned by a key (`pin-x/<model>` reaches only that provider), so a new provider gets one:
/// the gateway's `internalPrefixFor` (`gateway/provider-routing.mjs`), numbered like the panel's
/// `resolveProviderPrefix` (`utils/internalPrefix.ts`) so it never repeats a prefix in use. The
/// gateway itself does not number; it treats a prefix that more than one `prefix:` line of the
/// engine config carries as not unique and refuses to pin through it.
enum ProviderPrefixAllocator {
    /// "pin-" + the name in lower case with every run of characters outside [a-z0-9] turned
    /// into "-" and leading/trailing "-" removed. A name with nothing left (for example an
    /// all-Chinese one) uses the first 8 hex digits of the SHA-1 of the name's UTF-8 bytes, as
    /// given (not trimmed).
    static func internalPrefix(for name: String) -> String {
        var slug = ""
        var pendingDash = false
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash && !slug.isEmpty { slug.append("-") }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        if !slug.isEmpty { return "pin-" + slug }
        let digest = Insecure.SHA1.hash(data: Data(name.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "pin-" + String(hex.prefix(8))
    }

    /// The prefix to save: one the provider already has (trimmed, never changed); nil for a
    /// blank name; otherwise `internalPrefix(for:)` of the trimmed name, with "-2", "-3", …
    /// appended while that is in `taken` (compared trimmed and case-insensitively).
    static func resolve(prefix: String?, name: String?, taken: [String]) -> String? {
        let existing = (prefix ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty { return existing }
        let trimmedName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }
        let used = Set(taken.map(comparable).filter { !$0.isEmpty })
        let base = internalPrefix(for: trimmedName)
        var candidate = base
        var suffix = 2
        while used.contains(comparable(candidate)) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// A prefix as two prefixes are compared: trimmed and lower case. Leading and trailing "/"
    /// are dropped as well, because the engine and the gateway ignore them (`normalizePrefix`).
    static func comparable(_ prefix: String) -> String {
        var value = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("/") { value.removeFirst() }
        while value.hasSuffix("/") { value.removeLast() }
        return value.lowercased()
    }

    /// Every prefix in use: the openai-compatibility providers' (except the one named
    /// `excludingProviderNamed`, compared trimmed) and every direct provider credential's, because
    /// the gateway judges uniqueness by every `prefix:` line of the engine config. nil when a list
    /// is not known (not loaded, or its last read failed): then nothing is allocated automatically.
    static func takenPrefixes(
        openAICompatibility: [RuntimeOpenAICompatibility]?,
        directCredentials: [RuntimeDirectProviderKind: [RuntimeDirectProviderCredential]]?,
        excludingProviderNamed excluded: String?
    ) -> [String]? {
        guard let openAICompatibility, let directCredentials else { return nil }
        let excludedName = excluded?.trimmingCharacters(in: .whitespacesAndNewlines)
        var prefixes: [String] = []
        for provider in openAICompatibility {
            if let excludedName, provider.name.trimmingCharacters(in: .whitespacesAndNewlines) == excludedName { continue }
            prefixes.append(provider.prefix)
        }
        for kind in RuntimeDirectProviderKind.allCases {
            for credential in directCredentials[kind] ?? [] {
                prefixes.append(credential.prefix)
            }
        }
        return prefixes.filter { !comparable($0).isEmpty }
    }

    @MainActor
    static func takenPrefixes(from store: RuntimeDataStore, excludingProviderNamed excluded: String?) -> [String]? {
        takenPrefixes(
            openAICompatibility: store.hasLoadedOpenAICompatibility ? store.openAICompatibility : nil,
            directCredentials: store.hasLoadedDirectProviderCredentials ? store.directProviderCredentials : nil,
            excludingProviderNamed: excluded
        )
    }

    /// The prefix a new provider is saved with: what the user typed, else the allocated one.
    /// Fails when it would have to be allocated while the provider lists are not known.
    static func prefixForNewProvider(typed: String, name: String, taken: [String]?) -> Result<String, ProviderPrefixError> {
        let typedPrefix = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedPrefix.isEmpty { return .success(typedPrefix) }
        guard let taken else { return .failure(.providerListsNotLoaded) }
        return .success(resolve(prefix: nil, name: name, taken: taken) ?? "")
    }
}

enum ProviderPrefixError: LocalizedError, Equatable {
    /// The provider lists have not been read (or their last read failed), so a free prefix
    /// cannot be chosen.
    case providerListsNotLoaded

    var errorDescription: String? {
        switch self {
        case .providerListsNotLoaded:
            OasesLocalization.localized("请先刷新供应商列表，再保存新的 AI 服务（需要知道已在使用的前缀）。")
        }
    }
}
