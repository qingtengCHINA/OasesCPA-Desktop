import Foundation
import XCTest
@testable import OasesCPA

final class RuntimeCodexInspectionContractTests: XCTestCase {
    func testRunsEnvelopeDecodesCamelCaseStatusAndActivityFlags() throws {
        let response = try decodeRuns(
            """
            {
              "items": [
                {
                  "id": 42,
                  "triggerType": "manual",
                  "triggerKey": "button",
                  "status": "running",
                  "startedAtMs": 1710000000000,
                  "finishedAtMs": 0,
                  "totalFiles": 9,
                  "probeSetCount": 3,
                  "sampledCount": 2,
                  "disabledCount": 1,
                  "enabledCount": 4,
                  "deleteCount": 0,
                  "disableCount": 1,
                  "enableCount": 0,
                  "reauthCount": 0,
                  "keepCount": 1,
                  "error": "",
                  "createdAtMs": 1710000000000,
                  "updatedAtMs": 1710000001000,
                  "active": true,
                  "cancellable": true
                }
              ]
            }
            """
        )

        XCTAssertEqual(response.items.count, 1)
        let run = try XCTUnwrap(response.items.first)
        XCTAssertEqual(run.id, 42)
        XCTAssertEqual(run.triggerType, "manual")
        XCTAssertEqual(run.status, "running")
        XCTAssertTrue(run.active)
        XCTAssertTrue(run.cancellable)
        XCTAssertEqual(run.startedAtMs, 1710000000000)
        XCTAssertEqual(run.totalFiles, 9)
        XCTAssertEqual(run.probeSetCount, 3)
    }

    func testRunDetailDecodesResultsQuotaWindowsAndLogDetailUsingCamelCase() throws {
        let detail = try decodeDetail(
            """
            {
              "run": {
                "id": 7,
                "triggerType": "manual",
                "status": "completed",
                "startedAtMs": 1710000000000,
                "finishedAtMs": 1710000005000,
                "totalFiles": 1,
                "probeSetCount": 1,
                "sampledCount": 1,
                "disabledCount": 0,
                "enabledCount": 0,
                "deleteCount": 0,
                "disableCount": 0,
                "enableCount": 0,
                "reauthCount": 0,
                "keepCount": 1,
                "createdAtMs": 1710000000000,
                "updatedAtMs": 1710000005000,
                "active": false,
                "cancellable": false
              },
              "results": [{
                "id": 101,
                "runId": 7,
                "accountKey": "account-key",
                "fileName": "codex.json",
                "displayAccount": "user@example.com",
                "accountSnapshot": "snapshot",
                "authIndex": "2",
                "accountId": "acct_1",
                "provider": "codex",
                "disabled": false,
                "status": "healthy",
                "state": "ready",
                "action": "keep",
                "actionReason": "probe succeeded",
                "actionStatus": "none",
                "executedAction": "",
                "actionError": "",
                "statusCode": 200,
                "usedPercent": 12.5,
                "isQuota": true,
                "autoRecoverEligible": false,
                "error": "",
                "planType": "pro",
                "quotaWindows": [{
                  "id": "1",
                  "labelKey": "fiveHour",
                  "labelParams": {"hours": 5},
                  "usedPercent": 12.5,
                  "resetLabel": "in 2h",
                  "limitWindowSeconds": 18000
                }],
                "createdAtMs": 1710000002000,
                "errorKind": "",
                "errorDetail": ""
              }],
              "logs": [{
                "id": 501,
                "runId": 7,
                "level": "info",
                "message": "probe completed",
                "detail": {"statusCode": 200, "provider": "codex"},
                "createdAtMs": 1710000003000
              }]
            }
            """
        )

        XCTAssertEqual(detail.run.id, 7)
        let result = try XCTUnwrap(detail.results.first)
        XCTAssertEqual(result.id, 101)
        XCTAssertEqual(result.runID, 7)
        XCTAssertEqual(result.accountKey, "account-key")
        XCTAssertEqual(result.provider, "codex")
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.usedPercent, 12.5)
        XCTAssertEqual(result.quotaWindows.count, 1)
        XCTAssertEqual(result.quotaWindows.first?.labelKey, "fiveHour")
        XCTAssertEqual(result.quotaWindows.first?.resetLabel, "in 2h")

        let log = try XCTUnwrap(detail.logs.first)
        XCTAssertEqual(log.id, 501)
        XCTAssertEqual(log.runID, 7)
        XCTAssertEqual(log.message, "probe completed")
        XCTAssertNotNil(log.detail)
    }

    func testMissingActionStatusFallsBackForMutatingActionsAndKeepNeedsNoAction() throws {
        let detail = try decodeDetail(
            """
            {
              "run": {"id": 8, "status": "completed"},
              "results": [
                {"id": 1, "action": "delete"},
                {"id": 2, "action": "disable"},
                {"id": 3, "action": "enable"},
                {"id": 4, "action": "keep"}
              ],
              "logs": []
            }
            """
        )

        XCTAssertEqual(detail.results.map(\.actionStatus), ["pending", "pending", "pending", "none"])
    }

    func testMissingDetailOrInvalidRunIDIsRejected() {
        XCTAssertThrowsError(try decodeDetail("{\"results\": [], \"logs\": []}"))
        XCTAssertThrowsError(try decodeDetail("{\"run\": {\"id\": 0}, \"results\": [], \"logs\": []}"))
        XCTAssertThrowsError(try decodeDetail("{\"run\": {\"id\": -1}, \"results\": [], \"logs\": []}"))
    }

    func testDetailFiltersInvalidResultAndLogIDs() throws {
        let detail = try decodeDetail(
            """
            {
              "run": {"id": 9, "status": "completed"},
              "results": [{"id": 10}, {"id": 0}, {"id": -2}],
              "logs": [{"id": 20, "message": "kept"}, {"id": 0}, {"id": -3}]
            }
            """
        )

        XCTAssertEqual(detail.results.map(\.id), [10])
        XCTAssertEqual(detail.logs.map(\.id), [20])
    }

    private func decodeRuns(_ json: String) throws -> RuntimeCodexInspectionRunsResponse {
        try JSONDecoder().decode(RuntimeCodexInspectionRunsResponse.self, from: Data(json.utf8))
    }

    private func decodeDetail(_ json: String) throws -> RuntimeCodexInspectionRunDetail {
        try JSONDecoder().decode(RuntimeCodexInspectionRunDetail.self, from: Data(json.utf8))
    }
}
