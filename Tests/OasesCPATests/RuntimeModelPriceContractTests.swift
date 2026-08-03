import Foundation
import XCTest
@testable import OasesCPA

final class RuntimeModelPriceContractTests: XCTestCase {
    func testPricesEnvelopeDecodesUnknownFieldsAndTierMetadata() throws {
        let data = Data(
            #"""
            {
              "prices": {
                "gpt-5": {
                  "prompt": 1.25,
                  "completion": 3.5,
                  "cache": 0.2,
                  "promptConfigured": true,
                  "source": "models.dev",
                  "sourceModelId": "gpt-5-2025-08-07",
                  "contextTiers": [{"thresholdTokens": 128000, "prompt": 2.5}],
                  "serviceTiers": [{"mode": "fast", "serviceTier": "priority", "prompt": 1.5}],
                  "future-field": {"region": "us"},
                  "rawJson": "{\"provider\":\"upstream\"}"
                }
              }
            }
            """#.utf8
        )

        let response = try JSONDecoder().decode(RuntimeModelPricesResponse.self, from: data)
        let payload = try XCTUnwrap(response.prices["gpt-5"])

        XCTAssertEqual(payload.prompt, 1.25)
        XCTAssertEqual(payload.completion, 3.5)
        XCTAssertEqual(payload.source, "models.dev")
        XCTAssertEqual(payload.sourceModelID, "gpt-5-2025-08-07")
        XCTAssertEqual(payload.contextTierCount, 1)
        XCTAssertEqual(payload.serviceTierCount, 1)
        XCTAssertEqual(payload.rawMetadata, "{\"provider\":\"upstream\"}")
        XCTAssertEqual(payload.values["future-field"], .object(["region": .string("us")]))
        XCTAssertTrue(payload.hasAdvancedMetadata)
    }

    func testManualPayloadUsesBasicManualSemanticsAndDropsSyncMetadata() throws {
        let draft = RuntimeModelPriceDraft(
            modelID: " gpt-5 ",
            prompt: "1.25",
            completion: " 3.5 ",
            cache: "",
            cacheRead: "0",
            cacheCreation: "0.4"
        )

        let payload = draft.manualPayload()
        let object = try jsonObject(payload)

        XCTAssertEqual(object["prompt"] as? Double, 1.25)
        XCTAssertEqual(object["completion"] as? Double, 3.5)
        XCTAssertEqual(object["cache"] as? Double, 1.25)
        XCTAssertEqual(object["cacheRead"] as? Double, 0)
        XCTAssertEqual(object["cacheCreation"] as? Double, 0.4)
        XCTAssertEqual(object["promptConfigured"] as? Bool, true)
        XCTAssertEqual(object["completionConfigured"] as? Bool, true)
        XCTAssertEqual(object["cacheReadConfigured"] as? Bool, true)
        XCTAssertEqual(object["cacheCreationConfigured"] as? Bool, true)
        XCTAssertEqual(object["source"] as? String, "manual")
        XCTAssertNotNil(object["contextTiers"] as? [Any])
        XCTAssertEqual((object["contextTiers"] as? [Any])?.count, 0)
        XCTAssertEqual((object["serviceTiers"] as? [Any])?.count, 0)
        XCTAssertFalse(object.keys.contains("rawJson"))
        XCTAssertFalse(object.keys.contains("sourceModelId"))
    }

    func testReplaceRequestEncodesPricesAtTheTopLevel() throws {
        let request = RuntimeModelPricesReplaceRequest(prices: [
            "gpt-5": RuntimeModelPricePayload(values: [
                "prompt": .number(1),
                "source": .string("manual")
            ])
        ])

        let object = try jsonObject(request)
        XCTAssertEqual(Set(object.keys), ["prices"])
        let prices = try XCTUnwrap(object["prices"] as? [String: Any])
        let gpt = try XCTUnwrap(prices["gpt-5"] as? [String: Any])
        XCTAssertEqual(gpt["prompt"] as? Double, 1)
        XCTAssertEqual(gpt["source"] as? String, "manual")
    }

    func testSyncResponseDecodesImportSummaryAndSourceDetails() throws {
        let data = Data(
            #"""
            {
              "prices": {"gpt-5": {"prompt": 1}},
              "imported": 4,
              "skipped": 2,
              "source": "models.dev",
              "sources": ["models.dev", "litellm"],
              "candidates": [{"model": "gpt-5"}, {"model": "o3"}],
              "unmatched": ["local-only"],
              "preserved": ["existing-model"],
              "proxyUsed": true,
              "sourceResults": [
                {"source": "models.dev", "models": 10, "skipped": 1},
                {"source": "litellm", "models": 8, "skipped": 2, "error": "partial"}
              ]
            }
            """#.utf8
        )

        let response = try JSONDecoder().decode(RuntimeModelPriceSyncResponse.self, from: data)

        XCTAssertEqual(response.prices["gpt-5"]?.prompt, 1)
        XCTAssertEqual(response.imported, 4)
        XCTAssertEqual(response.skipped, 2)
        XCTAssertEqual(response.source, "models.dev")
        XCTAssertEqual(response.sources, ["models.dev", "litellm"])
        XCTAssertEqual(response.candidateSetCount, 2)
        XCTAssertEqual(response.unmatchedModels, ["local-only"])
        XCTAssertEqual(response.preservedModels, ["existing-model"])
        XCTAssertTrue(response.proxyUsed)
        XCTAssertEqual(response.sourceResults.count, 2)
        XCTAssertEqual(response.sourceResults[0].models, 10)
        XCTAssertNil(response.sourceResults[0].error)
        XCTAssertEqual(response.sourceResults[1].error, "partial")
    }

    func testDraftValidationRejectsInvalidValuesAndAcceptsExplicitZero() {
        XCTAssertNotNil(RuntimeModelPriceDraft(prompt: "1").validationMessage)

        XCTAssertNotNil(RuntimeModelPriceDraft(modelID: "   ", prompt: "0").validationMessage)
        XCTAssertNotNil(RuntimeModelPriceDraft(modelID: "gpt-5", prompt: "-0.1").validationMessage)
        XCTAssertNotNil(RuntimeModelPriceDraft(modelID: "gpt-5", prompt: "not-a-number").validationMessage)

        let zero = RuntimeModelPriceDraft(modelID: "gpt-5", prompt: "0")
        XCTAssertNil(zero.validationMessage)
        XCTAssertEqual(zero.manualPayload().prompt, 0)
        XCTAssertTrue(zero.manualPayload().promptConfigured)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
