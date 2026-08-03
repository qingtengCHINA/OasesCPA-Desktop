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
                  "priority": 3,
                  "disable-cooling": true,
                  "headers": {
                    "X-Region": "us",
                    "X-Retry": "safe"
                  },
                  "models": [
                    {"name": "gemini-2.5-pro", "alias": "gemini-pro", "priority": 4, "future-model-field": {"tier": "pro"}},
                    {"name": "gemini-2.5-flash", "alias": "gemini-flash", "priority": 2},
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
        XCTAssertEqual(credential.priority, 3)
        XCTAssertTrue(credential.disableCooling)
        XCTAssertEqual(credential.headers, ["X-Region": "us", "X-Retry": "safe"])
        XCTAssertEqual(credential.authIndex, "gemini-auth-0")
        XCTAssertEqual(credential.modelIDs, ["gemini-pro", "gemini-flash"])
        XCTAssertEqual(
            credential.models.first?.values["future-model-field"],
            .object(["tier": .string("pro")])
        )

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
            weight: 12,
            priority: 5,
            disableCooling: true,
            headers: ["X-Region": "us"],
            models: [
                RuntimeDirectProviderModelDraft(
                    name: "gemini-2.5-pro",
                    alias: "pro",
                    values: ["future-model-field": .boolean(true)]
                )
            ]
        )

        let object = try jsonObject(draft.newPayload(for: .xai))
        XCTAssertEqual(
            Set(object.keys),
            ["api-key", "base-url", "prefix", "proxy-url", "weight", "priority", "disable-cooling", "headers", "models"]
        )
        XCTAssertEqual(object["api-key"] as? String, "new-gemini-secret")
        XCTAssertEqual(object["base-url"] as? String, "https://example.test/v1")
        XCTAssertEqual(object["prefix"] as? String, "models/")
        XCTAssertEqual(object["proxy-url"] as? String, "socks5://proxy.example.test:1080")
        XCTAssertEqual(object["weight"] as? NSNumber, 12)
        XCTAssertEqual(object["priority"] as? NSNumber, 5)
        XCTAssertEqual(object["disable-cooling"] as? Bool, true)
        XCTAssertEqual((object["headers"] as? [String: Any])?["X-Region"] as? String, "us")
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])
        XCTAssertEqual(models.first?["name"] as? String, "gemini-2.5-pro")
        XCTAssertEqual(models.first?["alias"] as? String, "pro")
        XCTAssertNil(models.first?["priority"])
        XCTAssertEqual(models.first?["future-model-field"] as? Bool, true)
    }

    func testEditDraftDoesNotSendEmptyAPIKeyAndCanEncodeJSONNullWeight() throws {
        let existing = RuntimeDirectProviderCredential(
            kind: .xai,
            index: 2,
            payload: RuntimeProviderCredentialPayload(values: [
                "api-key": .string("existing-secret-never-replaced"),
                "base-url": .string("https://old.example.test"),
                "prefix": .string("old/"),
                "proxy-url": .string("http://old-proxy.example.test:8080"),
                "weight": .number(10),
                "priority": .number(8),
                "disable-cooling": .boolean(true),
                "headers": .object([
                    "X-Keep": .string("same"),
                    "X-Delete": .string("remove"),
                    "X-Future": .number(3)
                ]),
                "models": .array([
                    .object([
                        "name": .string("old-model"),
                        "alias": .string("old"),
                        "priority": .number(1),
                        "future": .object(["enabled": .boolean(true)])
                    ])
                ])
            ])
        )
        let draft = RuntimeDirectProviderCredentialDraft(
            baseURL: "https://new.example.test",
            prefix: "new/",
            proxyURL: "http://new-proxy.example.test:8080",
            weight: nil,
            priority: 9,
            disableCooling: false,
            headers: ["X-Keep": "changed", "X-Add": "new"],
            preservedHeaderValues: ["X-Future": .number(3)],
            models: [
                RuntimeDirectProviderModelDraft(
                    name: "new-model",
                    alias: "new",
                    values: ["future": .object(["enabled": .boolean(true)])]
                )
            ]
        )

        let patch = try XCTUnwrap(draft.patch(relativeTo: existing))
        let object = try jsonObject(patch)
        XCTAssertFalse(object.keys.contains("api-key"))
        XCTAssertEqual(object["base-url"] as? String, "https://new.example.test")
        XCTAssertEqual(object["prefix"] as? String, "new/")
        XCTAssertEqual(object["proxy-url"] as? String, "http://new-proxy.example.test:8080")
        XCTAssertTrue(object.keys.contains("weight"))
        XCTAssertTrue(object["weight"] is NSNull)
        XCTAssertEqual(object["priority"] as? NSNumber, 9)
        XCTAssertEqual(object["disable-cooling"] as? Bool, false)
        let headers = try XCTUnwrap(object["headers"] as? [String: Any])
        XCTAssertEqual(headers["X-Keep"] as? String, "changed")
        XCTAssertEqual(headers["X-Add"] as? String, "new")
        XCTAssertEqual(headers["X-Delete"] as? String, nil)
        XCTAssertEqual(headers["X-Future"] as? NSNumber, 3)
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])
        XCTAssertEqual(models.first?["name"] as? String, "new-model")
        let future = try XCTUnwrap(models.first?["future"] as? [String: Any])
        XCTAssertEqual(future["enabled"] as? Bool, true)
    }

    func testPatchOmitsUnchangedAdvancedFields() throws {
        let existing = RuntimeDirectProviderCredential(
            kind: .xai,
            index: 1,
            payload: RuntimeProviderCredentialPayload(values: [
                "api-key": .string("secret"),
                "disable-cooling": .boolean(false),
                "headers": .object(["X-Client": .string("oases")]),
                "models": .array([.object(["name": .string("model"), "alias": .string("m")])])
            ])
        )
        let draft = RuntimeDirectProviderCredentialDraft(
            headers: ["X-Client": "oases"],
            models: [RuntimeDirectProviderModelDraft(name: "model", alias: "m")]
        )

        XCTAssertNil(draft.patch(relativeTo: existing))
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
        XCTAssertNotNil(
            RuntimeDirectProviderCredentialDraft(
                apiKey: "gemini-key",
                priority: -1
            ).validationMessage(for: .gemini, isNew: true)
        )
        XCTAssertNotNil(
            RuntimeDirectProviderCredentialDraft(
                apiKey: "gemini-key",
                headers: ["X-Test": "line\nbreak"]
            ).validationMessage(for: .gemini, isNew: true)
        )
        XCTAssertNotNil(
            RuntimeDirectProviderCredentialDraft(
                apiKey: "gemini-key",
                models: [RuntimeDirectProviderModelDraft()]
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

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
