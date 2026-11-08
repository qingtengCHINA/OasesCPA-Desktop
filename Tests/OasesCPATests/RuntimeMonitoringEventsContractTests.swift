import Foundation
import XCTest
@testable import OasesCPA

final class RuntimeMonitoringEventsContractTests: XCTestCase {
    func testRequestEncodesCPAMPAnalyticsShapeAndOmitsBlankSearch() throws {
        let now = Date(timeIntervalSince1970: 1_735_689_600)
        let request = RuntimeMonitoringEventsRequest(
            range: .today,
            now: now,
            searchQuery: "   \n\t",
            failedOnly: true
        )

        let json = try jsonObject(for: request)
        XCTAssertNotNil(json["from_ms"] as? Int)
        XCTAssertNotNil(json["to_ms"] as? Int)
        XCTAssertNil(json["search_query"])

        let filters = try XCTUnwrap(json["filters"] as? [String: Any])
        XCTAssertEqual(filters["failed_only"] as? Bool, true)

        let include = try XCTUnwrap(json["include"] as? [String: Any])
        let eventsPage = try XCTUnwrap(include["events_page"] as? [String: Any])
        XCTAssertEqual(eventsPage["limit"] as? Int, 50)
        XCTAssertNil(eventsPage["before_ms"])
        XCTAssertNil(eventsPage["before_id"])
    }

    func testRequestEncodesTrimmedSearchQuery() throws {
        let request = RuntimeMonitoringEventsRequest(
            range: .sevenDays,
            now: Date(timeIntervalSince1970: 1_735_689_600),
            searchQuery: "  gpt-4o  ",
            failedOnly: false
        )

        let json = try jsonObject(for: request)
        XCTAssertEqual(json["search_query"] as? String, "gpt-4o")
    }

    func testNextPagePreservesRangeAndFiltersAndUsesBothCursorFields() throws {
        let initial = RuntimeMonitoringEventsRequest(
            range: .thirtyDays,
            now: Date(timeIntervalSince1970: 1_735_689_600),
            searchQuery: "  timeout ",
            failedOnly: true
        )
        let cursor = RuntimeMonitoringEventsCursor(beforeMs: 1_735_600_123_456, beforeId: 987_654)
        let next = initial.nextPage(after: cursor)

        let initialJSON = try jsonObject(for: initial)
        let nextJSON = try jsonObject(for: next)
        XCTAssertEqual(nextJSON["from_ms"] as? Int, initialJSON["from_ms"] as? Int)
        XCTAssertEqual(nextJSON["to_ms"] as? Int, initialJSON["to_ms"] as? Int)
        XCTAssertEqual(nextJSON["search_query"] as? String, "timeout")

        let initialFilters = try XCTUnwrap(initialJSON["filters"] as? [String: Any])
        let nextFilters = try XCTUnwrap(nextJSON["filters"] as? [String: Any])
        XCTAssertEqual(nextFilters["failed_only"] as? Bool, initialFilters["failed_only"] as? Bool)

        let include = try XCTUnwrap(nextJSON["include"] as? [String: Any])
        let page = try XCTUnwrap(include["events_page"] as? [String: Any])
        XCTAssertEqual(page["limit"] as? Int, 50)
        XCTAssertEqual(page["before_ms"] as? Int, Int(cursor.beforeMs))
        XCTAssertEqual(page["before_id"] as? Int, Int(cursor.beforeId))
    }

