import Foundation
import XCTest
@testable import OasesCPA

final class RuntimeDirectProviderContractTests: XCTestCase {
    func testGeminiResponseDecodesDashedFieldsAliasesAndMasksAPIKey() throws {
        let data = Data(
            #"""
            {
              "gemini-api-key": [
                {
                  "api-key": "gemini-contract-secret-123456",
                  "base-url": "https://generativelanguage.googleapis.com",
                  "prefix": "team/",
                  "weight": 7,
                  "models": [
                    {"name": "gemini-2.5-pro", "alias": "gemini-pro"},
                    {"name": "gemini-2.5-flash", "alias": "gemini-flash"},
                    {"name": "gemini-2.5-flash", "alias": "gemini-flash"}
                  ],
                  "auth-index": "gemini-auth-0",
                  "future-routing": {"region": "us"},
                  "advanced-list": ["keep", 3, true]
                }
              ]
            }
            """#.utf8
        )

        let credentials = try RuntimeDirectProviderCredentialDecoder.decode(
            data,
            kind: .gemini
        )

        let credential = try XCTUnwrap(credentials.first)
        XCTAssertEqual(credentials.count, 1)
        XCTAssertEqual(credential.kind, .gemini)
        XCTAssertEqual(credential.index, 0)
        XCTAssertEqual(credential.baseURL, "https://generativelanguage.googleapis.com")
        XCTAssertEqual(credential.prefix, "team/")
        XCTAssertEqual(credential.weight, 7)
        XCTAssertEqual(credential.authIndex, "gemini-auth-0")
        XCTAssertEqual(credential.modelIDs, ["gemini-pro", "gemini-flash"])

        let masked = credential.maskedAPIKey
        XCTAssertTrue(masked.hasPrefix("gemi"))
        XCTAssertTrue(masked.hasSuffix("3456"))
        XCTAssertFalse(masked.contains("gemini-contract-secret-123456"))
        XCTAssertFalse(masked.contains(credential.apiKey))
        XCTAssertNotEqual(masked, "未配置")

        // Unknown and newer server fields must remain available for round-tripping.
        XCTAssertEqual(credential.payload.stringValue(for: "api-key").count, 29)
        XCTAssertEqual(
            credential.payload.values["future-routing"],
            .object(["region": .string("us")])
        )
        XCTAssertEqual(
            credential.payload.values["advanced-list"],
            .array([.string("keep"), .number(3), .boolean(true)])
        )
    }

    func testNewDraftEncodesCLIProxyAPIPayloadWithDashedKeys() throws {
        let draft = RuntimeDirectProviderCredentialDraft(
            apiKey: "new-gemini-secret",
            baseURL: "https://example.test/v1",
            prefix: "models/",
            proxyURL: "socks5://proxy.example.test:1080",
            weight: 12
        )

        let object = try jsonObject(draft.newPayload(for: .gemini))
        XCTAssertEqual(
            Set(object.keys),
            ["api-key", "base-url", "prefix", "proxy-url", "weight"]
        )
        XCTAssertEqual(object["api-key"] as? String, "new-gemini-secret")
        XCTAssertEqual(object["base-url"] as? String, "https://example.test/v1")
        XCTAssertEqual(object["prefix"] as? String, "models/")
        XCTAssertEqual(object["proxy-url"] as? String, "socks5://proxy.example.test:1080")
        XCTAssertEqual(object["weight"] as? NSNumber, 12)
    }

    func testEditDraftDoesNotSendEmptyAPIKeyAndCanEncodeJSONNullWeight() throws {
        let existing = RuntimeDirectProviderCredential(
            kind: .gemini,
            index: 2,
            payload: RuntimeProviderCredentialPayload(values: [
                "api-key": .string("existing-secret-never-replaced"),
                "base-url": .string("https://old.example.test"),
                "prefix": .string("old/"),
                "proxy-url": .string("http://old-proxy.example.test:8080"),
                "weight": .number(10)
            ])
        )
        let draft = RuntimeDirectProviderCredentialDraft(
            baseURL: "https://new.example.test",
            prefix: "new/",
            proxyURL: "http://new-proxy.example.test:8080",
            weight: nil
        )

        let patch = try XCTUnwrap(draft.patch(relativeTo: existing))
        let object = try jsonObject(patch)
        XCTAssertFalse(object.keys.contains("api-key"))
        XCTAssertEqual(object["base-url"] as? String, "https://new.example.test")
        XCTAssertEqual(object["prefix"] as? String, "new/")
        XCTAssertEqual(object["proxy-url"] as? String, "http://new-proxy.example.test:8080")
        XCTAssertTrue(object.keys.contains("weight"))
        XCTAssertTrue(object["weight"] is NSNull)
    }

    func testDraftValidationRejectsMissingRequiredFieldsAndInvalidValues() {
        XCTAssertNotNil(
            RuntimeDirectProviderCredentialDraft()
                .validationMessage(for: .gemini, isNew: true)
        )
        XCTAssertNotNil(
            RuntimeDirectProviderCredentialDraft(apiKey: "codex-key")
                .validationMessage(for: .codex, isNew: true)
        )
        XCTAssertNotNil(
            RuntimeDirectProviderCredentialDraft(apiKey: "xai-key")
                .validationMessage(for: .xai, isNew: true)
        )

        XCTAssertNotNil(
            RuntimeDirectProviderCredentialDraft(
                apiKey: "gemini-key",
                baseURL: "not-a-url"
            ).validationMessage(for: .gemini, isNew: true)
        )
        XCTAssertNotNil(
            RuntimeDirectProviderCredentialDraft(
                apiKey: "gemini-key",
                weight: 0
            ).validationMessage(for: .gemini, isNew: true)
        )
        XCTAssertNotNil(
            RuntimeDirectProviderCredentialDraft(
                apiKey: "gemini-key",
                weight: 1_000_001
            ).validationMessage(for: .gemini, isNew: true)
        )
    }

    func testValidGeminiDraftPassesValidation() {
        let draft = RuntimeDirectProviderCredentialDraft(
            apiKey: "gemini-key",
            baseURL: "https://generativelanguage.googleapis.com",
            prefix: "team/",
            proxyURL: "http://127.0.0.1:7890",
            weight: 1
        )

        XCTAssertNil(draft.validationMessage(for: .gemini, isNew: true))
    }

    func testPatchRequestEncodesIndexValueAndProtocolKeys() throws {
        let request = RuntimeDirectProviderCredentialPatchRequest(
            index: 4,
            value: RuntimeProviderCredentialPayload(values: [
                "api-key": .string("replacement-secret"),
                "base-url": .string("https://api.example.test"),
                "proxy-url": .string("http://proxy.example.test:8080"),
                "auth-index": .string("auth-4"),
                "weight": .null
            ])
        )

        let root = try jsonObject(request)
        XCTAssertEqual(root["index"] as? NSNumber, 4)
        let value = try XCTUnwrap(root["value"] as? [String: Any])
        XCTAssertEqual(
            Set(value.keys),
            ["api-key", "base-url", "proxy-url", "auth-index", "weight"]
        )
        XCTAssertEqual(value["api-key"] as? String, "replacement-secret")
        XCTAssertEqual(value["base-url"] as? String, "https://api.example.test")
        XCTAssertEqual(value["proxy-url"] as? String, "http://proxy.example.test:8080")
        XCTAssertEqual(value["auth-index"] as? String, "auth-4")
        XCTAssertTrue(value["weight"] is NSNull)
        XCTAssertFalse(value.keys.contains("apiKey"))
        XCTAssertFalse(value.keys.contains("baseUrl"))
        XCTAssertFalse(value.keys.contains("authIndex"))
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
