import Foundation
import XCTest
@testable import OasesCPA

/// `adminEntry` shape (gateway/search.mjs). "future" is SYNTHETIC.
private let braveEntry = """
{"id":"brave","name":"Brave Search","kind":"results","site":"https://brave.com/search/api/","docs":"https://api-dashboard.search.brave.com/documentation",
 "enabled":true,"configured":true,"key_hint":"…abcd","daily_limit":1000,"default_daily_limit":1000,"updated_at":"2026-11-07T10:00:00.000Z",
 "today":{"requests":3,"ok":2,"failed":1},"last_test":{"ok":true,"status":200,"message":"ok","detail":{},"tested_at":"2026-11-07T10:01:00.000Z","key_hint":"…abcd"},
 "future":1}
"""

final class GatewaySearchContractTests: XCTestCase {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func testSaveBodyOmitsUntouchedKeyAndSendsNullLimit() throws {
        let body = try json(GatewaySearchProviderSave(provider: "brave", enabled: true, apiKey: .keep, dailyLimit: .clear))
        XCTAssertEqual(body["provider"] as? String, "brave")
        XCTAssertEqual(body["enabled"] as? Bool, true)
        XCTAssertTrue(body["daily_limit"] is NSNull)
        XCTAssertNil(body["api_key"], "an untouched key is not written")
        XCTAssertEqual(Set(body.keys), ["provider", "enabled", "daily_limit"])
        // Nothing changed but the provider: only the provider.
        XCTAssertEqual(Set(try json(GatewaySearchProviderSave(provider: "exa")).keys), ["provider"])
        XCTAssertEqual(try json(GatewaySearchProviderSave(provider: "exa", dailyLimit: .set(50)))["daily_limit"] as? Int, 50)
    }

    func testClearingKeySendsEmptyString() throws {
        let body = try json(GatewaySearchProviderSave(provider: "brave", apiKey: .clear))
        XCTAssertEqual(body["api_key"] as? String, "")
        // A typed key is trimmed; the rules of adminSave are checked first.
        let typed = "BSA" + String(repeating: "k", count: 20)
        XCTAssertEqual(try json(GatewaySearchProviderSave(provider: "brave", apiKey: .set(" \(typed) ")))["api_key"] as? String, typed)
        XCTAssertFalse(GatewaySearchProviderSave(provider: "brave", apiKey: .set("has space")).validationErrors().isEmpty)
        XCTAssertFalse(GatewaySearchProviderSave(provider: "brave", apiKey: .set(String(repeating: "k", count: 513))).validationErrors().isEmpty)
        XCTAssertFalse(GatewaySearchProviderSave(provider: "brave", dailyLimit: .set(0)).validationErrors().isEmpty)
        XCTAssertFalse(GatewaySearchProviderSave(provider: "brave", dailyLimit: .set(10_000_001)).validationErrors().isEmpty)
        XCTAssertEqual(GatewaySearchProviderSave(provider: "brave", apiKey: .set(typed), dailyLimit: .set(10_000_000)).validationErrors(), [])
    }

    func testLogTimestampsAreSeconds() throws {
        // pushLog shape: ts in seconds, status the HTTP status number.
        let response = try JSONDecoder().decode(GatewaySearchLogsResponse.self, from: Data("""
        {"logs":[{"ts":1730000000,"provider":"brave","key_label":"laptop","key_fp":"0123abcd","status":200,"code":null,
                  "upstream_status":null,"results":5,"latency_ms":321,"attested":false,"upstream_called":true}]}
        """.utf8))
        let entry = try XCTUnwrap(response.logs.first)
        XCTAssertEqual(entry.ts, Date(timeIntervalSince1970: 1_730_000_000))
        XCTAssertEqual(entry.status, 200)
        XCTAssertTrue(entry.succeeded)
        XCTAssertEqual(entry.keyLabel, "laptop")
        XCTAssertEqual(entry.results, 5)
        XCTAssertEqual(entry.latencyMs, 321)
        XCTAssertEqual(entry.upstreamCalled, true)
    }

