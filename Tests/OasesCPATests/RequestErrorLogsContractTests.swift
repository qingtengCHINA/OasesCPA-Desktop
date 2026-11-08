import Foundation
import XCTest
@testable import OasesCPA

/// The engine's request-error files (`GET /v0/management/request-error-logs`, `…/:name`).
/// Shapes measured on v8.0.51 (`docs/acceptance/engine-v8.0.51-probe.md`): the list is
/// `{"files":[{"name","size","modified"}]}` (`modified` in Unix seconds, newest first, only
/// `error-*.log`; empty while `request-log` is on); a download is the file as `text/plain`
/// with `Content-Disposition: attachment`. File names here are made up.
final class RequestErrorLogsContractTests: XCTestCase {
    private let baseURL = URL(string: "http://127.0.0.1:18316")!
    private let key = "test-management-key"

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    func testDecodesRequestErrorLogListAndBuildsDownloadPath() async throws {
        let list = #"{"files":[{"name":"error-v1-chat-completions-sample.log","size":2048,"modified":1794120387,"future":"kept out"},{"name":"error-probe sample.log","size":25,"modified":1794120300}]}"#
        URLProtocolStub.install { request, _ in
            if request.url?.path == "/v0/management/request-error-logs" {
                return .json(200, list, for: request)
            }
            return URLProtocolStub.Result(
                response: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": "text/plain; charset=utf-8",
                    "Content-Disposition": "attachment; filename=\"error-probe sample.log\""
                ])!,
                data: Data("synthetic line\n".utf8)
            )
        }
        let client = ManagementAPIClient(session: URLProtocolStub.makeSession())

        let files = try await client.requestErrorLogs(baseURL: baseURL, managementKey: key)
        XCTAssertEqual(files.map(\.name), ["error-v1-chat-completions-sample.log", "error-probe sample.log"])
        XCTAssertEqual(files.first?.size, 2048)
        XCTAssertEqual(files.first?.modifiedAt, Date(timeIntervalSince1970: 1_794_120_387))

        let data = try await client.downloadRequestErrorLog(name: "error-probe sample.log", baseURL: baseURL, managementKey: key)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "synthetic line\n")
        let download = try XCTUnwrap(URLProtocolStub.recordedRequests.last?.0)
        XCTAssertEqual(download.url?.absoluteString, "http://127.0.0.1:18316/v0/management/request-error-logs/error-probe%20sample.log")
        XCTAssertEqual(download.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")

        // Characters that would change the request are encoded, path separators refused.
        XCTAssertEqual(
            RuntimeRequestErrorLogFiles.downloadPath(for: "error-a?b#c%.log"),
            "/v0/management/request-error-logs/error-a%3Fb%23c%25.log"
        )
        for name in ["", "../config.yaml", "error-a/b.log", "error-a\\b.log", "main.log", "error-x.txt", "error-\n.log"] {
            XCTAssertNil(RuntimeRequestErrorLogFiles.downloadPath(for: name), name)
            do {
                _ = try await client.downloadRequestErrorLog(name: name, baseURL: baseURL, managementKey: key)
                XCTFail("\(name) must be refused before any request")
            } catch ManagementAPIError.invalidRequestErrorLogName {
            }
        }

        // An empty list (request-log on, or no errors yet) and a missing list both read as empty.
        URLProtocolStub.install { request, _ in .json(200, #"{"files":[]}"#, for: request) }
        let empty = try await client.requestErrorLogs(baseURL: baseURL, managementKey: key)
        XCTAssertEqual(empty, [])
        URLProtocolStub.install { request, _ in .json(200, "{}", for: request) }
        let missing = try await client.requestErrorLogs(baseURL: baseURL, managementKey: key)
        XCTAssertEqual(missing, [])
    }

    func testSavedErrorLogIsRedactedAndShowsPublicModelNames() {
        let key = "cpa_" + String(repeating: "a1", count: 32)
        let clientKey = "sk-" + String(repeating: "Z", count: 30)
        let raw = "Authorization: Bearer \(key)\nbody: {\"model\":\"pin-openrouter-2/gpt-4o\",\"api_key\":\"\(clientKey)\"}\nsecret-literal-xyz\n"
        let saved = String(
            decoding: RuntimeRequestErrorLogFiles.redactedContents(Data(raw.utf8), secrets: ["secret-literal-xyz"]),
            as: UTF8.self
        )
        XCTAssertFalse(saved.contains(key))
        XCTAssertFalse(saved.contains(clientKey))
        XCTAssertFalse(saved.contains("secret-literal-xyz"))
        XCTAssertFalse(saved.contains("pin-openrouter-2/"))
        XCTAssertTrue(saved.contains("gpt-4o"))
        XCTAssertTrue(saved.contains(SecretRedactor.mask))
        // A file that is not UTF-8 is not written as garbage: only valid text is kept.
        let binary = RuntimeRequestErrorLogFiles.redactedContents(Data([0xff, 0xfe, 0x41]), secrets: [])
        XCTAssertFalse(binary.isEmpty)
    }

    @MainActor
    func testStoreLoadsOnceAndStopsAfterUnauthorized() async {
        URLProtocolStub.install { request, _ in
            .json(401, #"{"error":"invalid management key"}"#, for: request)
        }
        let store = RequestErrorLogsStore(session: URLProtocolStub.makeSession())
        await store.load(baseURL: baseURL, managementKey: key)
        XCTAssertEqual(store.files, [])
        XCTAssertEqual(store.errorMessage, ManagementAPIError.unauthorized.errorDescription)
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(URLProtocolStub.recordedRequests.count, 1, "a 401 is not retried")
    }
}
