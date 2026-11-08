import XCTest
@testable import OasesCPA

/// A page store that reads one value from the gateway.
@MainActor
private final class ProbeWorkbenchStore: GatewayWorkbenchStore {
    private(set) var value: String?
    private(set) var loadCount = 0
    /// When set, the next load waits here after its request (not cancellable), before it
    /// applies its result.
    var gate: CheckedContinuation<Void, Never>?
    var holdNextLoad = false

    override func load(using client: GatewayAdminClient) async throws {
        loadCount += 1
        let number = loadCount
        let answer: RuntimeJSONValue = try await client.get("/cpa-admin/host/status")
        if holdNextLoad {
            holdNextLoad = false
            await withCheckedContinuation { gate = $0 }
        }
        try ensureCurrentLoad()
        if case .object(let object) = answer, case .string(let text)? = object["value"] {
            value = "\(text)#\(number)"
        }
    }
}

@MainActor
final class GatewayWorkbenchStoreTests: XCTestCase {
    override func tearDown() async throws {
        URLProtocolStub.reset()
        try await super.tearDown()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func stub(_ status: Int, _ body: String) {
        URLProtocolStub.install { request, _ in .json(status, body, for: request) }
    }

    func testUnauthorizedLatchesAndStopsFurtherRequests() async throws {
        stub(401, #"{"error":"Unauthorized management key"}"#)
        let provider = FakeGatewayClientProvider()
        let store = ProbeWorkbenchStore(provider: provider)
        store.activate()
        try await waitUntil { store.phase == .unavailable(.credentialsRejected) }
        XCTAssertEqual(store.phase, .unavailable(.credentialsRejected))
        XCTAssertEqual(provider.reportCount, 1)
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 1)

        store.refreshNow()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 1, "a latched key sends nothing more")
        XCTAssertEqual(provider.reportCount, 1)
        XCTAssertEqual(store.phase, .unavailable(.credentialsRejected))

        // Only the user's "verify again" clears it.
        stub(200, #"{"value":"ok"}"#)
        store.retryAuthentication()
        try await waitUntil { store.phase == .loaded }
        XCTAssertEqual(provider.retryCount, 1)
        XCTAssertEqual(store.value, "ok#2")
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 1, "install() started a fresh recording")
        store.deactivate()
    }

