import Foundation

/// The models page: the gateway's model directory (`permissions/api/data` → `groupedModels`, internal
/// `pin-x/…` ids dropped) with the latest health results, single tests and a bulk run.
@MainActor
final class ModelsWorkbenchStore: GatewayWorkbenchStore {
    @Published private(set) var rows: [GatewayModelRow] = []
    /// The latest bulk run (also one started by another client); nil when there was none since the
    /// gateway started.
    @Published private(set) var run: GatewayTestRun?
    /// The gateway answered 503 `engine_key_missing`: tests cannot run until the deployment is fixed.
    @Published private(set) var engineKeyMissing = false
    /// The model whose single test is running.
    @Published private(set) var testingModel: String?

    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
    private var pollToken: UUID?

    init(provider: GatewayClientProviding, pollInterval: Duration = .seconds(2)) {
        self.pollInterval = pollInterval
        super.init(provider: provider, section: .models)
    }

    deinit {
        pollTask?.cancel()
    }

    override func deactivate() {
        pollTask?.cancel()
        pollTask = nil
        pollToken = nil
        super.deactivate()
    }

    override func load(using client: GatewayAdminClient) async throws {
        // One read after another: with a stale key only one request gets the 401 (every 401
        // lengthens the gateway's global back-off).
        let data = try await client.permissionsData()
        try ensureCurrentLoad()
        let results = try await client.modelHealth()
        try ensureCurrentLoad()
        rows = GatewayModelRow.rows(groupedModels: data.groupedModels, health: results.models)
        apply(run: results.run)
    }

    /// One real upstream request for `modelID` (the engine picks the provider). The view asks for
    /// confirmation first: a test costs money.
    func test(_ modelID: String) async {
        guard rows.contains(where: { $0.id == modelID }) else { return }
        testingModel = modelID
        defer { testingModel = nil }
        await mutate { [weak self] client in
            do {
                _ = try await client.testModel(modelID, provider: nil)
                self?.engineKeyMissing = false
            } catch {
                self?.noteEngineKey(error)
                throw error
            }
        }
    }

    /// Starts a run over every model (or joins the one already going), then reads the health
    /// results every `pollInterval` until the run has finished or the page is left.
    func testAll() async {
        var started: GatewayTestRun?
        let succeeded = await mutate { [weak self] client in
            do {
                started = try await client.testAllModels().run
                self?.engineKeyMissing = false
            } catch {
                self?.noteEngineKey(error)
                throw error
            }
        }
        // The reload after the change has read the run already; take the start answer only when
        // nothing newer arrived.
        if succeeded, run == nil, let started {
            apply(run: started)
        }
    }

    // MARK: - Internals

    private func noteEngineKey(_ error: Error) {
        if case GatewayAdminError.server(_, "engine_key_missing", _) = error {
            engineKeyMissing = true
        }
    }

    private func apply(run newRun: GatewayTestRun?) {
        run = newRun
        if let newRun, !newRun.isFinished {
            startPolling()
        }
    }

    private func startPolling() {
        guard pollTask == nil, isActive else { return }
        let token = UUID()
        pollToken = token
        pollTask = Task { [weak self, pollInterval] in
            let outcome = await self?.poll(every: pollInterval) ?? .stopped
            guard let self, self.pollToken == token else { return }
            self.pollTask = nil
            self.pollToken = nil
            if outcome == .rejected {
                // A 401 latched the key (or the key changed meanwhile): show that state or reload.
                self.refreshNow()
            }
        }
    }

    private enum PollOutcome { case stopped, rejected }

    /// Reads the health results every `interval` until the run has finished, the page is left, or
    /// a read fails (the next refresh resumes polling).
    private func poll(every interval: Duration) async -> PollOutcome {
        while true {
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, isActive, let client = provider.gatewayAdminClient() else { return .stopped }
            let results: GatewayModelHealthResponse
            do {
                results = try await client.modelHealth()
            } catch GatewayAdminError.unauthorized {
                guard !Task.isCancelled else { return .stopped }
                provider.reportGatewayUnauthorized(rejectedKey: client.managementKey)
                return .rejected
            } catch {
                return .stopped
            }
            guard !Task.isCancelled, isActive else { return .stopped }
            rows = rows.map { GatewayModelRow(id: $0.id, groups: $0.groups, health: results.models[$0.id]) }
            run = results.run
            if results.run?.isFinished ?? true { return .stopped }
        }
    }
}
