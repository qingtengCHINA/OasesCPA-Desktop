import Foundation
@testable import OasesCPA

/// A `GatewayClientProviding` for page-store tests: clients use `URLProtocolStub`, and a 401 latches
/// like `DeploymentStore` (only a rejection of the current key latches).
@MainActor
final class FakeGatewayClientProvider: GatewayClientProviding {
    var availability: GatewayAvailability = .ready
    var latched = false
    /// The key the next client carries (the user may change it while a request is running).
    var currentKey = "fake-key"
    private(set) var rejectedKeys: [String] = []
    private(set) var retryCount = 0
    let session = URLProtocolStub.makeSession()

    var reportCount: Int { rejectedKeys.count }
    var gatewayAvailability: GatewayAvailability { latched ? .credentialsRejected : availability }

    func gatewayAdminClient() -> GatewayAdminClient? {
        guard gatewayAvailability == .ready else { return nil }
        return GatewayAdminClient(baseURL: URL(string: "http://127.0.0.1:18320")!, managementKey: currentKey, session: session)
    }

    /// Same rule as `DeploymentStore`: only a rejection of the current key latches.
    func reportGatewayUnauthorized(rejectedKey: String) {
        rejectedKeys.append(rejectedKey)
        guard rejectedKey == currentKey else { return }
        latched = true
    }

    func retryGatewayAuthentication() {
        retryCount += 1
        latched = false
    }
}
