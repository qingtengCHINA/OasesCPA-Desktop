import Foundation
import XCTest
@testable import OasesCPA

/// The engine's `config.yaml` and CPA Manager Plus's `/usage-service/config` writes.
///
/// CLIProxyAPI v8.0.51 sends no `ETag` for `config.yaml` and ignores `If-Match` (measured,
/// `docs/acceptance/engine-v8.0.51-probe.md`): the conditional path below never fires against it
/// and a file write there is last-writer-wins. The tests keep the path correct for an engine that
/// does send one. CPA Manager Plus (the oases fork) answers `ETag: "<updatedAtMs>"` and refuses a
/// stale version with 409 `manager_config_conflict` (`managerconfig/handler.go`).
final class ConfigYAMLConcurrencyTests: XCTestCase {
    private let baseURL = URL(string: "http://127.0.0.1:18316")!
    private let cpampURL = URL(string: "http://127.0.0.1:18317")!
    private let key = "test-management-key"

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    private static func yamlResult(_ status: Int, body: String, headers: [String: String], for request: URLRequest) -> URLProtocolStub.Result {
        URLProtocolStub.Result(
            response: HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!,
            data: Data(body.utf8)
        )
    }

    func testSaveSendsIfMatchWhenSnapshotHasETag() async throws {
        URLProtocolStub.install { request, _ in
            if request.httpMethod == "GET" {
                return Self.yamlResult(200, body: "port: 18316\n", headers: [
                    "Content-Type": "application/yaml; charset=utf-8",
                    "ETag": "abc"
                ], for: request)
            }
            return .json(200, #"{"changed":["config"],"ok":true}"#, for: request)
        }
        let client = ManagementAPIClient(session: URLProtocolStub.makeSession())

        let snapshot = try await client.configYAML(baseURL: baseURL, managementKey: key)
        XCTAssertEqual(snapshot.etag, "abc")
        XCTAssertEqual(String(decoding: snapshot.data, as: UTF8.self), "port: 18316\n")
        try await client.saveConfigYAML(snapshot.data, etag: snapshot.etag, baseURL: baseURL, managementKey: key)

        let put = try XCTUnwrap(URLProtocolStub.recordedRequests.first { $0.0.httpMethod == "PUT" })
        XCTAssertEqual(put.0.url?.path, "/v0/management/config.yaml")
        XCTAssertEqual(put.0.value(forHTTPHeaderField: "If-Match"), "abc")
        XCTAssertEqual(put.1, snapshot.data)
    }

    func testSaveOmitsIfMatchWithoutETag() async throws {
        // The measured v8.0.51 answer: no ETag, no Last-Modified.
        URLProtocolStub.install { request, _ in
            if request.httpMethod == "GET" {
                return Self.yamlResult(200, body: "port: 18316\n", headers: [
                    "Content-Type": "application/yaml; charset=utf-8",
                    "Cache-Control": "no-store"
                ], for: request)
            }
            return .json(200, #"{"changed":["config"],"ok":true}"#, for: request)
        }
        let client = ManagementAPIClient(session: URLProtocolStub.makeSession())

        let snapshot = try await client.configYAML(baseURL: baseURL, managementKey: key)
        XCTAssertNil(snapshot.etag)
        try await client.saveConfigYAML(snapshot.data, etag: snapshot.etag, baseURL: baseURL, managementKey: key)

        let put = try XCTUnwrap(URLProtocolStub.recordedRequests.first { $0.0.httpMethod == "PUT" })
        XCTAssertNil(put.0.value(forHTTPHeaderField: "If-Match"))
        XCTAssertFalse(ManagementAPIClient.configYAMLWritesAreChecked(etag: snapshot.etag))
        XCTAssertTrue(ManagementAPIClient.configYAMLWritesAreChecked(etag: "abc"))
    }

    func testQuickConfigFileWriteCarriesTheReadETag() async throws {
        let yaml = "port: 18316\napi-keys: []\n"
        URLProtocolStub.install { request, _ in
            if request.httpMethod == "GET" {
                return Self.yamlResult(200, body: yaml, headers: ["ETag": "\"v7\""], for: request)
            }
            return .json(200, #"{"changed":["config"],"ok":true}"#, for: request)
        }
        let client = ManagementAPIClient(session: URLProtocolStub.makeSession())
        try await client.updateQuickConfigurationValue(.bool(true), for: .disableCooling, baseURL: baseURL, managementKey: key)
        let put = try XCTUnwrap(URLProtocolStub.recordedRequests.first { $0.0.httpMethod == "PUT" })
        XCTAssertEqual(put.0.value(forHTTPHeaderField: "If-Match"), "\"v7\"")
    }

    func testPreconditionFailuresMapToConfigConflict() async {
        for status in [412, 428] {
            URLProtocolStub.install { request, _ in
                .json(status, #"{"error":"precondition"}"#, for: request)
            }
            let client = ManagementAPIClient(session: URLProtocolStub.makeSession())
            do {
                try await client.saveConfigYAML(Data("port: 1\n".utf8), etag: "abc", baseURL: baseURL, managementKey: key)
                XCTFail("HTTP \(status) must throw")
            } catch let error as ManagementAPIError {
                guard case .configConflict = error else {
                    return XCTFail("HTTP \(status) → \(error), expected .configConflict")
                }
                let message = OasesLocalization.localized(
                    "配置已被其他人修改，请重新加载。",
                    language: .simplifiedChinese
                )
                XCTAssertTrue(message.hasPrefix("配置已被其他人修改，请重新加载"))
                XCTAssertEqual(error.errorDescription, OasesLocalization.localized("配置已被其他人修改，请重新加载。"))
                XCTAssertNotEqual(
                    OasesLocalization.localized("配置已被其他人修改，请重新加载。", language: .english),
                    "配置已被其他人修改，请重新加载。",
                    "the conflict text has an English translation"
                )
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
        // Other failures keep their own mapping.
        URLProtocolStub.install { request, _ in
            .json(400, #"{"error":"invalid_yaml","message":"yaml: line 1"}"#, for: request)
        }
        do {
            try await ManagementAPIClient(session: URLProtocolStub.makeSession())
                .saveConfigYAML(Data("host: [\n".utf8), etag: nil, baseURL: baseURL, managementKey: key)
            XCTFail("HTTP 400 must throw")
        } catch let error as ManagementAPIError {
            guard case .server(let status, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 400)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testManagerConfigPayloadCarriesUpdatedAtMsAndIfMatch() async throws {
        let config = RuntimeManagerConfig(
            cpaConnection: .init(engineBaseURL: "http://127.0.0.1:18316", managementKey: key),
            updatedAtMs: 1_730_000_000_000
        )
        let responseBody = #"{"config":{"cpaConnection":{"cpaBaseUrl":"http://127.0.0.1:18316"},"updatedAtMs":1730000000500},"source":"database"}"#
        URLProtocolStub.install { request, _ in
            .json(200, responseBody, for: request)
        }
        let client = ManagementAPIClient(session: URLProtocolStub.makeSession())

        let saved = try await client.saveManagerConfig(config, baseURL: cpampURL, managementKey: key)
        XCTAssertEqual(saved.config.updatedAtMs, 1_730_000_000_500)

        let (request, body) = try XCTUnwrap(URLProtocolStub.recordedRequests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/usage-service/config")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"1730000000000\"")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
        let encodedConfig = try XCTUnwrap(object["config"] as? [String: Any])
        XCTAssertEqual((encodedConfig["updatedAtMs"] as? NSNumber)?.int64Value, 1_730_000_000_000)
        XCTAssertNotNil(encodedConfig["cpaConnection"])

        // A config never read from the server (no version) sends neither.
        var unversioned = config
        unversioned.updatedAtMs = nil
        URLProtocolStub.install { request, _ in .json(200, responseBody, for: request) }
        _ = try await client.saveManagerConfig(unversioned, baseURL: cpampURL, managementKey: key)
        let (plainRequest, plainBody) = try XCTUnwrap(URLProtocolStub.recordedRequests.first)
        XCTAssertNil(plainRequest.value(forHTTPHeaderField: "If-Match"))
        let plainObject = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(plainBody)) as? [String: Any])
        XCTAssertNil((plainObject["config"] as? [String: Any])?["updatedAtMs"])

        // The fork's stale-version answer (`response.Error` with `UsageServiceErrorCode`).
        URLProtocolStub.install { request, _ in
            .json(409, #"{"error":"manager config conflict","code":"manager_config_conflict"}"#, for: request)
        }
        do {
            _ = try await client.saveManagerConfig(config, baseURL: cpampURL, managementKey: key)
            XCTFail("409 must throw")
        } catch let error as ManagementAPIError {
            guard case .managerConfigConflict = error else { return XCTFail("\(error)") }
            let source = "CPAMP 设置已被其他人修改，请重新读取后再保存。"
            XCTAssertEqual(error.errorDescription, OasesLocalization.localized(source))
            XCTAssertNotEqual(OasesLocalization.localized(source, language: .english), source)
        }

        // Another 409 (for example an environment-locked connection) is not a version conflict.
        URLProtocolStub.install { request, _ in
            .json(409, #"{"error":"CPA connection setup is managed by environment variables","code":"connection_env_managed"}"#, for: request)
        }
        do {
            _ = try await client.saveManagerConfig(config, baseURL: cpampURL, managementKey: key)
            XCTFail("409 must throw")
        } catch let error as ManagementAPIError {
            guard case .server(let status, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, 409)
        }
    }
}
