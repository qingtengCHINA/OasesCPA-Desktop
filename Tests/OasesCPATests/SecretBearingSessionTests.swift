import XCTest
@testable import OasesCPA

/// Every client that sends or receives keys must use a session that writes nothing to disk:
/// the default `URLSession.shared` stores responses (including raw client API keys) in the
/// on-disk URL cache even when the request ignores cached data.
final class SecretBearingSessionTests: XCTestCase {
    private func assertStoresNothing(_ session: URLSession, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        let configuration = session.configuration
        XCTAssertNil(configuration.urlCache, "\(label): URL cache", file: file, line: line)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData, "\(label): cache policy", file: file, line: line)
        XCTAssertNil(configuration.httpCookieStorage, "\(label): cookie storage", file: file, line: line)
        XCTAssertFalse(configuration.httpShouldSetCookies, "\(label): sets cookies", file: file, line: line)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never, "\(label): accepts cookies", file: file, line: line)
        XCTAssertNil(configuration.urlCredentialStorage, "\(label): credential storage", file: file, line: line)
        XCTAssertFalse(session === URLSession.shared, "\(label): must not be URLSession.shared", file: file, line: line)
    }

    func testSecretBearingSessionStoresNothing() {
        assertStoresNothing(SecretBearingURLSession.shared, "shared secret-bearing session")
    }

    func testGatewayAdminClientDefaultSessionStoresNothing() {
        let client = GatewayAdminClient(baseURL: URL(string: "http://127.0.0.1:18320")!, managementKey: "k")
        assertStoresNothing(client.session, "GatewayAdminClient")
    }

    @MainActor
    func testDeploymentStoreGatewayClientStoresNothing() throws {
        let store = DeploymentStore(autoProbe: false)
        store.attachForTesting(topology: .gateway, managementKey: "k1", adminKey: "a")
        let client = try XCTUnwrap(store.gatewayAdminClient())
        assertStoresNothing(client.session, "DeploymentStore.gatewayAdminClient()")
    }

    func testManagementAPIClientDefaultSessionStoresNothing() {
        // Engine management (`/v0/management/api-keys` returns the client keys) and the CPA
        // Manager Plus admin API both go through this client.
        assertStoresNothing(ManagementAPIClient().session, "ManagementAPIClient")
    }

    func testOpenRouterKeyExchangeSessionStoresNothing() {
        // The token exchange returns an API key; the model list sends one.
        assertStoresNothing(RuntimeOpenRouterOAuth.session, "RuntimeOpenRouterOAuth")
    }

    func testLifecycleHealthCheckSessionStoresNothing() {
        // The engine health check sends the management key and reads the engine config.
        assertStoresNothing(RuntimeLifecycleService().session, "RuntimeLifecycleService")
    }
}
