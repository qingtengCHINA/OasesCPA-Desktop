import Foundation

/// Readable messages of the web search page.
enum SearchProvidersError: LocalizedError, Equatable {
    case invalid([String])
    case message(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let messages): messages.joined(separator: "\n")
        case .message(let text): text
        }
    }

    /// The search service's codes as text; a key the user typed is masked out of anything else.
    static func map(_ error: Error, typedKey: String?) -> Error {
        guard case GatewayAdminError.server(_, let code, let message) = error else { return error }
        switch code {
        case "test_throttled":
            // "请 N 秒后再测试（服务商限制测试频率）。": the wait is taken from the gateway's text.
            if let seconds = message.split(whereSeparator: { !$0.isNumber }).first.flatMap({ Int($0) }) {
                return SearchProvidersError.message(OasesLocalization.localizedFormat("测试过于频繁，请 %lld 秒后再试（服务商限制测试频率）。", seconds))
            }
            return SearchProvidersError.message(OasesLocalization.localized("测试过于频繁，请稍后再试（服务商限制测试频率）。"))
        case "unknown_provider":
            return SearchProvidersError.message(OasesLocalization.localized("网关不认识这个搜索服务商，请刷新后再试。"))
        case "invalid_request":
            return SearchProvidersError.message(OasesLocalization.localizedFormat("网关拒绝了这次修改：%@", mask(message, typedKey: typedKey)))
        default:
            guard let typedKey, !typedKey.isEmpty else { return error }
            return SearchProvidersError.message(mask(error.localizedDescription, typedKey: typedKey))
        }
    }

    static func mask(_ text: String, typedKey: String?) -> String {
        SecretRedactor.redact(text, secrets: [typedKey].compactMap { $0 }.filter { !$0.isEmpty })
    }
}

/// The gateway's web search providers: list, save (enable, key, daily limit), test, the daily
/// usage and the call log. Provider keys are never shown: only `key_hint`.
@MainActor
final class SearchProvidersStore: GatewayWorkbenchStore {
    @Published private(set) var providers: [GatewaySearchProvider] = []
    @Published private(set) var usage: GatewaySearchUsage?
    @Published private(set) var logs: [GatewaySearchLogEntry] = []
    /// The latest test per provider id (from this session; the gateway's `last_test` otherwise).
    @Published private(set) var testResults: [String: GatewaySearchTestResult] = [:]
    /// The log shows one provider only (nil: all).
    @Published private(set) var logProvider: String?

    let usageDays: Int
    let logLimit: Int

    init(provider: GatewayClientProviding, usageDays: Int = 14, logLimit: Int = 100) {
        self.usageDays = usageDays
        self.logLimit = logLimit
        super.init(provider: provider, section: .webSearch)
    }

    override func load(using client: GatewayAdminClient) async throws {
        // One read after another: a rejected key gets one 401.
        let providers = try await client.searchProviders()
        try ensureCurrentLoad()
        let usage = try await client.searchUsage(days: usageDays)
        try ensureCurrentLoad()
        let logs = try await client.searchLogs(limit: logLimit, provider: logProvider)
        try ensureCurrentLoad()
        self.providers = providers
        self.usage = usage
        self.logs = logs
    }

    func result(for id: String) -> GatewaySearchTestResult? {
        testResults[id] ?? providers.first { $0.id == id }?.lastTest
    }

    /// Saves one provider. The typed key (if any) is sent once and not kept by the store.
    func save(_ change: GatewaySearchProviderSave) async -> Bool {
        let problems = change.validationErrors()
        var typedKey: String?
        if case .set(let key) = change.apiKey { typedKey = key }
        return await mutate { client in
            guard problems.isEmpty else { throw SearchProvidersError.invalid(problems) }
            do {
                _ = try await client.saveSearchProvider(change)
            } catch {
                throw SearchProvidersError.map(error, typedKey: typedKey)
            }
        }
    }

    /// Tests a typed key, or the saved one (`apiKey` nil). A real request to the provider.
    func test(_ id: String, apiKey: String? = nil) async -> Bool {
        await mutate(reloadAfter: true) { [weak self] client in
            do {
                var result = try await client.testSearchProvider(id, apiKey: apiKey)
                // The provider's message may echo the key just typed: it is masked before it is
                // kept, so no later view of the result can show it.
                result.message = SearchProvidersError.mask(result.message, typedKey: apiKey)
                self?.testResults[id] = result
            } catch {
                throw SearchProvidersError.map(error, typedKey: apiKey)
            }
        }
    }

    func showLogs(of provider: String?) {
        guard provider != logProvider else { return }
        logProvider = provider
        refreshNow()
    }
}
