import Foundation
import XCTest
@testable import OasesCPA

final class CPAQuickConfigTests: XCTestCase {
    func testCLIProxyAPIQuickConfigUsesExactManagementKeys() {
        XCTAssertEqual(
            RuntimeCPAQuickConfigField.allCases.map(\.endpointPath),
            [
                "debug",
                "usage-statistics-enabled",
                "logging-to-file",
                "request-log",
                "ws-auth",
                "force-model-prefix",
                "quota-exceeded/switch-project",
                "quota-exceeded/switch-preview-model",
                "request-retry",
                "max-retry-credentials",
                "max-retry-interval",
                "disable-cooling",
                "oauth-request-scoped-errors",
                "logs-max-total-size-mb",
                "error-logs-max-files",
                "proxy-url",
                "response-compression/enabled",
                "routing/strategy"
            ]
        )
        // Measured on v8.0.51 (docs/acceptance/engine-v8.0.51-probe.md): disable-cooling and
        // response-compression have no endpoint (404) and go through config.yaml.
        XCTAssertEqual(RuntimeCPAQuickConfigField.disableCooling.transport, .yaml(path: ["disable-cooling"]))
        XCTAssertEqual(RuntimeCPAQuickConfigField.responseCompression.transport, .yaml(path: ["response-compression", "enabled"]))
        XCTAssertEqual(RuntimeCPAQuickConfigField.maxRetryCredentials.transport, .endpoint)
        XCTAssertEqual(RuntimeCPAQuickConfigField.maxRetryCredentials.valueKind, .integer)
        XCTAssertEqual(RuntimeCPAQuickConfigField.oauthRequestScopedErrors.transport, .endpoint)
        XCTAssertTrue(RuntimeCPAQuickConfigField.oauthRequestScopedErrors.isReadOnly)
        XCTAssertEqual(RuntimeCPAQuickConfigField.allCases.filter(\.isReadOnly), [.oauthRequestScopedErrors])
        XCTAssertEqual(RuntimeCPAQuickConfiguration.default.responseCompression, true, "the engine's default when the key is absent")
        for field in [RuntimeCPAQuickConfigField.disableCooling, .responseCompression, .maxRetryCredentials, .oauthRequestScopedErrors] {
            XCTAssertNotEqual(OasesLocalization.localized(field.title, language: .english), field.title, field.rawValue)
        }
        XCTAssertEqual(RuntimeCPAQuickConfigField.routingStrategy.responseKey, "strategy")
        XCTAssertEqual(RuntimeCPAQuickConfigField.quotaSwitchProject.responseKey, "switch-project")
    }

    func testQuickConfigValuesDecodeTypedEndpointResponses() throws {
        let debug = try RuntimeCPAQuickConfigValue.decode(
            from: Data(#"{"debug":true}"#.utf8),
            for: .debug
        )
        let retry = try RuntimeCPAQuickConfigValue.decode(
            from: Data(#"{"request-retry":4}"#.utf8),
            for: .requestRetry
        )
        let strategy = try RuntimeCPAQuickConfigValue.decode(
            from: Data(#"{"strategy":"weighted-round-robin"}"#.utf8),
            for: .routingStrategy
        )

        XCTAssertEqual(debug, .bool(true))
        XCTAssertEqual(retry, .integer(4))
        XCTAssertEqual(strategy, .string("weighted-round-robin"))
    }

    func testQuickConfigPatchPayloadAlwaysUsesValueWrapper() throws {
        let payload = try ManagementAPIClient.quickConfigurationPatchBody(
            .string("http://127.0.0.1:7890")
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), ["value"])
        XCTAssertEqual(object["value"] as? String, "http://127.0.0.1:7890")
    }

    @MainActor
    func testStoreKeepsOnlyFailedFieldsDirtyForRetry() async {
        let baseline = RuntimeCPAQuickConfiguration.default
        let store = CPAQuickConfigStore(
            loadOperation: { _, _ in
                RuntimeCPAQuickConfigLoadResult(configuration: baseline, errors: [:])
            },
            saveOperation: { field, _, _, _ in
                if field == .requestLog {
                    throw TestError.failed
                }
            }
        )
        let baseURL = URL(string: "http://127.0.0.1:8317")!

        await store.load(baseURL: baseURL, managementKey: "test-key")
        store.setValue(.bool(true), for: .requestLog)
        store.setValue(.integer(5), for: .requestRetry)

        XCTAssertTrue(store.isDirty)
        await store.save(baseURL: baseURL, managementKey: "test-key")

        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.changedFields, [.requestLog])
        XCTAssertEqual(store.baseline[.requestRetry], .integer(5))
        XCTAssertEqual(store.draft[.requestLog], .bool(true))
        XCTAssertNotNil(store.fieldErrors[.requestLog])
    }

    @MainActor
    func testStoreClearsDirtyAfterAllChangedFieldsSucceed() async {
        let store = CPAQuickConfigStore(
            loadOperation: { _, _ in
                RuntimeCPAQuickConfigLoadResult(
                    configuration: .default,
                    errors: [.proxyURL: "not available"]
                )
            },
            saveOperation: { _, _, _, _ in }
        )
        let baseURL = URL(string: "http://127.0.0.1:8317")!

        await store.load(baseURL: baseURL, managementKey: "test-key")
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.fieldErrors[.proxyURL], "not available")

        store.setValue(.bool(true), for: .debug)
        await store.save(baseURL: baseURL, managementKey: "test-key")

        XCTAssertFalse(store.isDirty)
        XCTAssertNil(store.fieldErrors[.debug])
    }

