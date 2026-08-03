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
                "max-retry-interval",
                "logs-max-total-size-mb",
                "error-logs-max-files",
                "proxy-url",
                "routing/strategy"
            ]
        )
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
}

private enum TestError: Error {
    case failed
}
