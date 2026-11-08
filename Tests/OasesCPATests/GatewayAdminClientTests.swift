import XCTest
@testable import OasesCPA

/// Contract tests of the gateway admin client. Status codes and error bodies are the ones the
/// open-source gateway sends (Server repo, gateway/server.mjs: `authenticate`, the
/// `/permissions/api/save` handler, `sendPolicyUnavailable`, `handleModelProviders`, packs).
final class GatewayAdminClientTests: XCTestCase {
    private let baseURL = URL(string: "http://127.0.0.1:18320")!

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    private func makeClient(key: String = "test-key") -> GatewayAdminClient {
        GatewayAdminClient(baseURL: baseURL, managementKey: key, session: URLProtocolStub.makeSession())
    }

    private func stub(_ status: Int, _ body: String) {
        URLProtocolStub.install { request, _ in .json(status, body, for: request) }
    }

    private func assertThrows<T>(
        _ expected: GatewayAdminError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as GatewayAdminError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    private func thrownError<T>(_ operation: () async throws -> T) async -> GatewayAdminError? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error as? GatewayAdminError
        }
    }

    // MARK: Requests

    func testGetSetsManagementHeaderPathAndNoAuthorization() async throws {
        stub(200, #"{"keys":[],"permissions":{},"schema_version":2}"#)
        let value: RuntimeJSONValue = try await makeClient().get("/cpa-admin/permissions/api/data")
        guard case .object(let object) = value else { return XCTFail("expected an object") }
        XCTAssertEqual(object["schema_version"], .number(2))

        let requests = URLProtocolStub.recordedRequests
        XCTAssertEqual(requests.count, 1)
        let req = try XCTUnwrap(requests.first?.0)
        XCTAssertEqual(req.url?.absoluteString, "http://127.0.0.1:18320/cpa-admin/permissions/api/data")
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-management-key"), "test-key")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(req.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertEqual(req.timeoutInterval, 15)
    }

    func testGetAddsQueryItemsAndTimeout() async throws {
        stub(200, #"{"model":"glm-5","providers":[]}"#)
        let _: RuntimeJSONValue = try await makeClient().get(
            "/cpa-admin/permissions/api/models/providers",
            query: [URLQueryItem(name: "model", value: "glm-5 / a&b")],
            timeout: GatewayAdminTimeouts.modelProviders
        )
        let req = try XCTUnwrap(URLProtocolStub.recordedRequests.first?.0)
        let components = try XCTUnwrap(req.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(components.path, "/cpa-admin/permissions/api/models/providers")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "model", value: "glm-5 / a&b")])
        XCTAssertEqual(req.timeoutInterval, 30)
    }

    func testPostSendsJSONBodyWithContentTypeAndNoAuthorization() async throws {
        struct Body: Encodable, Sendable { let action: String; let key: String }
        stub(200, #"{"success":true}"#)
        let value: RuntimeJSONValue = try await makeClient().post(
            "/cpa-admin/permissions/api/save",
            body: Body(action: "set_label", key: "client-a"),
            timeout: GatewayAdminTimeouts.keyMutation
        )
        XCTAssertEqual(value, .object(["success": .boolean(true)]))

        let (req, body) = try XCTUnwrap(URLProtocolStub.recordedRequests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-management-key"), "test-key")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(req.timeoutInterval, 20)
        let sent = try XCTUnwrap(body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(sent, ["action": "set_label", "key": "client-a"])
    }

    func testTimeoutsOutlastTheGatewayUnauthorizedBackoff() async throws {
        // The gateway delays every 401 by up to MAX_BACKOFF_MS = 10 s (one global counter,
        // gateway/server.mjs). A timeout of 10 s would turn a late 401 into a timeout and the
        // latch would never close; every authenticated request waits at least 15 s.
        XCTAssertEqual(GatewayAdminTimeouts.gatewayMaximumUnauthorizedDelay, 10)
        XCTAssertGreaterThanOrEqual(GatewayAdminTimeouts.minimumAuthenticated, 15)
        XCTAssertGreaterThan(GatewayAdminTimeouts.minimumAuthenticated, GatewayAdminTimeouts.gatewayMaximumUnauthorizedDelay)
        for timeout in [
            GatewayAdminTimeouts.standard, GatewayAdminTimeouts.modelProviders, GatewayAdminTimeouts.modelReorder,
            GatewayAdminTimeouts.keyMutation, GatewayAdminTimeouts.modelTest, GatewayAdminTimeouts.modelTestAll,
        ] {
            XCTAssertGreaterThanOrEqual(timeout, GatewayAdminTimeouts.minimumAuthenticated)
        }

        // A shorter timeout from a caller is raised to the minimum.
        stub(200, #"{"success":true}"#)
        let _: RuntimeJSONValue = try await makeClient().get("/cpa-admin/host/status", timeout: 2)
        struct Body: Encodable, Sendable { let action: String }
        let _: RuntimeJSONValue = try await makeClient().post("/cpa-admin/permissions/api/save", body: Body(action: "x"), timeout: 5)
        let timeouts = URLProtocolStub.recordedRequests.map(\.0.timeoutInterval)
        XCTAssertEqual(timeouts, [15, 15])
    }

    func testTimeoutConventions() {
        XCTAssertEqual(GatewayAdminTimeouts.standard, 15)
        XCTAssertEqual(GatewayAdminTimeouts.modelProviders, 30)
        XCTAssertEqual(GatewayAdminTimeouts.modelReorder, 30)
        XCTAssertEqual(GatewayAdminTimeouts.keyMutation, 20)
        XCTAssertEqual(GatewayAdminTimeouts.modelTest, 70)
        XCTAssertEqual(GatewayAdminTimeouts.modelTestAll, 15)
    }

    func testPostAllowingStatusReturnsAnAllowedNon2xxAnswer() async throws {
        struct Body: Encodable, Sendable { let model: String }
        stub(409, #"{"error":"A test is already running","code":"conflict"}"#)
        let result = try await makeClient().postAllowingStatus(
            "/cpa-admin/permissions/api/models/test",
            body: Body(model: "glm-5"),
            allowed: [409]
        )
        XCTAssertEqual(result.status, 409)
        XCTAssertEqual(String(data: result.data, encoding: .utf8), #"{"error":"A test is already running","code":"conflict"}"#)

        stub(502, #"{"error":"Engine model list unavailable","code":"models_unavailable"}"#)
        await assertThrows(.server(status: 502, code: "models_unavailable", message: "Engine model list unavailable")) {
            try await self.makeClient().postAllowingStatus("/cpa-admin/permissions/api/models/test", body: Body(model: "x"), allowed: [409])
        }
        stub(401, #"{"error":"Unauthorized management key"}"#)
        await assertThrows(.unauthorized) {
            try await self.makeClient().postAllowingStatus("/cpa-admin/permissions/api/models/test", body: Body(model: "x"), allowed: [401])
        }
    }

    // MARK: 401

    func testUnauthorizedIsNotRetried() async {
        stub(401, #"{"error":"Unauthorized management key"}"#)
        let client = makeClient()
        await assertThrows(.unauthorized) { try await client.get("/cpa-admin/packs/data", as: RuntimeJSONValue.self) }
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 1)
    }

    // MARK: Errors

    func testParsesStringAndObjectErrorShapes() async {
        let client = makeClient()
        stub(404, #"{"error":"Key not found in config"}"#)
        await assertThrows(.server(status: 404, code: nil, message: "Key not found in config")) {
            try await client.get("/cpa-admin/permissions/api/data", as: RuntimeJSONValue.self)
        }
        stub(503, #"{"error":{"message":"x","code":"policy_unavailable"}}"#)
        await assertThrows(.server(status: 503, code: "policy_unavailable", message: "x")) {
            try await client.get("/cpa-admin/permissions/api/data", as: RuntimeJSONValue.self)
        }
        stub(400, #"{"error":"bad","code":"pricing_required"}"#)
        await assertThrows(.server(status: 400, code: "pricing_required", message: "bad")) {
            try await client.get("/cpa-admin/packs/data", as: RuntimeJSONValue.self)
        }
        // The exact body of sendPolicyUnavailable (object shape with a type field).
        stub(503, #"{"error":{"message":"Policy store unavailable; request blocked until a valid policy is available.","type":"service_unavailable","code":"policy_unavailable"}}"#)
        await assertThrows(.server(status: 503, code: "policy_unavailable", message: "Policy store unavailable; request blocked until a valid policy is available.")) {
            try await client.get("/cpa-admin/permissions/api/data", as: RuntimeJSONValue.self)
        }
        // A body that is not JSON, and an empty body.
        stub(500, "upstream exploded")
        await assertThrows(.server(status: 500, code: nil, message: "upstream exploded")) {
            try await client.get("/cpa-admin/host/status", as: RuntimeJSONValue.self)
        }
        stub(405, "")
        let empty = await thrownError { try await client.get("/cpa-admin/host/status", as: RuntimeJSONValue.self) }
        guard case .server(405, nil, let message)? = empty else { return XCTFail("expected a 405 server error, got \(String(describing: empty))") }
        XCTAssertFalse(message.isEmpty)
    }

    func testKnownGatewayCodesMapToReadableMessages() async throws {
        let client = makeClient()
        let cases: [(Int, String, String)] = [
            (409, #"{"success":false,"error":"The internal engine key is managed by the gateway","code":"internal_key"}"#, "internal_key"),
            (409, #"{"error":"At least one API key must remain configured","code":"last_api_key"}"#, "last_api_key"),
            (502, #"{"error":"Engine provider list unavailable","code":"management_unavailable"}"#, "management_unavailable"),
            (502, #"{"ok":false,"error":"Engine rejected the provider update","code":"management_timeout"}"#, "management_timeout"),
            (503, #"{"error":"Internal engine key is not configured","code":"engine_key_missing"}"#, "engine_key_missing"),
            (503, #"{"error":"Policy store unavailable; API key was not added","code":"policy_unavailable"}"#, "policy_unavailable")
        ]
        var descriptions = Set<String>()
        for (status, body, code) in cases {
            stub(status, body)
            let error = await thrownError { try await client.get("/cpa-admin/permissions/api/data", as: RuntimeJSONValue.self) }
            guard case .server(status, code, _)? = error else { return XCTFail("\(code): \(String(describing: error))") }
            let description = try XCTUnwrap(error?.errorDescription)
            XCTAssertFalse(description.contains("HTTP"), "\(code) has its own message: \(description)")
            descriptions.insert(description)
        }
        XCTAssertEqual(descriptions.count, cases.count, "every code reads differently")

        stub(418, #"{"error":"I am a teapot","code":"teapot"}"#)
        let other = await thrownError { try await client.get("/cpa-admin/host/status", as: RuntimeJSONValue.self) }
        let otherDescription = try XCTUnwrap(other?.errorDescription)
        XCTAssertTrue(otherDescription.contains("418"))
        XCTAssertTrue(otherDescription.contains("I am a teapot"))
        XCTAssertNotNil(GatewayAdminError.unauthorized.errorDescription)
    }

    func testErrorDescriptionNeverContainsManagementKey() async throws {
        let managementKey = "test-key-123456"
        let clientKey = "sk-" + String(repeating: "x", count: 24)
        let client = makeClient(key: managementKey)
        stub(400, #"{"error":"Invalid key format: "# + managementKey + " and " + clientKey + #"","code":"bad_key"}"#)
        let error = await thrownError { try await client.get("/cpa-admin/permissions/api/data", as: RuntimeJSONValue.self) }
        let thrown = try XCTUnwrap(error)
        for text in [thrown.errorDescription ?? "", String(describing: thrown), thrown.localizedDescription] {
            XCTAssertFalse(text.contains(managementKey), text)
            XCTAssertFalse(text.contains(clientKey), text)
            XCTAssertTrue(text.contains("••••"), text)
        }

        // Also when the body is not JSON, and in a decoding failure that echoes the body.
        stub(500, "boom " + managementKey)
        let plain = await thrownError { try await client.get("/cpa-admin/host/status", as: RuntimeJSONValue.self) }
        XCTAssertFalse(String(describing: plain).contains(managementKey))
        stub(200, #"{"value":""# + managementKey + #""}"#)
        struct Strict: Decodable { let missing: Int }
        let decoding = await thrownError { try await client.get("/cpa-admin/host/status", as: Strict.self) }
        guard case .decoding? = decoding else { return XCTFail("expected a decoding error, got \(String(describing: decoding))") }
        XCTAssertFalse(String(describing: decoding).contains(managementKey))
    }

    func testServerMessageIsLimitedTo300Characters() async {
        stub(500, #"{"error":""# + String(repeating: "é", count: 500) + #""}"#)
        let error = await thrownError { try await self.makeClient().get("/cpa-admin/host/status", as: RuntimeJSONValue.self) }
        guard case .server(500, nil, let message)? = error else { return XCTFail("expected a server error") }
        XCTAssertLessThanOrEqual(message.count, 300)
    }

    func testTransportFailureAndRedirectAreErrors() async {
        URLProtocolStub.reset()   // no handler: the stub fails the request
        let transport = await thrownError { try await self.makeClient().get("/cpa-admin/host/status", as: RuntimeJSONValue.self) }
        guard case .transport? = transport else { return XCTFail("expected a transport error, got \(String(describing: transport))") }

        // A redirect is never followed, so the management key never travels to another URL.
        URLProtocolStub.install { request, _ in
            URLProtocolStub.Result(
                response: HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "http://127.0.0.1:9/elsewhere"])!,
                data: Data(),
                redirectURL: URL(string: "http://127.0.0.1:9/elsewhere")
            )
        }
        let redirected = await thrownError { try await self.makeClient().get("/cpa-admin/host/status", as: RuntimeJSONValue.self) }
        guard case .server(302, nil, _)? = redirected else { return XCTFail("expected the 302 itself, got \(String(describing: redirected))") }
        XCTAssertEqual(URLProtocolStub.recordedRequests.map { $0.0.url?.path }, ["/cpa-admin/host/status"])
    }

    func testDecoderUsesNoKeyStrategy() async throws {
        struct Shape: Decodable { let schema_version: Int }
        stub(200, #"{"schema_version":2}"#)
        let shape: Shape = try await makeClient().get("/cpa-admin/permissions/api/data")
        XCTAssertEqual(shape.schema_version, 2)
    }

    // MARK: JSON support

    func testUnknownFieldsAreCapturedAndWrittenBack() throws {
        struct Rule: Codable, Equatable {
            static let known: Set<String> = ["label", "enabled"]
            var label: String
            var enabled: Bool
            var unknown: [String: RuntimeJSONValue]

            enum CodingKeys: String, CodingKey { case label, enabled }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                label = try container.decode(String.self, forKey: .label)
                enabled = try container.decode(Bool.self, forKey: .enabled)
                unknown = try UnknownFields.capture(from: decoder, known: Self.known)
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(label, forKey: .label)
                try container.encode(enabled, forKey: .enabled)
                try UnknownFields.encode(unknown, to: encoder, skipping: Self.known)
            }
        }
        let json = #"{"label":"a","enabled":true,"daily_token_limit":5000,"attestation":{"mode":"observe"},"tags":["x",null]}"#
        let rule = try JSONDecoder().decode(Rule.self, from: Data(json.utf8))
        XCTAssertEqual(rule.unknown["daily_token_limit"], .number(5000))
        XCTAssertEqual(rule.unknown["attestation"], .object(["mode": .string("observe")]))
        XCTAssertNil(rule.unknown["label"])

        var edited = rule
        edited.label = "b"
        edited.unknown["label"] = .string("must not override the known field")
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any]
        XCTAssertEqual(written?["label"] as? String, "b")
        XCTAssertEqual(written?["daily_token_limit"] as? Int, 5000)
        XCTAssertEqual((written?["attestation"] as? [String: String])?["mode"], "observe")
        XCTAssertEqual((written?["tags"] as? [Any])?.count, 2)
        XCTAssertEqual(written?.count, 5)
    }

    func testGatewayDatesReadAndWriteMillisecondISO8601AndEpochMilliseconds() throws {
        // The gateway writes JavaScript's Date#toISOString(): UTC with milliseconds.
        let date = try XCTUnwrap(GatewayDates.date(from: "2026-11-08T01:02:03.456Z"))
        XCTAssertEqual(GatewayDates.epochMilliseconds(from: date), 1_794_099_723_456)
        XCTAssertEqual(GatewayDates.string(from: date), "2026-11-08T01:02:03.456Z")
        let fromEpoch = GatewayDates.date(fromEpochMilliseconds: 1_794_099_723_456)
        XCTAssertEqual(GatewayDates.epochMilliseconds(from: fromEpoch), 1_794_099_723_456)
        XCTAssertEqual(GatewayDates.string(from: fromEpoch), "2026-11-08T01:02:03.456Z")
        XCTAssertEqual(GatewayDates.date(from: "2026-11-08T01:02:03Z").map(GatewayDates.epochMilliseconds), 1_794_099_723_000)
        XCTAssertNil(GatewayDates.date(from: "yesterday"))
        XCTAssertNil(GatewayDates.date(from: ""))
    }
}
