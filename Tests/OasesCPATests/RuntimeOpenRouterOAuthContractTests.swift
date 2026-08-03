import CryptoKit
import Foundation
import XCTest
@testable import OasesCPA

final class RuntimeOpenRouterOAuthContractTests: XCTestCase {
    func testMakeSessionBuildsOpenRouterPKCEAuthorizationURLMatchingSession() throws {
        let callbackURL = URL(string: "http://127.0.0.1:43127/callback")!
        let session = try RuntimeOpenRouterOAuth.makeSession(callbackURL: callbackURL)
        let components = try XCTUnwrap(
            URLComponents(url: session.authorizationURL, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )

        XCTAssertEqual(session.authorizationURL.scheme, "https")
        XCTAssertEqual(session.authorizationURL.host, "openrouter.ai")
        XCTAssertEqual(session.authorizationURL.path, "/auth")
        XCTAssertEqual(query["callback_url"], callbackURL.absoluteString)
        XCTAssertEqual(query["state"], session.state)
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["code_challenge"], codeChallenge(for: session.codeVerifier))
        XCTAssertFalse(session.state.isEmpty)
        XCTAssertFalse(session.codeVerifier.isEmpty)
    }

    func testLoopbackAuthorizationCallbackAcceptsMatchingCodeAndState() throws {
        let callback = RuntimeOpenRouterOAuth.parseLoopbackCallbackTarget(
            "/callback?code=auth-code-123&state=expected-state"
        )
        let session = RuntimeOpenRouterOAuthSession(
            callbackURL: URL(string: "http://127.0.0.1:43127/callback")!,
            authorizationURL: URL(string: "https://openrouter.ai/auth")!,
            codeVerifier: "verifier",
            state: "expected-state"
        )

        let result = RuntimeOpenRouterOAuth.authorizationGrant(from: callback, session: session)

        XCTAssertEqual(
            result,
            .success(
                RuntimeOpenRouterAuthorizationGrant(
                    code: "auth-code-123",
                    codeVerifier: "verifier"
                )
            )
        )
    }

    func testLoopbackAuthorizationCallbackRejectsWrongState() {
        let callback = RuntimeOpenRouterOAuth.parseLoopbackCallbackTarget(
            "/callback?code=auth-code-123&state=attacker-state"
        )
        let session = makeSession(state: "expected-state")

        let result = RuntimeOpenRouterOAuth.authorizationGrant(from: callback, session: session)

        XCTAssertEqual(result, .failure(.stateMismatch))
    }

    func testLoopbackProviderErrorWithMatchingStateIsRejectedAsAuthorizationDenied() {
        let callback = RuntimeOpenRouterOAuth.parseLoopbackCallbackTarget(
            "/callback?error=access_denied&error_description=User%20cancelled&state=expected-state"
        )
        let session = makeSession(state: "expected-state")

        let result = RuntimeOpenRouterOAuth.authorizationGrant(from: callback, session: session)

        XCTAssertEqual(result, .failure(.authorizationDenied("User cancelled")))
    }

    func testLoopbackCallbackRejectsIllegalPathAndMissingCodeAsMalformed() {
        let session = makeSession(state: "expected-state")

        let illegalPath = RuntimeOpenRouterOAuth.parseLoopbackCallbackTarget(
            "/other?code=auth-code&state=expected-state"
        )
        let missingCode = RuntimeOpenRouterOAuth.parseLoopbackCallbackTarget(
            "/callback?state=expected-state"
        )

        XCTAssertEqual(
            RuntimeOpenRouterOAuth.authorizationGrant(from: illegalPath, session: session),
            .failure(.invalidCallback("回调地址不是预期的 /callback 路径。"))
        )
        XCTAssertEqual(
            RuntimeOpenRouterOAuth.authorizationGrant(from: missingCode, session: session),
            .failure(.invalidCallback("授权回调没有包含 code。"))
        )
    }

