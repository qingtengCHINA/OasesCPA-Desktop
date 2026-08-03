import Foundation
import XCTest
@testable import OasesCPA

final class RuntimeAccountActionContractTests: XCTestCase {
    func testCandidatesEnvelopeDecodesCamelCaseFieldsAndSearchableEvidence() throws {
        let data = Data(
            #"""
            {
              "items": [
                {
                  "id": 42,
                  "actionType": "reauth",
                  "status": "pending",
                  "provider": "codex",
                  "authFileName": "account.json",
                  "authIndex": "3",
                  "accountSnapshot": "alice@example.com",
                  "accountIdSnapshot": "acct_42",
                  "authLabel": "Alice",
                  "reasonCode": "token_expired",
                  "reason": "OAuth token expired",
                  "autoDisableEligible": true,
                  "autoDisabledAtMs": 1730000000123,
                  "evidence": {
                    "headerErrorKind": "unauthorized",
                    "headerErrorCode": 401,
                    "headerTraceId": "trace-abc",
                    "requestId": "req-1"
                  },
                  "lastError": "401 Unauthorized",
                  "firstSeenAtMs": 1730000000000,
                  "lastSeenAtMs": 1730000000100,
                  "hitCount": 2,
                  "createdAtMs": 1730000000000,
                  "updatedAtMs": 1730000000100
                }
              ],
              "pendingCount": 1
            }
            """#.utf8
        )

        let response = try JSONDecoder().decode(
            RuntimeAccountActionCandidatesResponse.self,
            from: data
        )
        let candidate = try XCTUnwrap(response.items.first)

        XCTAssertEqual(response.pendingCount, 1)
        XCTAssertEqual(candidate.id, 42)
        XCTAssertEqual(candidate.actionType, "reauth")
        XCTAssertEqual(candidate.status, "pending")
        XCTAssertEqual(candidate.provider, "codex")
        XCTAssertEqual(candidate.authFileName, "account.json")
        XCTAssertEqual(candidate.authIndex, "3")
        XCTAssertEqual(candidate.accountIDSnapshot, "acct_42")
        XCTAssertEqual(candidate.autoDisabledAtMs, 1730000000123)
        XCTAssertEqual(candidate.reason, "OAuth token expired")
        XCTAssertEqual(candidate.evidenceHeaderValue(for: "headerErrorKind"), "unauthorized")
        XCTAssertEqual(candidate.evidenceHeaderValue(for: "headerErrorCode"), "401")
        XCTAssertEqual(candidate.evidenceHeaderValue(for: "headerTraceId"), "trace-abc")
        XCTAssertTrue(candidate.searchText.contains("trace-abc"))
        XCTAssertTrue(candidate.searchText.contains("unauthorized"))
        XCTAssertTrue(candidate.evidenceText.contains("headerErrorKind"))
        XCTAssertTrue(candidate.evidenceText.contains("trace-abc"))
    }

    func testCandidatesEnvelopeDropsMalformedOrNonPositiveIDsAndClampsPendingCount() throws {
        let data = Data(
            #"""
            {
              "items": [
                {"id": 0, "actionType": "delete"},
                {"id": -5, "actionType": "reauth"},
                {"id": "not-a-number", "actionType": "review"},
                {"actionType": "delete"},
                {"id": 7, "actionType": "review", "status": "pending"}
              ],
              "pendingCount": -10
            }
            """#.utf8
        )

        let response = try JSONDecoder().decode(
            RuntimeAccountActionCandidatesResponse.self,
            from: data
        )

        XCTAssertEqual(response.items.map(\.id), [7])
        XCTAssertEqual(response.pendingCount, 0)
    }

    func testSingleCandidateResponseRequiresValidItem() throws {
        let validData = Data(
            #"{"item":{"id":9,"actionType":"delete","status":"resolved"}}"#.utf8
        )
        let valid = try JSONDecoder().decode(
            RuntimeAccountActionCandidateResponse.self,
            from: validData
        )
        XCTAssertEqual(valid.item.id, 9)

        let missingItem = Data(#"{"status":"ok"}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RuntimeAccountActionCandidateResponse.self,
                from: missingItem
            )
        )

        let invalidItem = Data(#"{"item":{"id":0,"actionType":"delete"}}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RuntimeAccountActionCandidateResponse.self,
                from: invalidItem
            )
        )
    }

    func testStatusFilterQueriesAndOperationEndpointComponents() {
        XCTAssertNil(RuntimeAccountActionStatusFilter.all.queryValue)
        XCTAssertEqual(RuntimeAccountActionStatusFilter.pending.queryValue, "pending")
        XCTAssertEqual(RuntimeAccountActionStatusFilter.ignored.queryValue, "ignored")
        XCTAssertEqual(RuntimeAccountActionStatusFilter.resolved.queryValue, "resolved")
        XCTAssertEqual(RuntimeAccountActionStatusFilter.deleted.queryValue, "deleted")

        XCTAssertEqual(RuntimeAccountActionOperation.ignore.endpointComponent, "ignore")
        XCTAssertEqual(RuntimeAccountActionOperation.resolve.endpointComponent, "resolve")
        XCTAssertEqual(RuntimeAccountActionOperation.enable.endpointComponent, "enable")
    }

    func testEvidenceFormattingAndKnownActionStatusTitles() throws {
        let data = Data(
            #"""
            {"item":{
              "id": 12,
              "actionType": " DELETE ",
              "status": " PENDING ",
              "evidence": {"headerTraceId": "trace-12", "headerErrorKind": "rate_limit"}
            }}
            """#.utf8
        )
        let candidate = try JSONDecoder().decode(
            RuntimeAccountActionCandidateResponse.self,
            from: data
        ).item

        XCTAssertEqual(candidate.actionTitle, "删除认证文件")
        XCTAssertEqual(candidate.statusTitle, "待处理")
        XCTAssertTrue(candidate.isPending)
        XCTAssertTrue(candidate.evidenceText.contains("headerTraceId"))
        XCTAssertTrue(candidate.evidenceText.contains("trace-12"))

        for (action, title) in [
            ("delete", "删除认证文件"),
            ("reauth", "重新授权"),
            ("review", "人工复核")
        ] {
            let candidate = try XCTUnwrap(
                RuntimeAccountActionCandidate(
                    value: .object(["id": .number(1), "actionType": .string(action)])
                )
            )
            XCTAssertEqual(candidate.actionTitle, title)
        }

        for (status, title) in [
            ("pending", "待处理"),
            ("resolved", "已处理"),
            ("deleted", "已删除")
        ] {
            let candidate = try XCTUnwrap(
                RuntimeAccountActionCandidate(
                    value: .object(["id": .number(1), "status": .string(status)])
                )
            )
            XCTAssertEqual(candidate.statusTitle, title)
        }
    }
}
