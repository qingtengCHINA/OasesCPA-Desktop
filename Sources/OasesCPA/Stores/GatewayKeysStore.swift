import CryptoKit
import Foundation

/// One client key on the API key page. The key itself stays in memory only; every list shows
/// `maskedKey`.
struct GatewayKeyRow: Identifiable, Equatable, Sendable {
    let key: String
    let policy: GatewayKeyPolicy
    let usage: GatewayKeyUsage?

    var id: String { key }

    /// `first 4••••last 4`.
    var maskedKey: String { GatewayKeyRow.mask(key) }

    var label: String { policy.label.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func mask(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return trimmed.isEmpty ? "" : "••••" }
        return "\(trimmed.prefix(4))••••\(trimmed.suffix(4))"
    }
}

/// Why a key change was refused before anything was sent.
enum GatewayKeysStoreError: LocalizedError, Equatable {
    /// The server's policy changed after the editor was opened.
    case changedElsewhere
    case keyNotFound
    case internalKey
    case invalid([String])
    /// Provider pins would be dropped and the user has not confirmed it.
    case pinsNotConfirmed([String])

    var errorDescription: String? {
        switch self {
        case .changedElsewhere:
            OasesLocalization.localized("这把 Key 的策略已被其他客户端修改，本次修改没有保存。请关闭编辑器、刷新后重新编辑。")
        case .keyNotFound:
            OasesLocalization.localized("网关上已没有这把 Key，本次修改没有保存；请刷新列表。")
        case .internalKey:
            OasesLocalization.localized("这把 Key 是网关内部使用的引擎 Key，由网关自己管理，不能修改或删除。")
        case .invalid(let errors):
            errors.joined(separator: "\n")
        case .pinsNotConfirmed(let models):
            OasesLocalization.localizedFormat("保存会清除这些模型的供应商指定：%@。请先确认。", models.joined(separator: "、"))
        }
    }
}

/// The API key page (#2): client keys with their policies, managed through the gateway's
/// `permissions/api/save` actions. The gateway hides its internal engine key; as a second line of
/// defence a key whose SHA-256 equals the deployment's recorded engine-key fingerprint is never
/// listed, edited or deleted.
@MainActor
final class GatewayKeysStore: GatewayWorkbenchStore {
    @Published private(set) var rows: [GatewayKeyRow] = []
    /// Model ids by group, internal `pin-x/…` ids dropped.
    @Published private(set) var groupedModels: [String: [String]] = [:]
    /// Openai-compatibility providers that are switched off (`disabledProviders`).
    @Published private(set) var disabledProviders: [String] = []

    private let packEngineKeyFingerprint: @MainActor () -> String?

    /// `section` is the page whose ⌘R refreshes this store (the dashboard's summary card has its own).
    init(
        provider: GatewayClientProviding,
        packEngineKeyFingerprint: @escaping @MainActor () -> String?,
        section: AppSection = .accessKeys
    ) {
        self.packEngineKeyFingerprint = packEngineKeyFingerprint
        super.init(provider: provider, section: section)
    }

    /// The providers a key may pin for `model` (openai-compatibility providers, in the engine's
    /// order), read on demand for the editor. A 401 latches the key like any other request.
    func pinnableProviders(for model: String) async -> Result<[GatewayModelProvider], GatewayAdminError> {
        guard let client = provider.gatewayAdminClient() else { return .failure(.unauthorized) }
        do {
            let response = try await client.modelProviders(model: model)
            return .success(response.pinnableProviders)
        } catch let error as GatewayAdminError {
            if case .unauthorized = error {
                provider.reportGatewayUnauthorized(rejectedKey: client.managementKey)
                refreshNow()
            }
            return .failure(error)
        } catch {
            return .failure(.transport(SecretRedactor.redact(error.localizedDescription, secrets: [])))
        }
    }

    override func load(using client: GatewayAdminClient) async throws {
        let data = try await client.permissionsData()
        try ensureCurrentLoad()
        apply(data)
    }

    /// Creates a key (the gateway's format, from `RuntimeAPIKeyGenerator`) with `policy`. Returns
    /// it for the one-time display, or nil when the gateway refused.
    func addKey(policy: GatewayKeyPolicy) async -> String? {
        let key = RuntimeAPIKeyGenerator.generate()
        let saved = await mutate { client in
            _ = try await client.save(.addKey(key: key, policy: policy))
        }
        return saved ? key : nil
    }

    /// Saves `draft` after reading the key's current policy again: when the server's policy is no
    /// longer the draft's baseline, nothing is sent. Otherwise the draft's fields are written over
    /// the server's latest object, so fields this app does not know are kept.
    func savePolicy(key: String, draft: GatewayKeyPolicyDraft) async -> Bool {
        guard !isInternal(key) else { return false }
        return await mutate(
            rereading: { client in try await client.permissionsData() },
            then: { client, data in
                let errors = draft.validationErrors()
                guard errors.isEmpty else { throw GatewayKeysStoreError.invalid(errors) }
                let dropped = draft.pinsThatWouldBeDropped()
                guard dropped.isEmpty else { throw GatewayKeysStoreError.pinsNotConfirmed(dropped) }
                guard data.keys.contains(key) else { throw GatewayKeysStoreError.keyNotFound }
                let current = data.policies[key] ?? .projectedDefault
                guard current.hasSameKnownFields(as: draft.baseline) else { throw GatewayKeysStoreError.changedElsewhere }
                var merged = draft.policy
                merged.extra = current.extra
                _ = try await client.save(.savePolicy(key: key, policy: merged))
            }
        )
    }

    /// Renames a key without touching any other policy field (`set_label`).
    func setLabel(key: String, label: String) async -> Bool {
        guard !isInternal(key) else { return false }
        let trimmed = String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(GatewayKeyPolicy.maximumLabelLength))
        return await mutate { client in
            _ = try await client.save(.setLabel(key: key, label: trimmed))
        }
    }

    /// Deletes a key from the engine and the policy store. The gateway refuses the last key
    /// (409 `last_api_key`, its internal engine key counts).
    func deleteKey(_ key: String) async -> Bool {
        guard !isInternal(key) else { return false }
        return await mutate { client in
            _ = try await client.save(.deleteKey(key: key))
        }
    }

    // MARK: - Internals

    private func apply(_ data: GatewayPermissionsData) {
        rows = data.keys
            .filter { !isInternal($0) }
            .map { key in
                GatewayKeyRow(key: key, policy: data.policies[key] ?? .projectedDefault, usage: data.usage[key])
            }
        var models: [String: [String]] = [:]
        for (group, ids) in data.groupedModels {
            let visible = ids.filter { InternalModelID.publicName($0) == $0 }
            if !visible.isEmpty { models[group] = visible }
        }
        groupedModels = models
        disabledProviders = data.disabledProviders
    }

    private func isInternal(_ key: String) -> Bool {
        guard let fingerprint = packEngineKeyFingerprint()?.lowercased(), !fingerprint.isEmpty else { return false }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return digest == fingerprint
    }
}
