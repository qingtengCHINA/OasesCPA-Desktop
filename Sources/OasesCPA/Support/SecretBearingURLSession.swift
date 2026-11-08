import Foundation

/// The transport of every client that sends a management key, an admin key or an API key, or
/// receives keys in its responses (gateway admin, engine and CPA Manager Plus management,
/// OpenRouter key exchange, lifecycle health checks).
///
/// `URLSession.shared` writes responses to the on-disk URL cache (`Cache.db`, readable by the
/// user's other processes) even when a request asks to ignore cached data: that policy only
/// skips reading the cache. The gateway sends no `Cache-Control`, so key lists would be stored.
/// This session keeps nothing: no URL cache, no cookies, no credential storage.
enum SecretBearingURLSession {
    /// A configuration for secret-bearing traffic, built on `.ephemeral` (memory-only storage).
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        return configuration
    }

    /// One shared session for all secret-bearing clients.
    static let shared = URLSession(configuration: configuration())
}
