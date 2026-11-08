import Combine
import Foundation

/// Whether the gateway admin API can be used for the current target.
enum GatewayAvailability: Equatable, Sendable {
    /// No attached target, or no management key loaded.
    case notAttached
    /// A legacy (0.1.x) native deployment: it has no gateway until it is upgraded.
    case needsUpgrade
    /// A legacy Docker deployment: the gateway is not offered for Docker.
    case dockerUnsupported
    /// The gateway rejected the current management key (401); latched until the key changes or
    /// the user verifies again.
    case credentialsRejected
    case ready
}

/// The source of gateway clients for the page stores (`DeploymentStore` in the app).
@MainActor
protocol GatewayClientProviding: AnyObject {
    var gatewayAvailability: GatewayAvailability { get }
    /// A client for the current target; nil whenever `gatewayAvailability != .ready`.
    func gatewayAdminClient() -> GatewayAdminClient?
    /// Latches the current key after a 401, so that nothing sends it again.
    func reportGatewayUnauthorized()
    /// The user's explicit "verify again": clears the latch.
    func retryGatewayAuthentication()
}

enum GatewayWorkbenchPhase: Equatable {
    case unavailable(GatewayAvailability)
    case loading
    case loaded
    case failed(String)
}

extension Notification.Name {
    /// Posted by ⌘R (toolbar and menu); `userInfo["section"]` is the `AppSection.rawValue` of the
    /// page that is shown.
    static let oasesRefreshCurrentSection = Notification.Name("oases.refresh-current-section")
}

/// Base class of the stores of the gateway pages: one load at a time, results of a superseded
/// load are dropped, a failed refresh keeps the loaded data and shows a banner, and a 401
/// latches the key instead of being retried.
///
/// Subclasses override `load(using:)` and call `ensureCurrentLoad()` after their last `await`,
/// before they assign any state.
@MainActor
class GatewayWorkbenchStore: ObservableObject {
    @Published private(set) var phase: GatewayWorkbenchPhase = .loading
    /// A banner for a failed refresh or mutation while data stays on screen.
    @Published private(set) var actionError: String?
    @Published private(set) var isMutating = false

    let provider: GatewayClientProviding
    /// The page this store belongs to; ⌘R for another page is ignored. Nil accepts every ⌘R.
    let section: AppSection?
    private(set) var isActive = false
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var refreshSubscription: AnyCancellable?

    init(provider: GatewayClientProviding, section: AppSection? = nil) {
        self.provider = provider
        self.section = section
    }

    deinit {
        loadTask?.cancel()
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        // Delivered on the main queue before anything reads the notification.
        refreshSubscription = NotificationCenter.default.publisher(for: .oasesRefreshCurrentSection)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, self.isActive else { return }
                let raw = notification.userInfo?["section"] as? String
                if let section = self.section, raw != section.rawValue { return }
                self.refreshNow()
            }
        refreshNow()
    }

    func deactivate() {
        isActive = false
        refreshSubscription = nil
        generation += 1
        loadTask?.cancel()
        loadTask = nil
    }

    /// Starts a fresh load and drops any load still running.
    func refreshNow() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        guard let client = provider.gatewayAdminClient() else {
            phase = .unavailable(provider.gatewayAvailability)
            return
        }
        let current = generation
        if phase != .loaded {
            phase = .loading
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.load(using: client)
                guard current == self.generation else { return }
                self.phase = .loaded
                self.actionError = nil
            } catch is CancellationError {
                return
            } catch {
                guard current == self.generation else { return }
                self.handleLoadFailure(error)
            }
        }
    }

    /// The user's "verify again" after a rejected key.
    func retryAuthentication() {
        provider.retryGatewayAuthentication()
        refreshNow()
    }

    /// Reads the page's data. Subclasses override it; the base reads nothing.
    func load(using client: GatewayAdminClient) async throws {}

    /// Throws `CancellationError` when this load was superseded (by `refreshNow()`,
    /// `deactivate()` or a mutation): its results must not be applied.
    func ensureCurrentLoad() throws {
        try Task.checkCancellation()
    }

    /// Runs one change; on success the page is read again before this returns. Returns whether
    /// the change succeeded. Failures go to `actionError`; a 401 latches the key.
    @discardableResult
    func mutate(_ operation: @escaping @MainActor (GatewayAdminClient) async throws -> Void) async -> Bool {
        guard !isMutating else { return false }
        guard let client = provider.gatewayAdminClient() else {
            phase = .unavailable(provider.gatewayAvailability)
            return false
        }
        isMutating = true
        actionError = nil
        defer { isMutating = false }
        do {
            try await operation(client)
        } catch is CancellationError {
            return false
        } catch {
            if case GatewayAdminError.unauthorized = error {
                latchRejectedKey()
            } else {
                actionError = Self.message(for: error)
            }
            return false
        }
        refreshNow()
        await loadTask?.value
        return true
    }

    /// A change that must start from the server's current state: `rereading` reads it right
    /// before `then` saves, with the same client (so a save never builds on a stale copy).
    @discardableResult
    func mutate<Snapshot: Sendable>(
        rereading: @escaping @MainActor (GatewayAdminClient) async throws -> Snapshot,
        then save: @escaping @MainActor (GatewayAdminClient, Snapshot) async throws -> Void
    ) async -> Bool {
        await mutate { client in
            let snapshot = try await rereading(client)
            try await save(client, snapshot)
        }
    }

    // MARK: - Internals

    private func handleLoadFailure(_ error: Error) {
        if case GatewayAdminError.unauthorized = error {
            latchRejectedKey()
            return
        }
        let message = Self.message(for: error)
        if phase == .loaded {
            actionError = message
        } else {
            phase = .failed(message)
        }
    }

    private func latchRejectedKey() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        provider.reportGatewayUnauthorized()
        phase = .unavailable(.credentialsRejected)
    }

    private static func message(for error: Error) -> String {
        if let error = error as? GatewayAdminError {
            return error.errorDescription ?? OasesLocalization.localized("网关返回了无法解析的响应。")
        }
        return SecretRedactor.redact(error.localizedDescription, secrets: [])
    }
}
