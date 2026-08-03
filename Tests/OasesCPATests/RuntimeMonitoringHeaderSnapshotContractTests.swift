import Foundation
import XCTest
@testable import OasesCPA

final class RuntimeMonitoringHeaderSnapshotContractTests: XCTestCase {
    func testSnakeCaseResponseDecodesSafeHeaderSignalsAndIgnoresResponseMetadata() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "generated_at_ms": 1_735_600_000_000,
            "from_ms": 1_735_500_000_000,
            "to_ms": 1_735_600_000_000,
            "items": [[
                "event_hash": "evt-header-001",
                "timestamp_ms": 1_735_599_999_000,
                "auth_file_snapshot": "codex-auth.json",
                "auth_index": "auth-7",
                "account_snapshot": "user@example.com",
                "auth_label_snapshot": "Primary",
                "auth_provider_snapshot": "openai",
                "auth_project_id_snapshot": "project-1",
                "source": "provider-response",
                "source_hash": "source-hash-1",
                "header_quota_recover_at_ms": 1_735_600_123_000,
                "header_quota_used_percent": 87.5,
                "header_quota_plan_type": "pro",
                "header_error_kind": "rate_limit",
                "header_error_code": "429",
                "header_trace_id": "trace-abc",
                "response_metadata": [
                    "authorization": "Bearer fake-secret",
                    "body": ["api_key": "fake-body-secret"]
                ],
                "response_body": "should-never-be-exposed"
            ]]
        ])

        let response = try JSONDecoder().decode(
            RuntimeMonitoringHeaderSnapshotsResponse.self,
            from: data
        )
        let snapshot = try XCTUnwrap(response.items.first)

        XCTAssertEqual(response.generatedAtMs, 1_735_600_000_000)
        XCTAssertEqual(response.fromMs, 1_735_500_000_000)
        XCTAssertEqual(response.toMs, 1_735_600_000_000)
        XCTAssertEqual(response.items.count, 1)
        XCTAssertEqual(snapshot.eventHash, "evt-header-001")
        XCTAssertEqual(snapshot.timestampMs, 1_735_599_999_000)
        XCTAssertEqual(snapshot.authFileSnapshot, "codex-auth.json")
        XCTAssertEqual(snapshot.authIndex, "auth-7")
        XCTAssertEqual(snapshot.accountSnapshot, "user@example.com")
        XCTAssertEqual(snapshot.authLabelSnapshot, "Primary")
        XCTAssertEqual(snapshot.authProviderSnapshot, "openai")
        XCTAssertEqual(snapshot.authProjectIdSnapshot, "project-1")
        XCTAssertEqual(snapshot.source, "provider-response")
        XCTAssertEqual(snapshot.sourceHash, "source-hash-1")
        XCTAssertEqual(snapshot.headerQuotaRecoverAtMs, 1_735_600_123_000)
        XCTAssertEqual(snapshot.headerQuotaUsedPercent, 87.5)
        XCTAssertEqual(snapshot.headerQuotaPlanType, "pro")
        XCTAssertEqual(snapshot.headerErrorKind, "rate_limit")
        XCTAssertEqual(snapshot.headerErrorCode, "429")
        XCTAssertEqual(snapshot.headerTraceId, "trace-abc")
        XCTAssertEqual(snapshot.errorTitle, "rate_limit · 429")
        XCTAssertTrue(snapshot.hasErrorSignal)
    }

    func testCamelCaseResponseDecodesAndDropsItemsWithoutHashOrPositiveTimestamp() throws {
        let data = Data(
            #"""
            {
              "generatedAtMs": 1735600000000,
              "fromMs": 1735500000000,
              "toMs": 1735600000000,
              "items": [
                {
                  "eventHash": "evt-camel",
                  "timestampMs": 1735599999000,
                  "authProviderSnapshot": "openai",
                  "headerTraceId": "trace-camel"
                },
                {
                  "timestampMs": 1735599999000,
                  "authProviderSnapshot": "missing-hash"
                },
                {
                  "eventHash": "zero-time",
                  "timestampMs": 0
                },
                {
                  "eventHash": "negative-time",
                  "timestampMs": -1
                }
              ]
            }
            """#.utf8
        )

        let response = try JSONDecoder().decode(
            RuntimeMonitoringHeaderSnapshotsResponse.self,
            from: data
        )

        XCTAssertEqual(response.generatedAtMs, 1_735_600_000_000)
        XCTAssertEqual(response.fromMs, 1_735_500_000_000)
        XCTAssertEqual(response.toMs, 1_735_600_000_000)
        XCTAssertEqual(response.items.count, 1)
        XCTAssertEqual(response.items.first?.eventHash, "evt-camel")
        XCTAssertEqual(response.items.first?.authProviderSnapshot, "openai")
        XCTAssertEqual(response.items.first?.headerTraceId, "trace-camel")
    }

    func testQuotaAndRecoveryBoundariesAreSafeAndHugeTimestampIsRejected() throws {
        let data = Data(
            #"""
            {
              "items": [
                {
                  "event_hash": "valid-zero-quota",
                  "timestamp_ms": 1735600000000,
                  "header_quota_used_percent": 0,
                  "header_quota_recover_at_ms": 0
                },
                {
                  "event_hash": "invalid-quota",
                  "timestamp_ms": 1735600000001,
                  "header_quota_used_percent": 100.01,
                  "header_quota_recover_at_ms": -10
                },
                {
                  "event_hash": "huge-time",
                  "timestamp_ms": 1e30,
                  "header_quota_used_percent": 50
                },
                {
                  "event_hash": "missing-time"
                }
              ]
            }
            """#.utf8
        )

        let response = try JSONDecoder().decode(
            RuntimeMonitoringHeaderSnapshotsResponse.self,
            from: data
        )
        let zeroQuota = try XCTUnwrap(response.items.first(where: { $0.eventHash == "valid-zero-quota" }))
        let invalidQuota = try XCTUnwrap(response.items.first(where: { $0.eventHash == "invalid-quota" }))

        XCTAssertEqual(response.items.count, 2)
        XCTAssertEqual(zeroQuota.headerQuotaUsedPercent, 0)
        XCTAssertNil(zeroQuota.headerQuotaRecoverAtMs)
        XCTAssertNil(invalidQuota.headerQuotaUsedPercent)
        XCTAssertNil(invalidQuota.headerQuotaRecoverAtMs)
        XCTAssertNil(response.items.first(where: { $0.eventHash == "huge-time" }))
        XCTAssertNil(response.items.first(where: { $0.eventHash == "missing-time" }))
    }

    func testStringFieldsAreTrimmedAndCappedAtSafeDisplayLength() throws {
        let longTrace = String(repeating: "x", count: 600)
        let data = try JSONSerialization.data(withJSONObject: [
            "items": [[
                "event_hash": "  evt-trimmed  ",
                "timestamp_ms": 1_735_600_000_000,
                "auth_label_snapshot": "  Primary account  ",
                "header_trace_id": "  \(longTrace)  ",
                "header_error_kind": "  rate_limit  "
            ]]
        ])

        let response = try JSONDecoder().decode(
            RuntimeMonitoringHeaderSnapshotsResponse.self,
            from: data
        )
        let snapshot = try XCTUnwrap(response.items.first)

        XCTAssertEqual(snapshot.eventHash, "evt-trimmed")
        XCTAssertEqual(snapshot.authLabelSnapshot, "Primary account")
        XCTAssertEqual(snapshot.headerErrorKind, "rate_limit")
        XCTAssertEqual(snapshot.headerTraceId.count, 512)
        XCTAssertFalse(snapshot.headerTraceId.hasPrefix(" "))
        XCTAssertFalse(snapshot.headerTraceId.hasSuffix(" "))
    }
}
