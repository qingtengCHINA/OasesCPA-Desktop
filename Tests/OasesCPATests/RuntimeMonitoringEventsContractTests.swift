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

    private func jsonObject<T: Encodable>(for value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