    func testTokenExchangeRequestUsesOnlyOpenRouterPKCEJSONBodyWithoutAuthorizationHeader() throws {
        let request = try RuntimeOpenRouterOAuth.tokenExchangeRequest(
            code: " authorization-code ",
            codeVerifier: " verifier "
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, RuntimeOpenRouterOAuth.tokenEndpoint)
        XCTAssertEqual(
            Set(json.keys),
            ["code", "code_verifier", "code_challenge_method"]
        )
        XCTAssertEqual(json["code"] as? String, "authorization-code")
        XCTAssertEqual(json["code_verifier"] as? String, "verifier")
        XCTAssertEqual(json["code_challenge_method"] as? String, "S256")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testAppendingProviderPreservesUnknownFieldsAuthIndexAndExistingEntries() throws {
        let response = Data(
            #"""
            {
              "openai-compatibility": [
                {
                  "name": "existing-provider",
                  "base-url": "https://existing.example/v1",
                  "api-key-entries": [
                    {"api-key": "existing-secret", "auth-index": "auth-existing"}
                  ],
                  "future-routing": {"region": "us-east", "priority": 7},
                  "auth-index": "provider-existing"
                }
              ]
            }
            """#.utf8
        )
        let provider = RuntimeOpenAICompatibilityWrite(
            name: RuntimeOpenRouterOAuth.providerName,
            priority: 0,
            disabled: false,
            prefix: "",
            baseURL: RuntimeOpenRouterOAuth.apiBaseURL.absoluteString,
            apiKeyEntries: [
                RuntimeProviderAPIKey(apiKey: "transient-key")
            ],
            models: [],
            headers: [:],
            disableCooling: false
        )

        let payload = try RuntimeOpenAICompatibilityListMutation.append(
            provider,
            to: response
        )
        let body = try XCTUnwrap(payload.requestBody)
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
        let existing = try XCTUnwrap(entries.first(where: { $0["name"] as? String == "existing-provider" }))
        let appended = try XCTUnwrap(entries.first(where: { $0["name"] as? String == RuntimeOpenRouterOAuth.providerName }))
        let futureRouting = try XCTUnwrap(existing["future-routing"] as? [String: Any])

        XCTAssertEqual(payload.outcome, .appended)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(existing["auth-index"] as? String, "provider-existing")
        let existingKey = try XCTUnwrap(
            (existing["api-key-entries"] as? [[String: Any]])?.first
        )
        XCTAssertEqual(existingKey["api-key"] as? String, "existing-secret")
        XCTAssertEqual(existingKey["auth-index"] as? String, "auth-existing")
        XCTAssertEqual(futureRouting["region"] as? String, "us-east")
        XCTAssertEqual(futureRouting["priority"] as? Int, 7)
        XCTAssertEqual(appended["base-url"] as? String, RuntimeOpenRouterOAuth.apiBaseURL.absoluteString)
    }

    func testAppendingProviderWithCaseInsensitiveExistingNameReturnsExistingWithoutRequestBody() throws {
        let response = Data(
            #"""
            {
              "openaiCompatibility": [
                {
                  "name": "OpenRouter-OAuth",
                  "base-url": "https://existing.example/v1"
                }
              ]
            }
            """#.utf8
        )
        let provider = RuntimeOpenAICompatibilityWrite(
            name: " openrouter-oauth ",
            priority: 0,
            disabled: false,
            prefix: "",
            baseURL: "https://openrouter.ai/api/v1",
            apiKeyEntries: [],
            models: [],
            headers: [:],
            disableCooling: false
        )

        let payload = try RuntimeOpenAICompatibilityListMutation.append(
            provider,
            to: response
        )

        XCTAssertEqual(payload.outcome, .existing(index: 0))
        XCTAssertNil(payload.requestBody)
    }

    private func makeSession(state: String) -> RuntimeOpenRouterOAuthSession {
        RuntimeOpenRouterOAuthSession(
            callbackURL: URL(string: "http://127.0.0.1:43127/callback")!,
            authorizationURL: RuntimeOpenRouterOAuth.authorizationEndpoint,
            codeVerifier: "verifier",
            state: state
        )
    }

    private func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
