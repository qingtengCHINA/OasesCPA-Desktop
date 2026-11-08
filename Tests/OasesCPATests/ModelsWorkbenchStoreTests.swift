import Foundation
import XCTest
@testable import OasesCPA

private let permissionsBody = """
{"keys":[],"permissions":{},"groupedModels":{"compat-a":["glm-5","pin-a/glm-5"],"认证文件 / 引擎模型":["gpt-5.5"]},"disabledProviders":[],"schema_version":2,"usage":{}}
"""
private let healthBody = """
{"models":{"pin-a/glm-5":{"status":"down","latency_ms":null,"error":"x","tested_at":1730000000000},
           "glm-5":{"status":"up","latency_ms":812,"error":null,"tested_at":1730000000000}},
 "providers":{},"run":null}
"""

@MainActor
final class ModelsWorkbenchStoreTests: XCTestCase {
    override func tearDown() async throws {
        URLProtocolStub.reset()
        try await super.tearDown()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Answers by path; `health` is called for every health read (in order).
    private func installGateway(health: @escaping @Sendable () -> (Int, String) = { (200, healthBody) },
                                other: @escaping @Sendable (URLRequest) -> (Int, String)? = { _ in nil }) {
        URLProtocolStub.install { request, _ in
            if let answer = other(request) { return .json(answer.0, answer.1, for: request) }
            switch request.url?.path {
            case "/cpa-admin/permissions/api/data": return .json(200, permissionsBody, for: request)
            case "/cpa-admin/permissions/api/models/health":
                let (status, body) = health()
                return .json(status, body, for: request)
            default: return .json(404, #"{"error":"Not found"}"#, for: request)
            }
        }
    }

    private func loadedStore(pollInterval: Duration = .seconds(2)) async throws -> ModelsWorkbenchStore {
        installGateway()
        let store = ModelsWorkbenchStore(provider: FakeGatewayClientProvider(), pollInterval: pollInterval)
        store.activate()
        try await waitUntil { store.phase == .loaded }
        XCTAssertEqual(store.phase, .loaded)
        return store
    }

    func testInternalPinIDsNeverReachViewState() async throws {
        let store = try await loadedStore()
        XCTAssertEqual(store.rows.map(\.id), ["glm-5", "gpt-5.5"])
        XCTAssertEqual(store.rows.first?.groups, ["compat-a"])
        XCTAssertEqual(store.rows.first?.health?.status, .up)
        XCTAssertEqual(store.rows.first?.health?.latencyMs, 812)
        XCTAssertNil(store.rows.last?.health)
        for row in store.rows {
            XCTAssertFalse(row.id.hasPrefix("pin-") || row.id.contains("/pin-"), row.id)
            for group in row.groups { XCTAssertFalse(group.hasPrefix("pin-"), group) }
        }
        store.deactivate()
    }

    func testTestBodyIsModelOnly() async throws {
        let store = try await loadedStore()
        installGateway(other: { request in
            request.url?.path == "/cpa-admin/permissions/api/models/test"
                ? (200, #"{"model":"glm-5","provider":null,"result":{"status":"up","latency_ms":700,"error":null,"tested_at":1730000005000}}"#)
                : nil
        })
        await store.test("glm-5")
        let post = try XCTUnwrap(URLProtocolStub.recordedRequests.first { $0.0.httpMethod == "POST" })
        XCTAssertEqual(post.0.url?.path, "/cpa-admin/permissions/api/models/test")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(post.1)) as? [String: String])
        XCTAssertEqual(body, ["model": "glm-5"])
        XCTAssertNil(store.actionError)
        store.deactivate()
    }

    func testTestAllPollsUntilRunFinishes() async throws {
        let store = try await loadedStore(pollInterval: .milliseconds(1))
        let reads = HealthReads()
        installGateway(
            health: {
                let count = reads.next()
                let run = count == 1
                    ? #"{"id":"r1","started_at":1730000000000,"finished_at":null,"total":2,"done":1,"up":1,"down":0,"skipped":0}"#
                    : #"{"id":"r1","started_at":1730000000000,"finished_at":1730000009000,"total":2,"done":2,"up":2,"down":0,"skipped":0}"#
                return (200, #"{"models":{"glm-5":{"status":"up","latency_ms":1,"error":null,"tested_at":1730000000000}},"providers":{},"run":"# + run + "}")
            },
            other: { request in
                request.url?.path == "/cpa-admin/permissions/api/models/test-all"
                    ? (200, #"{"run":{"id":"r1","started_at":1730000000000,"finished_at":null,"total":2,"done":0,"up":0,"down":0,"skipped":0},"already_running":false}"#)
                    : nil
            }
        )
        await store.testAll()
        try await waitUntil { store.run?.finishedAt != nil }
        XCTAssertEqual(store.run?.done, 2)
        try await Task.sleep(nanoseconds: 50_000_000)
        let healthReads = URLProtocolStub.recordedRequests.filter { $0.0.url?.path == "/cpa-admin/permissions/api/models/health" }
        XCTAssertEqual(healthReads.count, 2, "polling stops once the run has finished")
        let testAll = try XCTUnwrap(URLProtocolStub.recordedRequests.first { $0.0.url?.path == "/cpa-admin/permissions/api/models/test-all" })
        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(testAll.1)) as? [String: String], [:])
        store.deactivate()
    }

    func testDeactivateStopsPolling() async throws {
        let store = try await loadedStore(pollInterval: .milliseconds(5))
        installGateway(
            health: { (200, #"{"models":{},"providers":{},"run":{"id":"r","started_at":1,"finished_at":null,"total":9,"done":1,"up":1,"down":0,"skipped":0}}"#) },
            other: { request in
                request.url?.path == "/cpa-admin/permissions/api/models/test-all"
                    ? (200, #"{"run":{"id":"r","started_at":1,"finished_at":null,"total":9,"done":0,"up":0,"down":0,"skipped":0},"already_running":false}"#)
                    : nil
            }
        )
        await store.testAll()
        try await Task.sleep(nanoseconds: 40_000_000)
        store.deactivate()
        try await Task.sleep(nanoseconds: 20_000_000)
        let afterStop = URLProtocolStub.recordedRequests.count
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, afterStop, "no reads after deactivate")
    }

    func testEngineKeyMissingShowsBanner() async throws {
        let store = try await loadedStore()
        XCTAssertFalse(store.engineKeyMissing)
        installGateway(other: { request in
            request.url?.path == "/cpa-admin/permissions/api/models/test"
                ? (503, #"{"error":"Internal engine key is not configured","code":"engine_key_missing"}"#)
                : nil
        })
        await store.test("glm-5")
        XCTAssertTrue(store.engineKeyMissing)
        XCTAssertEqual(store.phase, .loaded, "the list stays on screen")
        store.deactivate()
    }

    func testUnauthorizedTestLatchesTheKey() async throws {
        let provider = FakeGatewayClientProvider()
        installGateway()
        let store = ModelsWorkbenchStore(provider: provider)
        store.activate()
        try await waitUntil { store.phase == .loaded }
        installGateway(other: { request in
            request.url?.path == "/cpa-admin/permissions/api/models/test" ? (401, #"{"error":"Unauthorized management key"}"#) : nil
        })
        await store.test("glm-5")
        XCTAssertEqual(store.phase, .unavailable(.credentialsRejected))
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 1, "a 401 is never retried")
        store.deactivate()
    }
}

/// A thread-safe counter for the stub handler.
private final class HealthReads: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