    func testUnauthorizedReportsTheRejectedClientKeyNotTheCurrentOne() async throws {
        // The 401 for "k1" arrives after the user switched to "k2": the store reports "k1"
        // (the key the gateway rejected), the provider ignores it, and the page reloads with "k2".
        let release = DispatchSemaphore(value: 0)
        URLProtocolStub.install { request, _ in
            if request.value(forHTTPHeaderField: "x-management-key") == "k1" {
                _ = release.wait(timeout: .now() + 5)
                return .json(401, #"{"error":"Unauthorized management key"}"#, for: request)
            }
            return .json(200, #"{"value":"fresh"}"#, for: request)
        }
        let provider = FakeGatewayClientProvider()
        provider.currentKey = "k1"
        let store = ProbeWorkbenchStore(provider: provider)
        store.activate()
        try await waitUntil { URLProtocolStub.recordedRequests.count == 1 }
        provider.currentKey = "k2"
        release.signal()

        try await waitUntil { store.phase == .loaded }
        XCTAssertEqual(provider.rejectedKeys, ["k1"], "the rejected key is the client's own key")
        XCTAssertFalse(provider.latched, "a rejection of a key that is no longer current latches nothing")
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.value, "fresh#2")
        let keys = URLProtocolStub.recordedRequests.map { $0.0.value(forHTTPHeaderField: "x-management-key") }
        XCTAssertEqual(keys, ["k1", "k2"], "the rejected key is never sent again")
        store.deactivate()
    }

    func testLatchAllowsADifferentKey() {
        var latch = GatewayAuthLatch()
        XCTAssertTrue(latch.allows(key: "k1"))
        latch.reject(key: "k1")
        XCTAssertFalse(latch.allows(key: "k1"))
        XCTAssertTrue(latch.allows(key: "k2"))
        latch.clear()
        XCTAssertTrue(latch.allows(key: "k1"))
    }

    func testLatchKeepsOnlyAFingerprint() {
        var latch = GatewayAuthLatch()
        latch.reject(key: "secret-management-key")
        XCTAssertFalse(String(describing: latch).contains("secret-management-key"))
        XCTAssertFalse(String(reflecting: latch).contains("secret-management-key"))
    }

    func testFailedRefreshKeepsLoadedDataAndShowsBanner() async throws {
        stub(200, #"{"value":"first"}"#)
        let store = ProbeWorkbenchStore(provider: FakeGatewayClientProvider())
        store.activate()
        try await waitUntil { store.phase == .loaded }
        XCTAssertEqual(store.value, "first#1")
        XCTAssertNil(store.actionError)

        stub(500, #"{"error":"Internal error"}"#)
        store.refreshNow()
        try await waitUntil { store.actionError != nil }
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(store.value, "first#1")
        XCTAssertNotNil(store.actionError)

        stub(200, #"{"value":"second"}"#)
        store.refreshNow()
        try await waitUntil { store.value == "second#3" }
        XCTAssertNil(store.actionError, "a successful refresh clears the banner")
        store.deactivate()
    }

    func testFirstLoadFailureIsAFailedPhase() async throws {
        stub(502, #"{"error":"Engine provider list unavailable","code":"management_unavailable"}"#)
        let store = ProbeWorkbenchStore(provider: FakeGatewayClientProvider())
        store.activate()
        try await waitUntil { if case .failed = store.phase { return true } else { return false } }
        guard case .failed(let message) = store.phase else { return XCTFail("expected failed, got \(store.phase)") }
        XCTAssertFalse(message.isEmpty)
        store.deactivate()
    }

    func testUnavailableGatewaySendsNothing() async throws {
        stub(200, #"{"value":"x"}"#)
        for availability in [GatewayAvailability.notAttached, .needsUpgrade, .dockerUnsupported] {
            let provider = FakeGatewayClientProvider()
            provider.availability = availability
            let store = ProbeWorkbenchStore(provider: provider)
            store.activate()
            XCTAssertEqual(store.phase, .unavailable(availability))
            let ok = await store.mutate { _ in XCTFail("no mutation without a client") }
            XCTAssertFalse(ok)
            store.deactivate()
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(URLProtocolStub.recordedRequests.isEmpty)
    }

    func testStaleLoadResultIsDiscarded() async throws {
        stub(200, #"{"value":"v"}"#)
        let store = ProbeWorkbenchStore(provider: FakeGatewayClientProvider())
        store.holdNextLoad = true
        store.activate()
        try await waitUntil { store.gate != nil }

        store.refreshNow()   // load 2 replaces the held load 1
        try await waitUntil { store.value == "v#2" }

        store.gate?.resume()
        store.gate = nil
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.value, "v#2", "the superseded load must not overwrite newer data")
        XCTAssertEqual(store.phase, .loaded)
        store.deactivate()
    }

    func testMutateRereadsAfterSuccessAndReportsFailures() async throws {
        stub(200, #"{"value":"before"}"#)
        let provider = FakeGatewayClientProvider()
        let store = ProbeWorkbenchStore(provider: provider)
        store.activate()
        try await waitUntil { store.phase == .loaded }

        stub(200, #"{"value":"after"}"#)
        let saved = await store.mutate { client in
            let _: RuntimeJSONValue = try await client.post("/cpa-admin/permissions/api/save", body: ["action": "set_label"])
        }
        XCTAssertTrue(saved)
        XCTAssertFalse(store.isMutating)
        XCTAssertEqual(store.value, "after#2", "a successful mutation reloads before it returns")
        XCTAssertEqual(URLProtocolStub.recordedRequests.map { $0.0.httpMethod }, ["POST", "GET"])

        stub(409, #"{"success":false,"error":"The internal engine key is managed by the gateway","code":"internal_key"}"#)
        let refused = await store.mutate { client in
            let _: RuntimeJSONValue = try await client.post("/cpa-admin/permissions/api/save", body: ["action": "delete_key"])
        }
        XCTAssertFalse(refused)
        XCTAssertNotNil(store.actionError)
        XCTAssertEqual(store.phase, .loaded)
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 1, "a failed mutation does not reload")

        stub(401, #"{"error":"Unauthorized management key"}"#)
        let rejected = await store.mutate { client in
            let _: RuntimeJSONValue = try await client.post("/cpa-admin/permissions/api/save", body: ["action": "set_label"])
        }
        XCTAssertFalse(rejected)
        XCTAssertEqual(provider.reportCount, 1)
        XCTAssertEqual(store.phase, .unavailable(.credentialsRejected))
        store.deactivate()
    }

    func testMutateRereadsBeforeSaving() async throws {
        stub(200, #"{"value":"server"}"#)
        let store = ProbeWorkbenchStore(provider: FakeGatewayClientProvider())
        store.activate()
        try await waitUntil { store.phase == .loaded }
        URLProtocolStub.install { request, _ in .json(200, #"{"value":"fresh"}"#, for: request) }

        let saved = await store.mutate(
            rereading: { client in
                let current: RuntimeJSONValue = try await client.get("/cpa-admin/permissions/api/data")
                return current
            },
            then: { client, current in
                XCTAssertEqual(current, .object(["value": .string("fresh")]))
                let _: RuntimeJSONValue = try await client.post("/cpa-admin/permissions/api/save", body: ["action": "save_policy"])
            }
        )
        XCTAssertTrue(saved)
        XCTAssertEqual(
            URLProtocolStub.recordedRequests.map { "\($0.0.httpMethod ?? "") \($0.0.url?.path ?? "")" },
            ["GET /cpa-admin/permissions/api/data", "POST /cpa-admin/permissions/api/save", "GET /cpa-admin/host/status"]
        )
        store.deactivate()
    }

    func testRefreshNotificationRefreshesOnlyTheActiveStoreOfThatSection() async throws {
        stub(200, #"{"value":"n"}"#)
        let store = ProbeWorkbenchStore(provider: FakeGatewayClientProvider(), section: .accessKeys)
        store.activate()
        try await waitUntil { store.loadCount == 1 && store.phase == .loaded }

        NotificationCenter.default.post(name: .oasesRefreshCurrentSection, object: nil, userInfo: ["section": AppSection.dashboard.rawValue])
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(store.loadCount, 1, "another section's refresh is ignored")

        NotificationCenter.default.post(name: .oasesRefreshCurrentSection, object: nil, userInfo: ["section": AppSection.accessKeys.rawValue])
        try await waitUntil { store.loadCount == 2 }
        XCTAssertEqual(store.loadCount, 2)

        store.deactivate()
        NotificationCenter.default.post(name: .oasesRefreshCurrentSection, object: nil, userInfo: ["section": AppSection.accessKeys.rawValue])
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(store.loadCount, 2, "an inactive store does not refresh")
    }

    func testRefreshCurrentSectionPostsTheSelectedSection() async throws {
        let appStore = AppStore()
        let deploymentStore = DeploymentStore(autoProbe: false)
        let runtimeDataStore = RuntimeDataStore()
        let expected = appStore.selectedSection.rawValue
        let posted = expectation(forNotification: .oasesRefreshCurrentSection, object: nil) { note in
            (note.userInfo?["section"] as? String) == expected
        }

        let before = appStore.refreshCount
        WorkspaceRefresh.refreshCurrentSection(store: appStore, deploymentStore: deploymentStore, runtimeDataStore: runtimeDataStore)
        XCTAssertEqual(appStore.refreshCount, before + 1)
        await fulfillment(of: [posted], timeout: 2)
    }

    // MARK: DeploymentStore as the provider

    func testDeploymentStoreGatewayAvailabilityAndLatch() {
        let store = DeploymentStore(autoProbe: false)
        XCTAssertEqual(store.gatewayAvailability, .notAttached)
        XCTAssertNil(store.gatewayAdminClient())

        store.attachForTesting(topology: .legacy, managementKey: "k1", adminKey: "a", method: .docker)
        XCTAssertEqual(store.gatewayAvailability, .dockerUnsupported)
        store.attachForTesting(topology: .legacy, managementKey: "k1", adminKey: "a")
        XCTAssertEqual(store.gatewayAvailability, .needsUpgrade)
        XCTAssertNil(store.gatewayAdminClient())

        store.attachForTesting(topology: .gateway, managementKey: "k1", adminKey: "a")
        XCTAssertEqual(store.gatewayAvailability, .ready)
        let client = store.gatewayAdminClient()
        XCTAssertEqual(client?.baseURL.absoluteString, "http://127.0.0.1:18320")
        XCTAssertEqual(client?.managementKey, "k1")

        store.reportGatewayUnauthorized(rejectedKey: "k1")
        XCTAssertEqual(store.gatewayAvailability, .credentialsRejected)
        XCTAssertNil(store.gatewayAdminClient())

        store.retryGatewayAuthentication()
        XCTAssertEqual(store.gatewayAvailability, .ready)

        store.reportGatewayUnauthorized(rejectedKey: "k1")
        store.attachForTesting(topology: .gateway, managementKey: "k2", adminKey: "a")
        XCTAssertEqual(store.gatewayAvailability, .ready, "a new management key clears the latch")

        store.attachForTesting(topology: .gateway, managementKey: "", adminKey: "a")
        XCTAssertEqual(store.gatewayAvailability, .notAttached)
    }

    func testDeploymentStoreIgnoresRejectionOfAKeyThatIsNoLongerCurrent() {
        let store = DeploymentStore(autoProbe: false)
        store.attachForTesting(topology: .gateway, managementKey: "k1", adminKey: "a")
        store.attachForTesting(topology: .gateway, managementKey: "k2", adminKey: "a")
        store.reportGatewayUnauthorized(rejectedKey: "k1")
        XCTAssertEqual(store.gatewayAvailability, .ready, "a late 401 for the old key must not latch the new one")
        XCTAssertEqual(store.gatewayAdminClient()?.managementKey, "k2")

        store.reportGatewayUnauthorized(rejectedKey: "k2")
        XCTAssertEqual(store.gatewayAvailability, .credentialsRejected)
    }
}