    // MARK: - Task 19 (#8): measured shapes of CLIProxyAPI v8.0.51

    /// `GET /v0/management/max-retry-credentials` → `{"max-retry-credentials": N}`; the rules of
    /// `oauth-request-scoped-errors` are a map of channels to rule lists (null when there are
    /// none), shown as a rule count.
    func testNewEndpointFieldsDecodeTheMeasuredShapes() throws {
        XCTAssertEqual(try RuntimeCPAQuickConfigValue.decode(from: Data(#"{"max-retry-credentials":2}"#.utf8), for: .maxRetryCredentials), .integer(2))
        XCTAssertEqual(try RuntimeCPAQuickConfigValue.decode(from: Data(#"{"oauth-request-scoped-errors":null}"#.utf8), for: .oauthRequestScopedErrors), .integer(0))
        let rules = #"{"oauth-request-scoped-errors":{"codex":[{"status":400,"match":["prompt is too long"],"action":"stop"}],"claude":[{"status":400,"action":"stop"},{"status":500,"action":"continue"}]}}"#
        XCTAssertEqual(try RuntimeCPAQuickConfigValue.decode(from: Data(rules.utf8), for: .oauthRequestScopedErrors), .integer(3))
        XCTAssertThrowsError(try RuntimeCPAQuickConfigValue.decode(from: Data(#"{"oauth-request-scoped-errors":true}"#.utf8), for: .oauthRequestScopedErrors))
    }

    /// Changing disable-cooling reads config.yaml, changes that one line and writes the file back;
    /// the engine has no `/v0/management/disable-cooling` (404 on v8.0.51).
    func testQuickConfigRoutesYAMLFieldsThroughConfigFile() async throws {
        defer { URLProtocolStub.reset() }
        let yaml = "host: \"127.0.0.1\"\nport: 18316\napi-keys: []\nrequest-retry: 3 # keep\n"
        URLProtocolStub.install { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v0/management/config.yaml"):
                return URLProtocolStub.Result(response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                                                        headerFields: ["Content-Type": "application/yaml; charset=utf-8"])!,
                                              data: Data(yaml.utf8))
            case ("PUT", "/v0/management/config.yaml"): return .json(200, #"{"changed":["config"],"ok":true}"#, for: request)
            default: return .json(404, "", for: request)
            }
        }
        let client = ManagementAPIClient(session: URLProtocolStub.makeSession())
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:18316"))
        try await client.updateQuickConfigurationValue(.bool(true), for: .disableCooling, baseURL: base, managementKey: "test-management-key")
        let requests = URLProtocolStub.recordedRequests
        XCTAssertEqual(requests.map { "\($0.0.httpMethod ?? "") \($0.0.url?.path ?? "")" },
                       ["GET /v0/management/config.yaml", "PUT /v0/management/config.yaml"])
        XCTAssertFalse(requests.contains { $0.0.url?.path == "/v0/management/disable-cooling" })
        XCTAssertEqual(requests[1].1.map { String(decoding: $0, as: UTF8.self) }, yaml + "disable-cooling: true\n", "one line added, the rest as read")
        XCTAssertEqual(requests[1].0.value(forHTTPHeaderField: "Authorization"), "Bearer test-management-key")

        // Reading: both YAML fields from ONE read of the file; absent keys are the engine defaults.
        URLProtocolStub.install { request, _ in
            switch request.url?.path {
            case "/v0/management/config.yaml":
                return URLProtocolStub.Result(response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!,
                                              data: Data((yaml + "disable-cooling: true\n").utf8))
            case "/v0/management/max-retry-credentials": return .json(200, #"{"max-retry-credentials":2}"#, for: request)
            case "/v0/management/oauth-request-scoped-errors": return .json(200, #"{"oauth-request-scoped-errors":null}"#, for: request)
            default: return .json(404, "", for: request)
            }
        }
        let loaded = await client.loadQuickConfiguration(baseURL: base, managementKey: "test-management-key")
        XCTAssertEqual(loaded.configuration.disableCooling, true)
        XCTAssertEqual(loaded.configuration.responseCompression, true, "absent: the engine default")
        XCTAssertEqual(loaded.configuration.maxRetryCredentials, 2)
        XCTAssertEqual(loaded.configuration.oauthRequestScopedErrorRules, 0)
        XCTAssertNil(loaded.errors[.disableCooling])
        XCTAssertEqual(URLProtocolStub.recordedRequests.filter { $0.0.url?.path == "/v0/management/config.yaml" }.count, 1)

        // The read-only rule count is never written.
        do {
            try await client.updateQuickConfigurationValue(.integer(1), for: .oauthRequestScopedErrors, baseURL: base, managementKey: "test-management-key")
            XCTFail("a read-only field must not be written")
        } catch {}
        XCTAssertFalse(URLProtocolStub.recordedRequests.contains { $0.0.httpMethod != "GET" })
    }

    /// A file the patcher does not understand is refused with the editor hint and nothing is
    /// written; so is a config in the v8 nested layout (its keys live elsewhere).
    func testYAMLFieldRefusesShapesItDoesNotUnderstand() async throws {
        defer { URLProtocolStub.reset() }
        for yaml in ["disable-cooling: false\ndisable-cooling: true\n", "config-version: 8\nrouting:\n  disable-cooling: false\n"] {
            URLProtocolStub.install { request, _ in
                request.httpMethod == "GET"
                    ? URLProtocolStub.Result(response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!, data: Data(yaml.utf8))
                    : .json(200, #"{"ok":true}"#, for: request)
            }
            let client = ManagementAPIClient(session: URLProtocolStub.makeSession())
            do {
                try await client.updateQuickConfigurationValue(.bool(true), for: .disableCooling,
                                                               baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:18316")), managementKey: "k")
                XCTFail("refused: \(yaml)")
            } catch {
                let text = error.localizedDescription
                XCTAssertTrue(text.contains("配置文件编辑器") || text.contains("configuration file editor"), text)
            }
            XCTAssertEqual(URLProtocolStub.recordedRequests.map { $0.0.httpMethod ?? "" }, ["GET"], "nothing written")
        }
    }

    /// Endpoint writes finish before a YAML field is written (an endpoint write rewrites
    /// config.yaml too; a parallel read-modify-write of the file would undo it).
    @MainActor
    func testStoreWritesYAMLFieldsAfterTheEndpointFields() async {
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [String] = []
            func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
        }
        let log = Log()
        let store = CPAQuickConfigStore(
            loadOperation: { _, _ in RuntimeCPAQuickConfigLoadResult(configuration: .default, errors: [:]) },
            saveOperation: { field, _, _, _ in
                if field.transport == .endpoint { try? await Task.sleep(nanoseconds: 30_000_000) }
                log.add(field.rawValue)
            }
        )
        let baseURL = URL(string: "http://127.0.0.1:18316")!
        await store.load(baseURL: baseURL, managementKey: "test-key")
        store.setValue(.bool(true), for: .disableCooling)
        store.setValue(.bool(false), for: .responseCompression)
        store.setValue(.integer(2), for: .maxRetryCredentials)
        store.setValue(.integer(9), for: .oauthRequestScopedErrors)
        XCTAssertFalse(store.changedFields.contains(.oauthRequestScopedErrors), "read-only: never a change")
        await store.save(baseURL: baseURL, managementKey: "test-key")
        XCTAssertEqual(log.all.first, "max-retry-credentials")
        XCTAssertEqual(Set(log.all.dropFirst()), ["disable-cooling", "response-compression/enabled"])
        XCTAssertFalse(store.isDirty)
    }
}

private enum TestError: Error {
    case failed
}
