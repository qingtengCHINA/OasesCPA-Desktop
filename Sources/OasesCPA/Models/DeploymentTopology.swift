import Foundation

/// How a deployment is laid out on its target.
///
/// - `legacy`: app 0.1.x — the engine (CLIProxyAPI) serves `/v1` and its management API on
///   8317, CPA Manager Plus on 18317.
/// - `gateway`: the open edition — the Oases gateway serves `/v1` on 8317 and its admin API on
///   18320, the engine moves to 18316, CPA Manager Plus stays on 18317.
///
/// Every listener binds IPv4 loopback only, so every URL here uses `127.0.0.1`, never
/// `localhost` (it may resolve to `::1`, where nothing listens).
enum DeploymentTopology: String, Codable, Sendable {
    case legacy
    case gateway
}

enum DeploymentPorts {
    static let gatewayAPI = 8317
    static let gatewayAdmin = 18320
    static let engine = 18316
    static let cpamp = 18317
    static let legacyEngine = 8317

    /// The loopback ports an SSH tunnel forwards, each to the same port on the target's loopback.
    static func tunnelPorts(for topology: DeploymentTopology) -> [Int] {
        switch topology {
        case .gateway: [gatewayAPI, gatewayAdmin, cpamp, engine]
        case .legacy: [legacyEngine, cpamp]
        }
    }
}

/// The loopback base URLs of one deployment, as seen from this Mac (directly for a local
/// target, through the SSH tunnel for a remote one).
struct DeploymentEndpoints: Equatable, Sendable {
    let topology: DeploymentTopology
    /// The OpenAI-compatible endpoint clients call (with `/v1`).
    let clientAPIBaseURL: URL
    /// The gateway admin API (`/cpa-admin/*`, `/healthz`); nil for a legacy deployment.
    let gatewayAdminBaseURL: URL?
    /// The engine, including its management API (`/v0/management/*`).
    let engineBaseURL: URL
    /// CPA Manager Plus (usage analytics, monitoring, panel backend).
    let cpampBaseURL: URL

    init(topology: DeploymentTopology) {
        self.topology = topology
        clientAPIBaseURL = Self.loopback(DeploymentPorts.gatewayAPI, path: "/v1")
        cpampBaseURL = Self.loopback(DeploymentPorts.cpamp)
        switch topology {
        case .gateway:
            gatewayAdminBaseURL = Self.loopback(DeploymentPorts.gatewayAdmin)
            engineBaseURL = Self.loopback(DeploymentPorts.engine)
        case .legacy:
            gatewayAdminBaseURL = nil
            engineBaseURL = Self.loopback(DeploymentPorts.legacyEngine)
        }
    }

    private static func loopback(_ port: Int, path: String = "") -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }
}
