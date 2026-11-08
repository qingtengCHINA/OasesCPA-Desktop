import Foundation
import XCTest
@testable import OasesCPA

/// Shapes of the gateway's model-health routes (Server `gateway/model-health.mjs`, `server.mjs`
/// handleModelHealth / handleModelTest / handleModelTestAll).
final class GatewayModelHealthContractTests: XCTestCase {
    func testHealthDecodingUsesEpochMilliseconds() throws {
        let response = try JSONDecoder().decode(GatewayModelHealthResponse.self, from: Data("""
        {
          "models": {
            "glm-5": {"status":"up","latency_ms":812,"error":null,"tested_at":1730000000000},
            "image-1": {"status":"skipped","latency_ms":null,"error":null,"tested_at":1730000001000},
            "gpt-5.5": {"status":"down","latency_ms":null,"error":"HTTP 503","tested_at":1730000002000},
            "odd": {"status":"flaky","latency_ms":null,"error":null,"tested_at":0}
          },
          "providers": {"compat-a|glm-5": {"status":"up","latency_ms":90,"error":null,"tested_at":1730000003000}},
          "run": null
        }
        """.utf8))
        let up = try XCTUnwrap(response.models["glm-5"])
        XCTAssertEqual(up.status, .up)
        XCTAssertEqual(up.latencyMs, 812)
        XCTAssertNil(up.error)
        XCTAssertEqual(up.testedAt, Date(timeIntervalSince1970: 1_730_000_000))
        XCTAssertEqual(response.models["image-1"]?.status, .skipped)
        XCTAssertEqual(response.models["gpt-5.5"]?.status, .down)
        XCTAssertEqual(response.models["gpt-5.5"]?.error, "HTTP 503")
        XCTAssertEqual(response.models["odd"]?.status, .other("flaky"))
        XCTAssertEqual(response.providers["compat-a|glm-5"]?.latencyMs, 90)
        XCTAssertNil(response.run)

        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(up)) as? [String: Any])
        XCTAssertEqual(encoded["tested_at"] as? Int, 1_730_000_000_000)
        XCTAssertEqual(encoded["status"] as? String, "up")
        XCTAssertTrue(encoded["error"] is NSNull, "error is written as null, like the gateway")
    }

    func testRunAndTestAllDecode() throws {
        let response = try JSONDecoder().decode(GatewayTestAllResponse.self, from: Data("""
        {"run":{"id":"r1","started_at":1730000000000,"finished_at":null,"total":3,"done":1,"up":1,"down":0,"skipped":0},"already_running":true}
        """.utf8))
        XCTAssertTrue(response.alreadyRunning)
        XCTAssertEqual(response.run.id, "r1")
        XCTAssertEqual(response.run.startedAt, Date(timeIntervalSince1970: 1_730_000_000))
        XCTAssertNil(response.run.finishedAt)
        XCTAssertEqual([response.run.total, response.run.done, response.run.up, response.run.down, response.run.skipped], [3, 1, 1, 0, 0])

        let single = try JSONDecoder().decode(GatewayModelTestResponse.self, from: Data("""
        {"model":"glm-5","provider":null,"result":{"status":"down","latency_ms":null,"error":"请求超时（60 秒内无响应）","tested_at":1730000000000}}
        """.utf8))
        XCTAssertEqual(single.model, "glm-5")
        XCTAssertNil(single.provider)
        XCTAssertEqual(single.result.status, .down)
    }

    func testHealthAndRunPreserveUnknownFields() throws {
        // Synthetic: today's gateway writes neither field; a newer one may add fields.
        let result = try JSONDecoder().decode(GatewayHealthResult.self, from: Data("""
        {"status":"up","latency_ms":5,"error":null,"tested_at":1730000000000,"future":1}
        """.utf8))
        XCTAssertEqual(result.extra["future"], .number(1))
        let reencoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        XCTAssertEqual(reencoded["future"] as? Int, 1)

        let run = try JSONDecoder().decode(GatewayTestRun.self, from: Data("""
        {"id":"r","started_at":1,"finished_at":2,"total":0,"done":0,"up":0,"down":0,"skipped":0,"future":1}
        """.utf8))
        XCTAssertEqual(run.extra["future"], .number(1))
        let runJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(run)) as? [String: Any])
        XCTAssertEqual(runJSON["future"] as? Int, 1)
        XCTAssertEqual(runJSON["finished_at"] as? Int, 2)
    }

    func testPermissionsDataDecodesGroupedModels() throws {
        // The real /cpa-admin/permissions/api/data body (server.mjs): extra fields are ignored here.
        let data = try JSONDecoder().decode(GatewayPermissionsData.self, from: Data("""
        {"keys":[],"permissions":{},"groupedModels":{"compat-a":["glm-5","pin-a/glm-5"]},"disabledProviders":[],"schema_version":2,"usage":{}}
        """.utf8))
        XCTAssertEqual(data.groupedModels["compat-a"], ["glm-5", "pin-a/glm-5"])
    }
}
