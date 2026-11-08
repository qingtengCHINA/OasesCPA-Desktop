import Foundation

/// Readable messages of the model packs page.
enum ModelPacksError: LocalizedError, Equatable {
    case invalid([String])
    case gateway(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let messages): messages.joined(separator: "\n")
        case .gateway(let message): message
        }
    }

    /// The pack service's codes (`packs.mjs` `HTTP_STATUS`) as text; anything else keeps the
    /// general gateway message. A 401 is not mapped (the key is latched instead).
    static func map(_ error: Error) -> Error {
        guard case GatewayAdminError.server(_, let code, let message) = error else { return error }
        switch code {
        case "pricing_required":
            return ModelPacksError.gateway(GatewayPackValidation.pricingRequiredMessage)
        case "not_found":
            return ModelPacksError.gateway(OasesLocalization.localized("这个模型包或 Key 已不存在（可能已被其他客户端删除），请刷新后再试。"))
        case "conflict":
            return ModelPacksError.gateway(OasesLocalization.localized("与网关当前的数据冲突，本次修改没有保存；请刷新后再试。"))
        case "unavailable":
            return ModelPacksError.gateway(OasesLocalization.localized("网关的模型包数据暂时不可用（无法读取或写入），模型包 Key 也已暂停服务；请检查网关数据目录后重试。"))
        case "invalid":
            return ModelPacksError.gateway(OasesLocalization.localizedFormat("网关拒绝了这次修改：%@", message))
        default:
            return error
        }
    }
}

/// Packs (left), the selected pack's members and keys (right). New keys' plaintext lives only in
/// `revealedKeys` until `dismissRevealedKeys()`: never saved, logged or put on the clipboard.
@MainActor
final class ModelPacksStore: GatewayWorkbenchStore {
    @Published private(set) var packs: [GatewayPack] = []
    @Published private(set) var keysByPack: [String: [GatewayPackKey]] = [:]
    /// The gateway's internal engine key exists and is configured: pack keys can be served.
    @Published private(set) var engineKeyReady = true
    @Published private(set) var storeAvailable = true
    @Published private(set) var persistenceFailing = false
    /// The engine's models, for the member picker.
    @Published private(set) var models: [String] = []
    @Published private(set) var revealedKeys: [GatewayCreatedPackKey] = []

    private let clock: () -> Date

    init(provider: GatewayClientProviding, clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        super.init(provider: provider, section: .modelPacks)
    }

    override func load(using client: GatewayAdminClient) async throws {
        let data = try await client.packsData()
        try ensureCurrentLoad()
        // One read after another: a rejected key gets one 401, not one per pack.
        var keys: [String: [GatewayPackKey]] = [:]
        for pack in data.packs {
            keys[pack.id] = try await client.packKeys(packID: pack.id)
            try ensureCurrentLoad()
        }
        packs = data.packs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        keysByPack = keys
        engineKeyReady = data.engineKeyReady
        storeAvailable = data.storeAvailable
        persistenceFailing = data.persistenceFailing
        models = data.models
    }

    func pack(id: String?) -> GatewayPack? {
        packs.first { $0.id == id }
    }

    func hasCostLimitedKeys(packID: String?) -> Bool {
        guard let packID else { return false }
        return (keysByPack[packID] ?? []).contains { $0.limits.totalCostUSD != nil }
    }

    // MARK: - Packs

    func savePack(_ draft: GatewayPackDraft) async -> Bool {
        let problems = GatewayPackValidation.errors(pack: draft, hasCostLimitedKeys: hasCostLimitedKeys(packID: draft.id))
        return await run { client in
            guard problems.isEmpty else { throw ModelPacksError.invalid(problems) }
            try await client.savePacks(.upsertPack(draft))
        }
    }

    func deletePack(id: String) async -> Bool {
        await run { client in try await client.savePacks(.deletePack(id: id)) }
    }

    // MARK: - Keys

    /// Creates the keys; on success their plaintext is in `revealedKeys` (shown once).
    func createKeys(_ batch: GatewayPackKeyBatch) async -> Bool {
        let problems = pack(id: batch.packID).map { GatewayPackValidation.errors(batch: batch, pack: $0, now: clock()) }
            ?? [OasesLocalization.localized("这个模型包或 Key 已不存在（可能已被其他客户端删除），请刷新后再试。")]
        return await run { [weak self] client in
            guard problems.isEmpty else { throw ModelPacksError.invalid(problems) }
            let created = try await client.createPackKeys(batch)
            self?.revealedKeys = created
        }
    }

    /// Forgets the plaintext of the keys just created (the one-time sheet was closed).
    func dismissRevealedKeys() {
        revealedKeys = []
    }

    func updateKey(_ patch: GatewayPackKeyPatch) async -> Bool {
        var problems: [String] = []
        if case .set(let reset) = patch.reset { problems += GatewayPackValidation.errors(reset: reset, now: clock()) }
        if case .set(let tokens) = patch.totalTokens, tokens <= 0 {
            problems.append(OasesLocalization.localized("总 Token 上限必须是正整数，或留空表示不限。"))
        }
        if case .set(let cost) = patch.totalCostUSD {
            if cost <= 0 {
                problems.append(OasesLocalization.localized("总花费上限必须大于 0，或留空表示不限。"))
            } else if let pack = packs.first(where: { keysByPack[$0.id]?.contains { $0.id == patch.keyID } == true }), !pack.isPriced {
                problems.append(GatewayPackValidation.pricingRequiredMessage)
            }
        }
        if case .set(let label) = patch.label, label.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count > GatewayKeyPolicy.maximumLabelLength {
            problems.append(OasesLocalization.localizedFormat("名称最多 %lld 个字符。", GatewayKeyPolicy.maximumLabelLength))
        }
        guard !patch.isEmpty else { return true }
        return await run { client in
            guard problems.isEmpty else { throw ModelPacksError.invalid(problems) }
            try await client.savePacks(.updateKey(patch))
        }
    }

    /// Restores the key's quota now (its current usage moves into the lifetime totals).
    func resetUsage(keyID: String) async -> Bool {
        await run { client in try await client.savePacks(.resetUsage(keyID: keyID)) }
    }

    func deleteKey(keyID: String) async -> Bool {
        await run { client in try await client.savePacks(.deleteKey(keyID: keyID)) }
    }

    func unbindKey(keyID: String) async -> Bool {
        await run { client in try await client.savePacks(.unbindKey(keyID: keyID)) }
    }

    /// One change through the base `mutate` (401 latches, success reads the page again), with the
    /// pack service's error codes turned into readable text.
    private func run(_ operation: @escaping @MainActor (GatewayAdminClient) async throws -> Void) async -> Bool {
        await mutate { client in
            do {
                try await operation(client)
            } catch {
                throw ModelPacksError.map(error)
            }
        }
    }
}
