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
    // MARK: - Whole-list writes (batch 6, Task 14)

    /// `GET /v0/management/config` as the engine answers it (`c.JSON(200, cfg)`), cut to the
    /// openai-compatibility list. "future-field" is SYNTHETIC (stands for a field of a newer engine).
    private static let configResponse = #"""
    {"debug":false,"openai-compatibility":[
      {"name":"DeepSeek 国内","priority":7,"prefix":"pin-deepseek","base-url":"https://a.example.test/v1",
       "api-key-entries":[{"api-key":"sk-upstream-one","weight":3,"proxy-url":"socks5://127.0.0.1:1080"}],
       "models":[{"name":"deepseek-chat","alias":"ds"}],"headers":{"X-Team":"a"},"disable-cooling":false,
       "future-field":{"depth":2}},
      {"name":"Other","base-url":"https://b.example.test/v1","models":[]}
    ]}
    """#

    private func entries(_ body: Data?) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(body)) as? [[String: Any]])
    }

    func testSettingPriorityChangesOnlyThatFieldAndKeepsEverythingElse() throws {
        let data = Data(Self.configResponse.utf8)
        let body = try XCTUnwrap(RuntimeOpenAICompatibilityListMutation.settingPriority(12, ofProviderNamed: " DeepSeek 国内 ", index: 0, in: data))
        let written = try entries(body)
        let original = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["openai-compatibility"] as? [[String: Any]])
        XCTAssertEqual(written.count, 2)
        var expected = original[0]
        expected["priority"] = 12
        XCTAssertEqual(NSDictionary(dictionary: written[0]), NSDictionary(dictionary: expected), "only priority changed")
        XCTAssertEqual(NSDictionary(dictionary: written[1]), NSDictionary(dictionary: original[1]), "other entries untouched")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains(#""weight":3"#) && text.contains(#""priority":12"#), "integers stay integers: \(text)")
        XCTAssertTrue(text.contains(#""future-field":{"depth":2}"#))
        XCTAssertTrue(text.contains(#""disable-cooling":false"#))

        // A stale index falls back to the name; the same value writes nothing; a missing name fails.
        let byName = try entries(try RuntimeOpenAICompatibilityListMutation.settingPriority(-1, ofProviderNamed: "Other", index: 0, in: data))
        XCTAssertEqual(byName[1]["priority"] as? Int, -1)
        XCTAssertEqual(byName[0]["priority"] as? Int, 7)
        XCTAssertNil(try RuntimeOpenAICompatibilityListMutation.settingPriority(7, ofProviderNamed: "DeepSeek 国内", index: 0, in: data))
        XCTAssertNil(try RuntimeOpenAICompatibilityListMutation.settingPriority(0, ofProviderNamed: "Other", index: 1, in: data), "missing priority is 0")
        XCTAssertThrowsError(try RuntimeOpenAICompatibilityListMutation.settingPriority(1, ofProviderNamed: "gone", index: nil, in: data))
    }

    func testAppendAllocatesThePrefixAgainstTheLatestListAndKeepsUnknownFields() throws {
        let data = Data(Self.configResponse.utf8)
        let provider = RuntimeOpenAICompatibilityWrite(
            name: "DeepSeek 海外", priority: 0, disabled: false, prefix: "pin-deepseek", baseURL: "https://c.example.test/v1",
            apiKeyEntries: [], models: [], headers: [:], disableCooling: false
        )
        let payload = try RuntimeOpenAICompatibilityListMutation.append(provider, to: data, allocatePrefixAgainst: ["pin-deepseek-2"])
        XCTAssertEqual(payload.outcome, .appended)
        let written = try entries(payload.requestBody)
        XCTAssertEqual(written.count, 3)
        XCTAssertEqual(written[2]["prefix"] as? String, "pin-deepseek-3", "numbered against the latest list and the direct providers")
        XCTAssertNotNil(written[0]["future-field"])
        XCTAssertEqual((written[0]["api-key-entries"] as? [[String: Any]])?.first?["proxy-url"] as? String, "socks5://127.0.0.1:1080")
        // A typed prefix is kept as typed.
        let typed = try entries(RuntimeOpenAICompatibilityListMutation.append(provider.withPrefix("relay"), to: data).requestBody)
        XCTAssertEqual(typed[2]["prefix"] as? String, "relay")
        // An engine config without providers answers null for the list.
        let empty = try entries(RuntimeOpenAICompatibilityListMutation.append(provider, to: Data(#"{"openai-compatibility":null}"#.utf8), allocatePrefixAgainst: []).requestBody)
        XCTAssertEqual(empty.first?["prefix"] as? String, "pin-deepseek")
    }

    func testClientReadsTheConfigAndPutsTheWholeList() async throws {
        defer { URLProtocolStub.reset() }
        URLProtocolStub.install { request, _ in
            if request.httpMethod == "GET" { return .json(200, Self.configResponse, for: request) }
            return .json(200, #"{"status":"ok"}"#, for: request)
        }
        let client = ManagementAPIClient(session: URLProtocolStub.makeSession())
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:18316"))
        try await client.setOpenAICompatibilityPriority(3, providerNamed: "Other", index: 1, baseURL: base, managementKey: "test-management-key")
        var requests = URLProtocolStub.recordedRequests
        XCTAssertEqual(requests.map { "\($0.0.httpMethod ?? "") \($0.0.url?.path ?? "")" },
                       ["GET /v0/management/config", "PUT /v0/management/openai-compatibility"])
        XCTAssertEqual(requests[0].0.value(forHTTPHeaderField: "Authorization"), "Bearer test-management-key")
        XCTAssertEqual(try entries(requests[1].1)[1]["priority"] as? Int, 3)

        // The same priority again: read only, nothing written.
        URLProtocolStub.install { request, _ in .json(200, Self.configResponse, for: request) }
        try await client.setOpenAICompatibilityPriority(7, providerNamed: "DeepSeek 国内", index: 0, baseURL: base, managementKey: "test-management-key")
        XCTAssertEqual(URLProtocolStub.recordedRequests.map { $0.0.httpMethod ?? "" }, ["GET"])

        URLProtocolStub.install { request, _ in
            if request.httpMethod == "GET" { return .json(200, Self.configResponse, for: request) }
            return .json(200, #"{"status":"ok"}"#, for: request)
        }
        let provider = RuntimeOpenAICompatibilityWrite(
            name: "New", priority: 0, disabled: false, prefix: "", baseURL: "https://d.example.test/v1",
            apiKeyEntries: [], models: [], headers: [:], disableCooling: false
        )
        let outcome = try await client.appendOpenAICompatibility(provider, allocatePrefixAgainst: [], baseURL: base, managementKey: "test-management-key")
        XCTAssertEqual(outcome, .appended)
        requests = URLProtocolStub.recordedRequests
        XCTAssertEqual(requests.map { "\($0.0.httpMethod ?? "") \($0.0.url?.path ?? "")" },
                       ["GET /v0/management/config", "PUT /v0/management/openai-compatibility"])
        XCTAssertEqual(try entries(requests[1].1).last?["prefix"] as? String, "pin-new")
    }
}