    func testAnalyticsResponseDecodesKnownFieldsCursorTotalsAndSafeFailureSummary() throws {
        let longFailure = String(repeating: "failure\n", count: 100)
        let data = try JSONSerialization.data(withJSONObject: [
            "events": [
                "items": [[
                    "event_hash": "evt-001",
                    "request_id": "req-001",
                    "timestamp_ms": 1_735_600_123_456,
                    "model": "gpt-4o",
                    "resolved_model": "openai/gpt-4o",
                    "endpoint": "openai",
                    "method": "POST",
                    "path": "/v1/chat/completions",
                    "auth_index": "auth-7",
                    "source": "openrouter",
                    "total_tokens": 321,
                    "latency_ms": 842,
                    "failed": true,
                    "fail_status_code": 429,
                    "fail_summary": longFailure,
                    "response_metadata": ["secret_header": "must-not-be-modeled"],
                    "future_field": ["new": true]
                ]],
                "next_before_ms": 1_735_600_000_000,
                "next_before_id": 123,
                "has_more": true,
                "total_count": 77
            ],
            "analytics_version": 2
        ])

        let response = try JSONDecoder().decode(
            RuntimeMonitoringEventsAnalyticsResponse.self,
            from: data
        )
        let page = try XCTUnwrap(response.events)
        let event = try XCTUnwrap(page.items.first)

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(event.id, "evt-001")
        XCTAssertEqual(event.requestId, "req-001")
        XCTAssertEqual(event.timestampMs, 1_735_600_123_456)
        XCTAssertEqual(event.model, "gpt-4o")
        XCTAssertEqual(event.resolvedModel, "openai/gpt-4o")
        XCTAssertEqual(event.totalTokens, 321)
        XCTAssertEqual(event.latencyMs, 842)
        XCTAssertTrue(event.failed)
        XCTAssertEqual(event.failStatusCode, 429)
        XCTAssertEqual(event.safeFailureSummary?.count, 480)
        XCTAssertFalse(event.safeFailureSummary?.contains("\n") ?? true)
        XCTAssertEqual(page.nextCursor, RuntimeMonitoringEventsCursor(beforeMs: 1_735_600_000_000, beforeId: 123))
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.totalCount, 77)
    }

    func testAnalyticsResponseAcceptsCamelCaseCompatibilityAndDropsMissingEventHash() throws {
        let data = Data(
            #"""
            {
              "events": {
                "items": [
                  {"requestId":"req-camel","eventHash":"evt-camel","resolvedModel":"vendor/model","failed":false},
                  {"request_id":"missing-hash","model":"should-be-dropped"}
                ],
                "nextBeforeMs": 1735600000000,
                "nextBeforeId": 42,
                "hasMore": true,
                "totalCount": "5",
                "response_metadata": {"arbitrary":"ignored"},
                "unknown_nested": {"does_not_matter": [1,2,3]}
              }
            }
            """#.utf8
        )

        let response = try JSONDecoder().decode(
            RuntimeMonitoringEventsAnalyticsResponse.self,
            from: data
        )
        let page = try XCTUnwrap(response.events)
        let event = try XCTUnwrap(page.items.first)

        XCTAssertEqual(page.items.count, 1)
        XCTAssertEqual(event.eventHash, "evt-camel")
        XCTAssertEqual(event.requestId, "req-camel")
        XCTAssertEqual(event.resolvedModel, "vendor/model")
        XCTAssertEqual(page.nextCursor, RuntimeMonitoringEventsCursor(beforeMs: 1_735_600_000_000, beforeId: 42))
        XCTAssertEqual(page.totalCount, 5)
    }

    func testHasMoreWithInvalidCursorProducesNilNextCursor() throws {
        let data = Data(
            #"{"events":{"items":[],"has_more":true,"next_before_ms":1735600000000,"next_before_id":0,"total_count":50}}"#.utf8
        )

        let response = try JSONDecoder().decode(
            RuntimeMonitoringEventsAnalyticsResponse.self,
            from: data
        )
        let page = try XCTUnwrap(response.events)

        XCTAssertTrue(page.hasMore)
        XCTAssertNil(page.nextCursor)
    }

    func testRawFieldsDropCredentialHeaders() throws {
        let clientKey = "sk-" + String(repeating: "q", count: 30)
        let event = try XCTUnwrap(RuntimeMonitoringEvent(value: .object([
            "event_hash": .string("evt-1"),
            "model": .string("pin-openrouter-2/gpt-4o"),
            "latency_ms": .number(812),
            "authorization": .string("Bearer \(clientKey)"),
            "x-api-key": .string(clientKey),
            "Cookie": .string("session=abc"),
            "x-management-key": .string("cpa_" + String(repeating: "0", count: 64)),
            "input_tokens": .number(12),
            "response_headers": .object([
                "Set-Cookie": .string("a=b"),
                "x-request-id": .string("req-42"),
                "proxy-authorization": .string("Basic Zm9v")
            ]),
            "fail_summary": .string("upstream echoed \(clientKey)"),
            "tags": .array([.string("a"), .number(2)])
        ])))
        let fields = Dictionary(uniqueKeysWithValues: event.rawFields.map { ($0.key, $0.value) })
        for dropped in ["authorization", "x-api-key", "Cookie", "x-management-key", "response_headers.Set-Cookie", "response_headers.proxy-authorization"] {
            XCTAssertNil(fields[dropped], dropped)
        }
        XCTAssertEqual(fields["event_hash"], "evt-1")
        XCTAssertEqual(fields["latency_ms"], "812")
        XCTAssertEqual(fields["input_tokens"], "12", "token counts are not credentials")
        XCTAssertEqual(fields["response_headers.x-request-id"], "req-42")
        XCTAssertEqual(fields["model"], "gpt-4o", "internal pin- heads are never shown")
        XCTAssertEqual(fields["tags"], #"["a",2]"#)
        let summary = try XCTUnwrap(fields["fail_summary"])
        XCTAssertFalse(summary.contains(clientKey), "values pass the secret redactor")
        XCTAssertTrue(summary.contains(SecretRedactor.mask))
        XCTAssertEqual(event.rawFields.map(\.key), event.rawFields.map(\.key).sorted(), "sorted by key")
    }

    func testCredentialKeysAreRecognisedInEverySpelling() throws {
        for key in [
            "accessToken", "refreshToken", "idToken", "sessionToken", "managementKey", "xManagementKey",
            "apiKey", "xApiKey", "X-Goog-Api-Key", "clientSecret", "secretKey", "Authorization",
            "proxyAuthorization", "setCookie", "userPassword", "access-token", "REFRESH_TOKEN", "token",
            "bearer", "credentials"
        ] {
            XCTAssertTrue(RuntimeMonitoringEvent.isCredentialKey(key), key)
        }
        for key in ["inputTokens", "input_tokens", "totalTokens", "cachedTokens", "x-request-id", "model", "keyHint", "latency_ms"] {
            XCTAssertFalse(RuntimeMonitoringEvent.isCredentialKey(key), key)
        }
        let event = try XCTUnwrap(RuntimeMonitoringEvent(value: .object([
            "event_hash": .string("evt-2"),
            "accessToken": .string("at-" + String(repeating: "a", count: 24)),
            "metadata": .object([
                "refreshToken": .string("rt-" + String(repeating: "b", count: 24)),
                "managementKey": .string("mk-" + String(repeating: "c", count: 24)),
                "inputTokens": .number(7)
            ])
        ])))
        let fields = Dictionary(uniqueKeysWithValues: event.rawFields.map { ($0.key, $0.value) })
        XCTAssertNil(fields["accessToken"])
        XCTAssertNil(fields["metadata.refreshToken"])
        XCTAssertNil(fields["metadata.managementKey"])
        XCTAssertEqual(fields["metadata.inputTokens"], "7", "token counts are not credentials")
    }

    func testAdvancedMonitoringFiltersBuildRequest() throws {
        var draft = RuntimeMonitoringFilterDraft()
        draft.provider = "openai-compatible-mock"
        draft.requestType = "OpenAICompatExecutor"
        draft.minLatencyText = "500"
        draft.cacheStatus = .hit
        draft.model = "gpt-4o"
        draft.account = " ops-account-1 , 另一个账号 "
        draft.apiKeyHash = "f1e2d3"
        draft.headerErrorKind = "rate_limit"
        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(draft.activeCount, 8)

        let request = RuntimeMonitoringEventsRequest(
            range: .today,
            now: Date(timeIntervalSince1970: 1_735_689_600),
            searchQuery: "",
            failedOnly: false,
            filters: draft.filters(prefixes: ["pin-mock"])
        )
        let filters = try XCTUnwrap(try jsonObject(for: request)["filters"] as? [String: Any])
        XCTAssertEqual(filters["providers"] as? [String], ["openai-compatible-mock"])
        XCTAssertEqual(filters["request_types"] as? [String], ["OpenAICompatExecutor"])
        XCTAssertEqual(filters["min_latency_ms"] as? Int, 500)
        XCTAssertEqual(filters["cache_status"] as? String, "hit")
        XCTAssertEqual(filters["models"] as? [String], ["gpt-4o", "pin-mock/gpt-4o"], "a public name queries every spelling")
        XCTAssertEqual(filters["accounts"] as? [String], ["ops-account-1", "另一个账号"])
        XCTAssertEqual(filters["api_key_hashes"] as? [String], ["f1e2d3"])
        XCTAssertEqual(filters["header_error_kinds"] as? [String], ["rate_limit"])
        XCTAssertEqual(filters["failed_only"] as? Bool, false)

        // An internal spelling typed by hand is folded to its public name first.
        draft = RuntimeMonitoringFilterDraft()
        draft.model = "pin-mock/gpt-4o"
        XCTAssertEqual(draft.filters(prefixes: ["pin-mock"]).models, ["gpt-4o", "pin-mock/gpt-4o"])

        // Nothing chosen: nothing but failed_only is sent; a bad latency is refused.
        let empty = RuntimeMonitoringEventsRequest(range: .today, searchQuery: "", failedOnly: true, filters: RuntimeMonitoringFilterDraft().filters(prefixes: []))
        let emptyFilters = try XCTUnwrap(try jsonObject(for: empty)["filters"] as? [String: Any])
        XCTAssertEqual(Set(emptyFilters.keys), ["failed_only"])
        draft.minLatencyText = "-3"
        XCTAssertFalse(draft.isValid)
        draft.minLatencyText = "1.5"
        XCTAssertFalse(draft.isValid)
        draft.minLatencyText = ""
        XCTAssertTrue(draft.isValid)
    }

    private func jsonObject<T: Encodable>(for value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
