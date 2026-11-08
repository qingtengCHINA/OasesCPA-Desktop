import Foundation

/// The target-side operations `DeploymentStore` runs. The app uses `live`; store-level tests
/// inject fakes, so they exercise the store's decisions (topology, fingerprint, profile)
/// without running scripts, SSH or the network.
struct DeploymentStoreServices: Sendable {
    /// Runs the install script (`DeploymentExecutor.execute`); the second argument is the
    /// deployment control token.
    var execute: @Sendable (DeploymentExecutionRequest, String) async throws -> DeploymentExecutionResult
    /// Probes the target and its install directory (`DeploymentProbeService.probe`).
    var probe: @Sendable (DeploymentExecutionRequest) async throws -> DeploymentProbe
    /// Reads the credentials of an existing deployment (`ExistingDeploymentAdoptionService`).
    var readExistingCredentials: @Sendable (DeploymentExecutionRequest) async throws -> DeploymentExecutionResult
    /// Upgrade and rollback (`DeploymentMaintenanceService`).
    var upgrade: @Sendable (DeploymentExecutionRequest) async throws -> DeploymentMaintenanceResult
    var rollback: @Sendable (DeploymentExecutionRequest) async throws -> DeploymentMaintenanceResult
    /// The session of the health checks (`RuntimeLifecycleService(session:endpoints:)`).
    var healthSession: URLSession
    /// System notifications of the patrol (`HealthNotificationService`): target and detail,
    /// target and topology.
    var notifyDegraded: @Sendable (String, String) async -> Void = { target, detail in
        await HealthNotificationService.shared.notifyDegraded(target: target, detail: detail)
    }
    var notifyRecovered: @Sendable (String, DeploymentTopology) async -> Void = { target, topology in
        await HealthNotificationService.shared.notifyRecovered(target: target, topology: topology)
    }

    static let live = DeploymentStoreServices(
        execute: { request, controlToken in
            try await DeploymentExecutor().execute(request: request, controlToken: controlToken)
        },
        probe: { request in
            try await DeploymentProbeService().probe(
                target: request.target,
                host: request.host,
                user: request.user,
                port: request.port,
                privateKeyPath: request.privateKeyPath,
                installDirectory: request.installDirectory
            )
        },
        readExistingCredentials: { request in
            try await ExistingDeploymentAdoptionService().readCredentials(request: request)
        },
        upgrade: { request in
            try await DeploymentMaintenanceService().upgrade(request: request)
        },
        rollback: { request in
            try await DeploymentMaintenanceService().rollback(request: request)
        },
        healthSession: SecretBearingURLSession.shared
    )

    /// The lifecycle service for a topology's endpoints, with this value's health session.
    func lifecycle(_ endpoints: DeploymentEndpoints) -> RuntimeLifecycleService {
        RuntimeLifecycleService(session: healthSession, endpoints: endpoints)
    }
}
