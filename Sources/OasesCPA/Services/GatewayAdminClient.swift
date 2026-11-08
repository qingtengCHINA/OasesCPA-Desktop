import Foundation

/// Request timeouts of the gateway admin API, in seconds.
enum GatewayAdminTimeouts {
    static let standard: TimeInterval = 10
    /// `GET /cpa-admin/permissions/api/models/providers` (reads the engine's provider list).
    static let modelProviders: TimeInterval = 30
    /// `POST /cpa-admin/permissions/api/models/reorder` (writes the engine configuration).
    static let modelReorder: TimeInterval = 30
    /// `add_key` / `delete_key` (engine configuration plus policy store, with rollback).
    static let keyMutation: TimeInterval = 20
    /// `POST /cpa-admin/permissions/api/models/test` (one real upstream call).
    static let modelTest: TimeInterval = 70
    /// `POST /cpa-admin/permissions/api/models/test-all` (returns at once; the run continues).
    static let modelTestAll: TimeInterval = 15
}

/// Client of the gateway admin API on the admin listener (`http://127.0.0.1:18320`).
///
/// - Authenticates with the `x-management-key` header only; never sends `Authorization`.
/// - A 401 throws `.unauthorized` and is never retried: every failed attempt lengthens the
///   gateway's global back-off. Callers latch the key (`GatewayClientProviding`).
/// - Redirects are not followed, so the key never travels to another URL.
/// - Responses decode with a plain `JSONDecoder` (no key strategy): models spell out their
///   `CodingKeys`.
struct GatewayAdminClient: Sendable {
    let baseURL: URL
    let managementKey: String
    let session: URLSession

    init(baseURL: URL, managementKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.managementKey = managementKey
        self.session = session
    }

    func get<R: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        timeout: TimeInterval = GatewayAdminTimeouts.standard,
        as type: R.Type = R.self
    ) async throws -> R {
        let request = try makeRequest(path: path, query: query, method: "GET", body: nil, timeout: timeout)
        let (status, data) = try await perform(request)
        guard (200..<300).contains(status) else {
            throw GatewayAdminError.from(status: status, data: data, secrets: secrets)
        }
        return try decode(type, from: data)
    }

    func post<B: Encodable & Sendable, R: Decodable>(
        _ path: String,
        body: B,
        timeout: TimeInterval = GatewayAdminTimeouts.standard,
        as type: R.Type = R.self
    ) async throws -> R {
        let (status, data) = try await send(path, body: body, timeout: timeout)
        guard (200..<300).contains(status) else {
            throw GatewayAdminError.from(status: status, data: data, secrets: secrets)
        }
        return try decode(type, from: data)
    }

    /// For endpoints whose non-2xx answers carry data (for example 409 for a test that is
    /// already running). A 401 still throws `.unauthorized`, even when listed in `allowed`.
    func postAllowingStatus<B: Encodable & Sendable>(
        _ path: String,
        body: B,
        allowed: Set<Int>,
        timeout: TimeInterval = GatewayAdminTimeouts.standard
    ) async throws -> (status: Int, data: Data) {
        let (status, data) = try await send(path, body: body, timeout: timeout)
        guard status != 401 else { throw GatewayAdminError.unauthorized }
        guard (200..<300).contains(status) || allowed.contains(status) else {
            throw GatewayAdminError.from(status: status, data: data, secrets: secrets)
        }
        return (status, data)
    }

    // MARK: - Internals

    private var secrets: [String] { [managementKey] }

    private func send<B: Encodable & Sendable>(_ path: String, body: B, timeout: TimeInterval) async throws -> (Int, Data) {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(body)
        } catch {
            throw GatewayAdminError.decoding(GatewayAdminError.sanitized(String(describing: error), secrets: secrets))
        }
        let request = try makeRequest(path: path, query: [], method: "POST", body: encoded, timeout: timeout)
        return try await perform(request)
    }

    private func makeRequest(path: String, query: [URLQueryItem], method: String, body: Data?, timeout: TimeInterval) throws -> URLRequest {
        guard path.hasPrefix("/"),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw GatewayAdminError.invalidResponse
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw GatewayAdminError.invalidResponse }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(managementKey, forHTTPHeaderField: "x-management-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Int, Data) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: GatewayNoRedirectDelegate.shared)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw GatewayAdminError.transport(GatewayAdminError.sanitized(error.localizedDescription, secrets: secrets))
        }
        guard let http = response as? HTTPURLResponse else { throw GatewayAdminError.invalidResponse }
        if http.statusCode == 401 { throw GatewayAdminError.unauthorized }
        return (http.statusCode, data)
    }

    private func decode<R: Decodable>(_ type: R.Type, from data: Data) throws -> R {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GatewayAdminError.decoding(GatewayAdminError.sanitized(String(describing: error), secrets: secrets))
        }
    }
}

/// Refuses every redirect: the answer is the 3xx itself.
private final class GatewayNoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = GatewayNoRedirectDelegate()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
