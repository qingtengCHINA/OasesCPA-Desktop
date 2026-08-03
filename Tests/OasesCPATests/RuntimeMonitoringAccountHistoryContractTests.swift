import Foundation
import XCTest
@testable import OasesCPA

final class RuntimeMonitoringAccountHistoryContractTests: XCTestCase {
    func testRequestUsesSafeSnakeCaseFieldsAndRejectsEmptyTargets() throws {
        XCTAssertNil(RuntimeMonitoringAccountHistoryTarget(
            accountSnapshot: "  ",
            authLabelSnapshot: "\n\t",
            authIndex: "",
            source: " \n"
        ))

        let target = try XCTUnwrap(RuntimeMonitoringAccountHistoryTarget(
            accountSnapshot: "  account@example.com  ",
            authLabelSnapshot: " Primary ",
            authIndex: " 7 ",
            source: " local "
        ))
        let request = RuntimeMonitoringAccountHistoryRequest(
            accounts: [target],
            catchUp: true
        )
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)
        ) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["accounts", "catch_up"])
        XCTAssertEqual(object["catch_up"] as? Bool, true)
        let account = try XCTUnwrap((object["accounts"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(account.keys), [
            "account_snapshot",
            "auth_label_snapshot",
            "auth_index",
            "source"
        ])
        XCTAssertEqual(account["account_snapshot"] as? String, "account@example.com")
        XCTAssertEqual(account["auth_label_snapshot"] as? String, "Primary")
        XCTAssertEqual(account["auth_index"] as? String, "7")
        XCTAssertEqual(account["source"] as? String, "local")
        XCTAssertNil(account["account_key"])
    }

    func testSnakeAndCamelCaseResponsesDecodeWithoutExposingAccountKey() throws {
        let snake = Data(
            #"""
            {
              "generated_at_ms": 1735600000000,
              "checkpoint": {
                "last_event_id": 10,
                "latest_id": 10,
                "pending": false,
                "processed": 10
              },
              "items": [{
                "account_key": "must-not-become-display-data",
                "matched": true,
                "total_requests": 12,
                "success_calls": 10,
                "failure_calls": 2,
                "total_tokens": 500,
                "total_cost": 1.25,
                "success_rate": 0.8333,
                "first_seen_ms": 1735500000000,
                "last_seen_ms": 1735600000000,
                "sync_status": "ready"
              }]
            }
            """#.utf8
        )
        let camel = Data(
            #"""
            {
              "generatedAtMs": 1735600000001,
              "checkpoint": {
                "lastEventId": 11,
                "latestId": 12,
                "pending": true,
                "processed": 1
              },
              "items": [{
                "accountKey": "also-must-be-ignored",
                "matched": false,
                "totalRequests": 1,
                "successCalls": 0,
                "failureCalls": 1,
                "totalTokens": 9,
                "totalCost": 0.5,
                "successRate": 0,
                "firstSeenMs": 1735600000000,
                "lastSeenMs": 1735600000001,
                "syncStatus": "pending"
              }]
            }
            """#.utf8
        )

        let snakeResponse = try JSONDecoder().decode(
            RuntimeMonitoringAccountHistoryResponse.self,
            from: snake
        )
        let snakeItem = try XCTUnwrap(snakeResponse.items.first.flatMap { $0 })
        XCTAssertEqual(snakeResponse.generatedAtMs, 1735600000000)
        XCTAssertEqual(snakeItem.totalRequests, 12)
        XCTAssertEqual(snakeItem.totalCost, 1.25)
        XCTAssertEqual(snakeItem.syncStatus, .ready)

        let camelResponse = try JSONDecoder().decode(
            RuntimeMonitoringAccountHistoryResponse.self,
            from: camel
        )
        let camelItem = try XCTUnwrap(camelResponse.items.first.flatMap { $0 })
        XCTAssertEqual(camelResponse.checkpoint.pending, true)
        XCTAssertEqual(camelItem.totalTokens, 9)
        XCTAssertEqual(camelItem.syncStatus, .pending)
    }

    func testMalformedAndOutOfRangeValuesAreSafeAndArrayPositionsRemainStable() throws {
        let data = Data(
            #"""
            {
              "checkpoint": {
                "last_event_id": -10,
                "latest_id": 1e30,
                "pending": "not-a-bool",
                "processed": -4
              },
              "items": [
                {"total_requests": -2, "total_tokens": 1e30, "total_cost": -1, "success_rate": 2, "first_seen_ms": -1, "last_seen_ms": "bad", "sync_status": "future"},
                "not-an-object",
                {"total_requests": 4, "success_calls": 3, "failure_calls": 1, "total_tokens": 8, "total_cost": 2, "success_rate": 1, "first_seen_ms": 1735600000000, "last_seen_ms": 1735600000001, "sync_status": "ready"}
              ]
            }
            """#.utf8
        )

        let response = try JSONDecoder().decode(
            RuntimeMonitoringAccountHistoryResponse.self,
            from: data
        )
        XCTAssertEqual(response.checkpoint.lastEventID, 0)
        XCTAssertEqual(response.checkpoint.latestID, 0)
        XCTAssertEqual(response.checkpoint.processed, 0)
        XCTAssertFalse(response.checkpoint.pending)
        XCTAssertEqual(response.items.count, 3)

        let malformed = try XCTUnwrap(response.items[0])
        XCTAssertEqual(malformed.totalRequests, 0)
        XCTAssertEqual(malformed.totalTokens, 0)
        XCTAssertEqual(malformed.totalCost, 0)
        XCTAssertNil(malformed.successRate)
        XCTAssertNil(malformed.firstSeenMs)
        XCTAssertNil(malformed.lastSeenMs)
        XCTAssertEqual(malformed.syncStatus, .unknown)
        XCTAssertNil(response.items[1])

        let valid = try XCTUnwrap(response.items[2])
        XCTAssertEqual(valid.totalRequests, 4)
        XCTAssertEqual(valid.totalTokens, 8)
        XCTAssertEqual(valid.successRate, 1)
        XCTAssertEqual(valid.syncStatus, .ready)
    }

    func testSyncStatusesHaveExplicitSafeHandling() {
        XCTAssertEqual(RuntimeMonitoringAccountHistorySyncStatus(value: .string("ready")), .ready)
        XCTAssertEqual(RuntimeMonitoringAccountHistorySyncStatus(value: .string("pending")), .pending)
        XCTAssertEqual(RuntimeMonitoringAccountHistorySyncStatus(value: .string("empty")), .empty)
        XCTAssertEqual(RuntimeMonitoringAccountHistorySyncStatus(value: .string("unexpected")), .unknown)
        XCTAssertEqual(RuntimeMonitoringAccountHistorySyncStatus(value: nil), .unknown)
        XCTAssertEqual(RuntimeMonitoringAccountHistorySyncStatus(value: .string(" READY ")), .ready)
    }
}
