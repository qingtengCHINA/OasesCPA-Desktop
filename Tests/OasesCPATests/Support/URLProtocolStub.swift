import Foundation

/// One stubbed HTTP transport for every test that injects a `URLSession`.
///
/// The handler is global (URLProtocol classes are registered by type), so tests that use it
/// must not run in parallel (`swift test` without `--parallel`). Every read and write of the
/// handler and of the recorded requests goes through one lock.
final class URLProtocolStub: URLProtocol {
    struct Result: @unchecked Sendable {
        let response: HTTPURLResponse
        let data: Data
        /// When set, the request is redirected here instead of answered (the updater tests use it).
        let redirectURL: URL?

        init(response: HTTPURLResponse, data: Data, redirectURL: URL? = nil) {
            self.response = response
            self.data = data
            self.redirectURL = redirectURL
        }

        /// A JSON answer for `request` with the given status.
        static func json(_ status: Int, _ body: String, for request: URLRequest) -> Result {
            Result(
                response: HTTPURLResponse(
                    url: request.url ?? URL(string: "http://127.0.0.1/")!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data: Data(body.utf8)
            )
        }
    }

    typealias Handler = @Sendable (URLRequest, Data?) -> Result

    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var recorded: [(URLRequest, Data?)] = []
    private static let lock = NSLock()

    /// Installs `handler` and starts a fresh recording (earlier requests are forgotten).
    static func install(_ handler: @escaping Handler) {
        lock.lock()
        Self.handler = handler
        recorded = []
        lock.unlock()
    }

    /// Removes the handler and the recording. A request without a handler fails.
    static func reset() {
        lock.lock()
        handler = nil
        recorded = []
        lock.unlock()
    }

    /// An ephemeral session whose only transport is this stub.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    /// A snapshot of every request the stub received, with its body, in arrival order.
    static var recordedRequests: [(URLRequest, Data?)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private static func answer(for request: URLRequest, body: Data?) -> Result? {
        lock.lock()
        recorded.append((request, body))
        let current = handler
        lock.unlock()
        return current?(request, body)
    }

    /// URLSession hands the protocol a body stream, not `httpBody`.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let result = Self.answer(for: request, body: Self.body(of: request)) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let redirectURL = result.redirectURL {
            var redirectedRequest = request
            redirectedRequest.url = redirectURL
            client?.urlProtocol(self, wasRedirectedTo: redirectedRequest, redirectResponse: result.response)
            // A followed redirect stops this load and starts a new one for `redirectURL`; when the
            // task's delegate refuses it, the 3xx below is the answer.
        }
        client?.urlProtocol(self, didReceive: result.response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
