import Foundation
import XCTest
@testable import OasesCPA

/// `describeModelProviders` shape (server.mjs): compat providers by priority, then OAuth pools.
private let providersBody = """
{"model":"glm-5","providers":[
  {"id":"compat-a","kind":"compat","name":"compat-a","priority":20,"prefix":"pin-a","draggable":true,"upstreamModel":"glm-5"},
  {"id":"compat-b","kind":"compat","name":"compat-b","priority":10,"prefix":"pin-b","draggable":true,"upstreamModel":"glm-5"},
  {"id":"oauth:codex","kind":"oauth","name":"Codex 账号 ×1","priority":0,"prefix":null,"draggable":false,"upstreamModel":"glm-5"}
]}
"""

/// A thread-safe list of canned answers, used in order (the last one repeats).
private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int, String)]
    init(_ items: [(Int, String)]) { self.items = items }
    func next() -> (Int, String) {
        lock.lock()
        defer { lock.unlock() }
        return items.count > 1 ? items.removeFirst() : items[0]
    }
}

@MainActor
final class ModelDetailStoreTests: XCTestCase {
    override func tearDown() async throws {
        URLProtocolStub.reset()
        try await super.tearDown()
    }

    private struct Stub {
        var reorder: Answers = Answers([(200, #"{"priorities":{},"affected":[],"ties":[],"rejected":null}"#)])
        var analytics = #"{"generated_at_ms":1,"summary":{"total_calls":0,"success_calls":0,"failure_calls":0,"total_cost":0}}"#
        var events = #"{"events":{"items":[],"has_more":false,"total_count":0}}"#
        var prices = #"{"prices":{"glm-5":{"input":1,"output":2}}}"#
    }

    private func install(_ stub: Stub) {
        URLProtocolStub.install { request, body in
            switch (request.url?.port, request.url?.path) {
            case (18320, "/cpa-admin/permissions/api/models/providers"): return .json(200, providersBody, for: request)
            case (18320, "/cpa-admin/permissions/api/models/reorder"):
                let (status, text) = stub.reorder.next()
                return .json(status, text, for: request)
            case (18317, "/v0/management/monitoring/analytics"):
                let isEvents = (try? JSONSerialization.jsonObject(with: body ?? Data()) as? [String: Any])
                    .flatMap { ($0["include"] as? [String: Any])?["events_page"] } != nil
                return .json(200, isEvents ? stub.events : stub.analytics, for: request)
            case (18317, "/v0/management/model-prices"): return .json(200, stub.prices, for: request)
            default: return .json(404, #"{"error":"Not found"}"#, for: request)
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func loadedStore(_ stub: Stub = Stub()) async throws -> ModelDetailStore {
        install(stub)
        let store = ModelDetailStore(
            modelID: "glm-5",
            provider: FakeGatewayClientProvider(),
            cpamp: { (URL(string: "http://127.0.0.1:18317")!, "test-cpamp-admin") },
            client: ManagementAPIClient(session: URLProtocolStub.makeSession())
        )
        store.activate()
        try await waitUntil { store.phase == .loaded && store.summary != nil }
        XCTAssertEqual(store.phase, .loaded)
        return store
    }

    private func reorderBodies() throws -> [[String: Any]] {
        try URLProtocolStub.recordedRequests
            .filter { $0.0.url?.path == "/cpa-admin/permissions/api/models/reorder" }
            .map { try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap($0.1)) as? [String: Any]) }
    }

    private func providerReads() -> Int {
        URLProtocolStub.recordedRequests.filter { $0.0.url?.path == "/cpa-admin/permissions/api/models/providers" }.count
    }

    private let newOrder = ["compat-b", "compat-a", "oauth:codex"]

    func testReorderWithoutSideEffectsCommitsAfterDryRun() async throws {
        var stub = Stub()
        stub.reorder = Answers([
            (200, #"{"priorities":{"A":20,"B":10},"affected":[],"ties":[],"rejected":null}"#),
            (200, #"{"ok":true,"priorities":{"A":20,"B":10},"affected":[],"ties":[],"rejected":null}"#),
        ])
        let store = try await loadedStore(stub)
        let readsBefore = providerReads()
        await store.proposeOrder(newOrder)
        let bodies = try reorderBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0]["dryRun"] as? Bool, true)
        XCTAssertEqual(bodies[0]["order"] as? [String], newOrder, "every id, pools included")
        XCTAssertEqual(bodies[0]["model"] as? String, "glm-5")
        XCTAssertNil(bodies[1]["dryRun"], "the change itself carries no dryRun key")
        XCTAssertEqual(bodies[1]["order"] as? [String], newOrder, "the same order")
        XCTAssertGreaterThan(providerReads(), readsBefore, "providers read again after the change")
        XCTAssertNil(store.pendingPlan)
        XCTAssertNil(store.actionError)
        XCTAssertFalse(store.isReordering)
        store.deactivate()
    }

    func testReorderAffectingOtherModelsWaitsForConfirmation() async throws {
        var stub = Stub()
        stub.reorder = Answers([
            (200, #"{"priorities":{"compat-a":10,"compat-b":20},"affected":["other-model"],"ties":[],"rejected":null}"#),
            (200, #"{"ok":true,"priorities":{"compat-a":10,"compat-b":20},"affected":["other-model"],"ties":[],"rejected":null}"#),
        ])
        let store = try await loadedStore(stub)
        await store.proposeOrder(newOrder)
        XCTAssertEqual(try reorderBodies().count, 1, "only the dry run")
        XCTAssertEqual(store.pendingPlan?.affected, ["other-model"])
        XCTAssertEqual(store.providers.map(\.id), newOrder, "the proposed order is shown while waiting")

        await store.confirmPendingPlan()
        let bodies = try reorderBodies()
        XCTAssertEqual(bodies.count, 2)
        XCTAssertNil(bodies[1]["dryRun"])
        XCTAssertEqual(bodies[1]["order"] as? [String], newOrder)
        XCTAssertNil(store.pendingPlan)

        // Discarding a pending plan sends nothing and shows the server's order again.
        stub.reorder = Answers([(200, #"{"priorities":{},"affected":["other-model"],"ties":[],"rejected":null}"#)])
        install(stub)
        await store.proposeOrder(newOrder)
        XCTAssertNotNil(store.pendingPlan)
        store.discardPendingPlan()
        XCTAssertNil(store.pendingPlan)
        XCTAssertEqual(store.providers.map(\.id), ["compat-a", "compat-b", "oauth:codex"])
        XCTAssertEqual(try reorderBodies().count, 1)
        store.deactivate()
    }

    func testRejectedDryRunRestoresOriginalOrder() async throws {
        // Built at run time: a reason naming an internal id and carrying a key-shaped string.
        let reason = "会改变 " + "pin-a/" + "glm-5" + " 中与登录账号 oauth:codex 的先后 " + "sk-" + String(repeating: "x7", count: 16)
        let encodedReason = String(decoding: try JSONEncoder().encode(reason), as: UTF8.self)
        var stub = Stub()
        stub.reorder = Answers([(200, #"{"priorities":{},"affected":[],"ties":[],"rejected":"# + encodedReason + "}")])
        let store = try await loadedStore(stub)
        await store.proposeOrder(newOrder)
        XCTAssertEqual(try reorderBodies().count, 1, "no second request")
        XCTAssertEqual(store.providers.map(\.id), ["compat-a", "compat-b", "oauth:codex"])
        let expected = SecretRedactor.redact(InternalModelID.publicText(reason), secrets: [])
        XCTAssertEqual(store.actionError, expected)
        XCTAssertFalse(expected.contains("pin-a/"), expected)
        XCTAssertFalse(expected.contains(String(repeating: "x7", count: 16)), "masked: \(expected)")
        XCTAssertNil(store.pendingPlan)
        store.deactivate()
    }

    func testConflictOnCommitRestoresOriginalOrder() async throws {
        var stub = Stub()
        stub.reorder = Answers([
            (200, #"{"priorities":{"compat-a":10,"compat-b":20},"affected":[],"ties":[],"rejected":null}"#),
            (409, #"{"ok":false,"priorities":{},"affected":[],"ties":[],"rejected":"顺序与当前的供应商列表不一致，请刷新后再试"}"#),
        ])
        let store = try await loadedStore(stub)
        await store.proposeOrder(newOrder)
        XCTAssertEqual(try reorderBodies().count, 2)
        XCTAssertEqual(store.providers.map(\.id), ["compat-a", "compat-b", "oauth:codex"])
        XCTAssertEqual(store.actionError, "顺序与当前的供应商列表不一致，请刷新后再试")
        store.deactivate()
    }

    /// M15: the engine could not be written (502 management_unavailable): readable, order restored.
    func testEngineFailureOnCommitIsReadable() async throws {
        var stub = Stub()
        stub.reorder = Answers([
            (200, #"{"priorities":{"compat-a":10,"compat-b":20},"affected":[],"ties":[],"rejected":null}"#),
            (502, #"{"ok":false,"error":"Engine rejected the provider update","code":"management_unavailable"}"#),
        ])
        let store = try await loadedStore(stub)
        await store.proposeOrder(newOrder)
        XCTAssertEqual(store.providers.map(\.id), ["compat-a", "compat-b", "oauth:codex"])
        XCTAssertEqual(store.actionError, OasesLocalization.localized("网关暂时连不上引擎的管理接口，本次操作没有生效；请确认引擎在运行后重试。"))
        XCTAssertFalse(store.actionError?.contains("502") ?? true)
        store.deactivate()
    }

    func testReorderPlanPreservesUnknownFields() throws {
        let plan = try JSONDecoder().decode(GatewayReorderPlan.self, from: Data(
            #"{"priorities":{"a":3},"affected":["m"],"ties":[["a","b"]],"rejected":null,"future":true}"#.utf8
        ))
        XCTAssertEqual(plan.extra["future"], .boolean(true))
        XCTAssertEqual(plan.priorities, ["a": 3])
        XCTAssertEqual(plan.ties, [["a", "b"]])
        XCTAssertNil(plan.rejected)
        XCTAssertTrue(plan.hasSideEffects)
        // The request writes dryRun only when true.
        let dry = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GatewayReorderRequest(model: "m", order: ["a"], dryRun: true))) as? [String: Any]
        XCTAssertEqual(dry?["dryRun"] as? Bool, true)
        for value in [false, nil] as [Bool?] {
            let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(GatewayReorderRequest(model: "m", order: ["a"], dryRun: value))) as? [String: Any]
            XCTAssertNil(body?["dryRun"])
        }
    }

    func testSevenDayAnalyticsRequestUsesAllVariants() throws {
        let now = Date(timeIntervalSince1970: 1_730_000_000)
        let request = ModelDetailStore.analyticsRequest(modelID: "glm-5", prefixes: ["pin-a", "pin-b"], now: now, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(request.filters.models, ["glm-5", "pin-a/glm-5", "pin-b/glm-5"])
        XCTAssertEqual(request.toMs - request.fromMs, 7 * 24 * 60 * 60 * 1_000)
        XCTAssertEqual(request.toMs, 1_730_000_000_000)
        XCTAssertEqual(request.include.summary, true)
        XCTAssertEqual(ModelDetailStore.routingPrefixes(of: try JSONDecoder().decode(GatewayModelProvidersResponse.self, from: Data(providersBody.utf8)).providers),
                       ["pin-a", "pin-b"], "compat providers only")
    }

    func testRecentCallsQueryUsesVariantsAndShowPublicName() async throws {
        var stub = Stub()
        stub.events = #"{"events":{"items":[{"event_hash":"e1","timestamp_ms":1730000000000,"model":"pin-a/glm-5","resolved_model":"cc-pin-a/glm-5","failed":false}],"has_more":false,"total_count":1}}"#
        let store = try await loadedStore(stub)
        let eventsRequest = try XCTUnwrap(URLProtocolStub.recordedRequests.first { request in
            guard request.0.url?.path == "/v0/management/monitoring/analytics", let body = request.1,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
            return (json["include"] as? [String: Any])?["events_page"] != nil
        })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(eventsRequest.1)) as? [String: Any])
        XCTAssertEqual((json["filters"] as? [String: Any])?["models"] as? [String], ["glm-5", "pin-a/glm-5", "pin-b/glm-5"])
        XCTAssertEqual(((json["include"] as? [String: Any])?["events_page"] as? [String: Any])?["limit"] as? Int, 20)
        XCTAssertEqual(eventsRequest.0.value(forHTTPHeaderField: "Authorization"), "Bearer test-cpamp-admin", "CPAMP's admin key")
        XCTAssertEqual(store.recentCalls.count, 1)
        XCTAssertEqual(store.recentCalls.first?.displayModel, "glm-5")
        XCTAssertEqual(store.recentCalls.first?.displayResolvedModel, "glm-5")
        store.deactivate()
    }

    func testMissingPriceShowsNoPriceFlag() async throws {
        var stub = Stub()
        stub.prices = #"{"prices":{"other-model":{"input":1,"output":2}}}"#
        stub.analytics = #"{"generated_at_ms":1,"summary":{"total_calls":4,"success_calls":3,"failure_calls":1,"total_cost":0}}"#
        let store = try await loadedStore(stub)
        XCTAssertEqual(store.summary, ModelDetailSummary(calls: 4, successRate: 0.75, totalCost: 0, hasPrice: false))
        store.deactivate()

        // A price stored under the public name counts.
        let priced = try await loadedStore()
        XCTAssertEqual(priced.summary?.hasPrice, true)
        priced.deactivate()
    }
}
