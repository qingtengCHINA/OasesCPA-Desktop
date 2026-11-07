import Foundation
import XCTest
@testable import OasesCPA

final class RuntimeProviderConnectivityContractTests: XCTestCase {
    func testGeminiClaudeAndOpenAICompatibleFactoriesBuildSafeEndpointsAndHeaders() throws {
        let gemini = RuntimeDirectProviderCredential(
            kind: .gemini,
            index: 0,
            payload: RuntimeProviderCredentialPayload(values: [
                "api-key": .string("gemini-secret"),
                "base-url": .string("https://generativelanguage.googleapis.com/"),
                "headers": .object([
                    "X-Trace": .string("trace-value")
                ])
            ])
        )
        let claude = RuntimeDirectProviderCredential(
            kind: .claude,
            index: 1,
            payload: RuntimeProviderCredentialPayload(values: [
                "api-key": .string("claude-secret"),
                "base-url": .string("https://api.anthropic.com/v1/"),
                "headers": .object([
                    "anthropic-version": .string("2023-06-01")
                ])
            ])
        )
        let openAI = RuntimeOpenAICompatibility(
            name: "OpenAI Pool",
            baseURL: "https://gateway.example.test/v1/",
            apiKeyEntries: [
                RuntimeProviderAPIKey(apiKey: "openai-secret")
            ],
            headers: [
                "X-Provider": "native-test"
            ]
        )

        let plan = RuntimeProviderConnectivityFactory.plan(
            directCredentials: [
                .gemini: [gemini],
                .claude: [claude]
            ],
            openAICompatibility: [openAI]
        )
        let geminiExecution = try XCTUnwrap(plan.executions.first { $0.target.id == "direct.gemini.0" })
        let claudeExecution = try XCTUnwrap(plan.executions.first { $0.target.id == "direct.claude.1" })
        let openAIExecution = try XCTUnwrap(plan.executions.first { $0.target.id == "openai.0.0" })

        let geminiRequest = try XCTUnwrap(geminiExecution.requests.first)
        XCTAssertEqual(geminiRequest.method, "GET")
        XCTAssertEqual(geminiRequest.url, "https://generativelanguage.googleapis.com/v1beta/models")
        XCTAssertEqual(geminiRequest.header["x-goog-api-key"], "gemini-secret")
        XCTAssertEqual(geminiRequest.header["X-Trace"], "trace-value")

        let claudeRequest = try XCTUnwrap(claudeExecution.requests.first)
        XCTAssertEqual(claudeRequest.url, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(claudeRequest.header["x-api-key"], "claude-secret")
        XCTAssertEqual(claudeRequest.header["anthropic-version"], "2023-06-01")

        let openAIRequest = try XCTUnwrap(openAIExecution.requests.first)
        XCTAssertEqual(openAIRequest.url, "https://gateway.example.test/v1/models")
        XCTAssertEqual(openAIRequest.header["Authorization"], "Bearer openai-secret")
        XCTAssertEqual(openAIRequest.header["X-Provider"], "native-test")
        XCTAssertEqual(plan.preview.outboundRequestUpperBound, 3)
    }

    func testPublishedTargetAndResultDoNotCarrySecretsURLsOrResponseBody() {
        let target = RuntimeProviderConnectivityTarget(
            id: "openai.0.0",
            providerTitle: "OpenAI Pool · 密钥 1",
            providerKind: "Compatible",
            host: "gateway.example.test",
            endpointLabel: "GET /models",
            systemImage: "arrow.left.arrow.right"
        )
        let result = RuntimeProviderConnectivityResult(
            target: target,
            status: .success,
            modelCount: 3,
            statusCode: 200,
            durationMilliseconds: 42,
            message: "发现 3 个模型。"
        )

        let forbiddenLabels: Set<String> = [
            "apiKey", "authIndex", "header", "headers", "url", "body",
            "responseBody", "responseHeader", "responseMetadata"
        ]
        let targetLabels = Set(Mirror(reflecting: target).children.compactMap(\.label))
        let resultLabels = Set(Mirror(reflecting: result).children.compactMap(\.label))
        XCTAssertTrue(forbiddenLabels.isDisjoint(with: targetLabels))
        XCTAssertTrue(forbiddenLabels.isDisjoint(with: resultLabels))

        let secret = "super-secret-provider-key"
        XCTAssertFalse(String(describing: target).contains(secret))
        XCTAssertFalse(String(describing: result).contains(secret))
        XCTAssertFalse(String(describing: result).contains("https://"))
        XCTAssertFalse(result.message.contains("raw-response-body"))
    }

    func testMaskedKeyWithoutAuthIndexIsSkippedWithoutRequests() throws {
        let credential = RuntimeDirectProviderCredential(
            kind: .gemini,
            index: 0,
            payload: RuntimeProviderCredentialPayload(values: [
                "api-key": .string("••••••••••••"),
                "base-url": .string("https://generativelanguage.googleapis.com")
            ])
        )
        let plan = RuntimeProviderConnectivityFactory.plan(
            directCredentials: [.gemini: [credential]],
            openAICompatibility: []
        )
        let execution = try XCTUnwrap(plan.executions.first)

        XCTAssertTrue(execution.requests.isEmpty)
        XCTAssertNotNil(execution.skipReason)
        XCTAssertEqual(plan.preview.outboundRequestUpperBound, 0)
        XCTAssertEqual(plan.preview.skippedCount, 1)
    }

    func testModelCountParserRecognizesDataAndModelsDeduplicatesAndRejectsUnsafeBodies() {
        XCTAssertEqual(
            RuntimeProviderConnectivityModelParser.modelCount(from: #"""
            {"data":[{"id":"gpt-4"},{"id":"GPT-4"},{"name":"claude-3"},{"value":" "},42]}
            """#),
            2
        )
        XCTAssertEqual(
            RuntimeProviderConnectivityModelParser.modelCount(from: #"""
            {"models":["models/gemini-1","models/GEMINI-1","gemini-2"]}
            """#),
            2
        )
        XCTAssertEqual(
            RuntimeProviderConnectivityModelParser.modelCount(from: #"{"data":[]}"#),
            0
        )
        XCTAssertNil(RuntimeProviderConnectivityModelParser.modelCount(from: #"{"error":"not a model list"}"#))
        XCTAssertNil(RuntimeProviderConnectivityModelParser.modelCount(from: "not-json"))

        let oversizedBody = String(repeating: "x", count: 2_000_001)
        XCTAssertNil(RuntimeProviderConnectivityModelParser.modelCount(from: oversizedBody))
    }

    func testDisabledOpenAICompatibleProviderIsSkippedWithoutNetworkRequest() throws {
        let provider = RuntimeOpenAICompatibility(
            name: "Disabled Pool",
            disabled: true,
            baseURL: "https://gateway.example.test/v1",
            apiKeyEntries: [
                RuntimeProviderAPIKey(apiKey: "key-one"),
                RuntimeProviderAPIKey(apiKey: "key-two")
            ]
        )
        let plan = RuntimeProviderConnectivityFactory.plan(
            directCredentials: [:],
            openAICompatibility: [provider]
        )

        XCTAssertEqual(plan.executions.count, 2)
        XCTAssertTrue(plan.executions.allSatisfy { $0.requests.isEmpty })
        XCTAssertTrue(plan.executions.allSatisfy { $0.skipReason != nil })
        XCTAssertEqual(plan.preview.outboundRequestUpperBound, 0)
        XCTAssertEqual(plan.preview.skippedCount, 2)
    }
}
