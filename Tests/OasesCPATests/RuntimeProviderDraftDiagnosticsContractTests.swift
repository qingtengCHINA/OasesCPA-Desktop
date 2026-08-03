import Foundation
import XCTest
@testable import OasesCPA

final class RuntimeProviderDraftDiagnosticsContractTests: XCTestCase {
    func testEndpointNormalizationSupportsBothEndpointInputs() throws {
        let modelsFromBase = try RuntimeProviderDraftDiagnosticsFactory.modelsRequest(
            baseURL: "https://gateway.example.test/v1/"
        )
        XCTAssertEqual(modelsFromBase.url, "https://gateway.example.test/v1/models")

        let modelsFromChat = try RuntimeProviderDraftDiagnosticsFactory.modelsRequest(
            baseURL: "https://gateway.example.test/v1/chat/completions"
        )
        XCTAssertEqual(modelsFromChat.url, "https://gateway.example.test/v1/models")

        let chatFromModels = try RuntimeProviderDraftDiagnosticsFactory.chatCompletionsRequest(
            baseURL: "https://gateway.example.test/v1/models",
            apiKey: "secret",
            model: "gpt-test"
        )
        XCTAssertEqual(chatFromModels.url, "https://gateway.example.test/v1/chat/completions")
    }

    func testRequestsUseManagementAPICallPayloadShapeAndMergeHeaders() throws {
        let models = try RuntimeProviderDraftDiagnosticsFactory.modelsRequest(
            baseURL: "gateway.example.test/v1/v0/management/",
            apiKey: "secret",
            headers: ["X-Trace": "trace"]
        )
        XCTAssertEqual(models.method, "GET")
        XCTAssertEqual(models.url, "http://gateway.example.test/v1/models")
        XCTAssertEqual(models.header["X-Trace"], "trace")
        XCTAssertEqual(models.header["Authorization"], "Bearer secret")
        XCTAssertNil(models.data)
        XCTAssertNil(models.authIndex)

        let request = try RuntimeProviderDraftDiagnosticsFactory.chatCompletionsRequest(
            baseURL: "https://gateway.example.test/v1",
            apiKey: "secret",
            headers: ["x-trace": "trace"],
            model: "gpt-test"
        )
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.header["x-trace"], "trace")
        XCTAssertEqual(request.header["Content-Type"], "application/json")

        let body = try XCTUnwrap(request.data?.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "gpt-test")
        XCTAssertEqual(object["stream"] as? Bool, false)
        XCTAssertEqual(object["max_tokens"] as? Int, 5)
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "Hi")
    }

    func testAuthorizationIsCaseInsensitiveAndAuthIndexUsesPlaceholder() throws {
        let customAuthorization = try RuntimeProviderDraftDiagnosticsFactory.modelsRequest(
            baseURL: "https://gateway.example.test",
            apiKey: "secret",
            headers: ["aUtHoRiZaTiOn": "Custom token"]
        )
        XCTAssertEqual(customAuthorization.header["aUtHoRiZaTiOn"], "Custom token")
        XCTAssertNil(customAuthorization.header["Authorization"])

        let indexed = try RuntimeProviderDraftDiagnosticsFactory.modelsRequest(
            baseURL: "https://gateway.example.test",
            authIndex: "  3  "
        )
        XCTAssertEqual(indexed.authIndex, "3")
        XCTAssertEqual(indexed.header["Authorization"], "Bearer $TOKEN$")

        let maskedIndexed = try RuntimeProviderDraftDiagnosticsFactory.modelsRequest(
            baseURL: "https://gateway.example.test",
            apiKey: "sk-****masked",
            authIndex: "3"
        )
        XCTAssertEqual(maskedIndexed.header["Authorization"], "Bearer $TOKEN$")
        XCTAssertFalse(maskedIndexed.header.values.contains { $0.contains("masked") })
    }

    func testMaskedCredentialWithoutAuthIndexIsRejectedWithoutLeakingSecretOrURL() {
        let secret = "sk-****masked-secret"
        XCTAssertThrowsError(
            try RuntimeProviderDraftDiagnosticsFactory.modelsRequest(
                baseURL: "https://gateway.example.test/private",
                apiKey: secret
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeProviderDraftDiagnosticsError, .maskedCredential)
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertFalse(String(describing: error).contains("https://"))
        }
    }

    func testModelParsingSupportsOpenAIModelsAndTopLevelArraysWithStableCaseInsensitiveDeduplication() throws {
        let openAIResponse = try makeResponse(
            statusCode: 200,
            header: [:],
            body: """
            {
              "data": [
                {"id":"gpt-4o", "description":"first"},
                {"id":"GPT-4O", "description":"duplicate"}
              ]
            }
            """
        )
        XCTAssertEqual(
            try RuntimeProviderDraftDiagnosticsParser.models(from: openAIResponse),
            [RuntimeDiscoveredProviderModel(name: "gpt-4o", description: "first")]
        )

        let alternateResponse = try makeResponse(
            statusCode: 200,
            header: [:],
            body: "{\"models\":[{\"name\":\"Claude\", \"alias\":\"claude-alias\"}, {\"id\":\" Gemini \"}]}"
        )
        XCTAssertEqual(
            try RuntimeProviderDraftDiagnosticsParser.models(from: alternateResponse),
            [
                RuntimeDiscoveredProviderModel(name: "Claude", alias: "claude-alias"),
                RuntimeDiscoveredProviderModel(name: "Gemini")
            ]
        )

        let arrayResponse = try makeResponse(
            statusCode: 200,
            header: [:],
            body: "[{\"id\":\"one\"}, \"Two\", {\"name\":\"ONE\"}, {\"id\":\"\"}, null]"
        )
        XCTAssertEqual(
            try RuntimeProviderDraftDiagnosticsParser.models(from: arrayResponse),
            [
                RuntimeDiscoveredProviderModel(name: "one"),
                RuntimeDiscoveredProviderModel(name: "Two")
            ]
        )
    }

    func testSafeOutcomesExposeOnlyStatusModelCountAndGenericMessages() throws {
        let response = try makeResponse(
            statusCode: 200,
            header: ["X-Secret": ["header-secret"]],
            body: #"{"data":[{"id":"one"},{"id":"TWO"}]}"#
        )
        let discovery = RuntimeProviderDraftDiagnosticsParser.safeOutcome(
            from: response,
            kind: .models
        )
        XCTAssertEqual(discovery.statusCode, 200)
        XCTAssertEqual(discovery.modelCount, 2)
        XCTAssertTrue(discovery.isSuccess)
        XCTAssertEqual(discovery.message, "已发现 2 个模型。")

        let failed = try makeResponse(
            statusCode: 401,
            header: ["Authorization": ["header-secret"]],
            body: "raw-response-body-and-url-https://secret.example.test"
        )
        let connectivity = RuntimeProviderDraftDiagnosticsParser.safeOutcome(
            from: failed,
            kind: .chatCompletions
        )
        XCTAssertFalse(connectivity.isSuccess)
        XCTAssertEqual(connectivity.message, "连通性测试未通过（状态码 401）。")
        XCTAssertFalse(connectivity.message.contains("raw-response-body"))
        XCTAssertFalse(connectivity.message.contains("https://"))
        XCTAssertFalse(String(describing: connectivity).contains("header-secret"))
    }

    private func makeResponse(
        statusCode: Int,
        header: [String: [String]],
        body: String
    ) throws -> RuntimeAPICallResponse {
        let object: [String: Any] = [
            "statusCode": statusCode,
            "header": header,
            "body": body
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(RuntimeAPICallResponse.self, from: data)
    }
}