    @MainActor
    func testThrottledTestShowsRetryMessage() async throws {
        defer { URLProtocolStub.reset() }
        URLProtocolStub.install { request, _ in
            switch request.url?.path {
            case "/cpa-admin/search/providers": return .json(200, #"{"providers":[\#(braveEntry)]}"#, for: request)
            case "/cpa-admin/search/usage": return .json(200, #"{"days":[]}"#, for: request)
            case "/cpa-admin/search/logs": return .json(200, #"{"logs":[]}"#, for: request)
            case "/cpa-admin/search/providers/test":
                return .json(429, #"{"error":"请 8 秒后再测试（服务商限制测试频率）。","code":"test_throttled"}"#, for: request)
            default: return .json(404, #"{"error":"Not found"}"#, for: request)
            }
        }
        let store = SearchProvidersStore(provider: FakeGatewayClientProvider())
        store.activate()
        for _ in 0..<300 where store.phase != .loaded { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.phase, .loaded)
        let succeeded = await store.test("brave")
        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.actionError, OasesLocalization.localizedFormat("测试过于频繁，请 %lld 秒后再试（服务商限制测试频率）。", 8))
        XCTAssertTrue(store.actionError?.contains("测试过于频繁") ?? false)
        XCTAssertTrue(OasesLocalization.localizedFormat("测试过于频繁，请 %lld 秒后再试（服务商限制测试频率）。", language: .english, 8).contains("8"))
        let tests = URLProtocolStub.recordedRequests.filter { $0.0.url?.path == "/cpa-admin/search/providers/test" }
        XCTAssertEqual(tests.count, 1, "not retried")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(tests.first?.1)) as? [String: Any])
        XCTAssertEqual(body as NSDictionary, ["provider": "brave"], "the saved key: no api_key")
        store.deactivate()
    }

    func testUsageDaysClampedTo1Through62() {
        func days(_ value: Int) -> String? { GatewayAdminClient.searchUsageQuery(days: value).first { $0.name == "days" }?.value }
        XCTAssertEqual(days(0), "1")
        XCTAssertEqual(days(-5), "1")
        XCTAssertEqual(days(7), "7")
        XCTAssertEqual(days(62), "62")
        XCTAssertEqual(days(63), "62")
        XCTAssertEqual(days(1_000), "62")
        // The log limit too (1…500), and the provider only when set.
        XCTAssertEqual(GatewayAdminClient.searchLogsQuery(limit: 0, provider: nil).map(\.value), ["1"])
        XCTAssertEqual(GatewayAdminClient.searchLogsQuery(limit: 9_999, provider: "exa").map(\.value), ["500", "exa"])
    }

    func testSearchProviderPreservesUnknownFields() throws {
        let provider = try JSONDecoder().decode(GatewaySearchProvider.self, from: Data(braveEntry.utf8))
        XCTAssertEqual(provider.extra["future"], .number(1))
        XCTAssertEqual(provider.keyHint, "…abcd")
        XCTAssertEqual(provider.dailyLimit, 1000)
        XCTAssertEqual(provider.today, GatewaySearchCounts(requests: 3, ok: 2, failed: 1))
        XCTAssertEqual(provider.lastTest?.ok, true)
        XCTAssertNotNil(provider.lastTest?.extra["detail"], "provider detail kept, never shown")
        let reencoded = try json(provider)
        XCTAssertEqual(reencoded["future"] as? Int, 1, "still there after re-encoding")
        XCTAssertEqual(reencoded["key_hint"] as? String, "…abcd")
        XCTAssertEqual(try JSONDecoder().decode(GatewaySearchProvider.self, from: JSONEncoder().encode(provider)), provider)
        // No daily limit decodes as nil.
        let unlimited = try JSONDecoder().decode(GatewaySearchProvider.self, from: Data(#"{"id":"x","daily_limit":null,"configured":false}"#.utf8))
        XCTAssertNil(unlimited.dailyLimit)
        XCTAssertNil(unlimited.keyHint)
    }

    /// A provider's message that echoes the key just typed is masked before the result is kept,
    /// so the provider row (which shows the kept result) cannot show it.
    @MainActor
    func testTypedKeyIsMaskedInTheKeptTestResult() async throws {
        defer { URLProtocolStub.reset() }
        let typed = "tvly-" + String(repeating: "q7", count: 12)
        URLProtocolStub.install { request, _ in
            switch request.url?.path {
            case "/cpa-admin/search/providers": return .json(200, #"{"providers":[\#(braveEntry)]}"#, for: request)
            case "/cpa-admin/search/usage": return .json(200, #"{"days":[]}"#, for: request)
            case "/cpa-admin/search/logs": return .json(200, #"{"logs":[]}"#, for: request)
            case "/cpa-admin/search/providers/test":
                return .json(200, #"{"result":{"ok":false,"status":401,"code":"upstream_auth","message":"invalid key \#(typed)","tested_at":"2026-11-08T00:00:00.000Z","key_hint":"…q7q7"}}"#, for: request)
            default: return .json(404, #"{"error":"Not found"}"#, for: request)
            }
        }
        let store = SearchProvidersStore(provider: FakeGatewayClientProvider())
        store.activate()
        for _ in 0..<300 where store.phase != .loaded { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.phase, .loaded)
        let succeeded = await store.test("brave", apiKey: typed)
        XCTAssertTrue(succeeded)
        let kept = try XCTUnwrap(store.result(for: "brave"))
        XCTAssertFalse(kept.ok)
        XCTAssertFalse(kept.message.contains(typed), kept.message)
        XCTAssertTrue(kept.message.hasPrefix("invalid key"), kept.message)
        store.deactivate()
    }
}
