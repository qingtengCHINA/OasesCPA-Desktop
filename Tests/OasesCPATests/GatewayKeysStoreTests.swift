import CryptoKit
import Foundation
import XCTest
@testable import OasesCPA

@MainActor
final class GatewayKeysStoreTests: XCTestCase {
    private static let fingerprint = SHA256.hash(data: Data("pack-engine-test-key".utf8)).map { String(format: "%02x", $0) }.joined()

    override func tearDown() async throws {
        URLProtocolStub.reset()
        try await super.tearDown()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// `data` answers every `GET …/api/data`; `save` every `POST …/api/save`.
    private func installGateway(data: @escaping @Sendable () -> String = { gatewayPermissionsFixture },
                                save: @escaping @Sendable () -> (Int, String) = { (200, #"{"success":true}"#) }) {
        URLProtocolStub.install { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/cpa-admin/permissions/api/data"): return .json(200, data(), for: request)
            case ("POST", "/cpa-admin/permissions/api/save"):
                let (status, body) = save()
                return .json(status, body, for: request)
            default: return .json(404, #"{"error":"Not found"}"#, for: request)
            }
        }
    }

    private func loadedStore(fingerprint: String? = GatewayKeysStoreTests.fingerprint) async throws -> GatewayKeysStore {
        installGateway()
        let store = GatewayKeysStore(provider: FakeGatewayClientProvider(), packEngineKeyFingerprint: { fingerprint })
        store.activate()
        try await waitUntil { store.phase == .loaded }
        XCTAssertEqual(store.phase, .loaded)
        return store
    }

    private func posts() -> [[String: Any]] {
        URLProtocolStub.recordedRequests
            .filter { $0.0.httpMethod == "POST" }
            .compactMap { $0.1.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }

    func testPackEngineKeyIsHiddenAndUndeletable() async throws {
        let store = try await loadedStore()
        XCTAssertEqual(store.rows.map(\.key), ["sk-cpa-test-key-one"])
        URLProtocolStub.install { request, _ in .json(200, #"{"success":true}"#, for: request) }
        let deleted = await store.deleteKey("pack-engine-test-key")
        XCTAssertFalse(deleted)
        let relabelled = await store.setLabel(key: "pack-engine-test-key", label: "x")
        XCTAssertFalse(relabelled)
        let saved = await store.savePolicy(key: "pack-engine-test-key", draft: GatewayKeyPolicyDraft(baseline: .projectedDefault))
        XCTAssertFalse(saved)
        XCTAssertTrue(URLProtocolStub.recordedRequests.isEmpty, "nothing is sent for the internal key")
        store.deactivate()
    }

    func testRowsMaskKeysAndCarryUsage() async throws {
        let store = try await loadedStore()
        let row = try XCTUnwrap(store.rows.first)
        XCTAssertEqual(row.maskedKey, "sk-c••••-one")
        XCTAssertEqual(row.label, "Team A")
        XCTAssertEqual(row.usage?.tokens, 1200)
        XCTAssertTrue(row.policy.isExpired(now: GatewayDates.date(from: "2026-12-02T00:00:00.000Z")!))
        XCTAssertFalse(row.policy.isExpired(now: GatewayDates.date(from: "2026-11-08T00:00:00.000Z")!))
        store.deactivate()
    }

    func testEmptyKeyListIsANormalLoadedState() async throws {
        installGateway(data: { #"{"keys":[],"permissions":{},"groupedModels":{},"disabledProviders":[],"schema_version":2,"usage":{}}"# })
        let store = GatewayKeysStore(provider: FakeGatewayClientProvider(), packEngineKeyFingerprint: { nil })
        store.activate()
        try await waitUntil { store.phase == .loaded }
        XCTAssertEqual(store.phase, .loaded, "the gateway may hide its only key: an empty list is not an error")
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertNil(store.actionError)
        store.deactivate()
    }

    func testGroupedModelsDropInternalIDs() async throws {
        let store = try await loadedStore()
        XCTAssertEqual(store.groupedModels["compat-a"], ["glm-5"])
        XCTAssertEqual(store.groupedModels["认证文件 / 引擎模型"], ["gpt-5.5"])
        for ids in store.groupedModels.values {
            for id in ids { XCTAssertFalse(InternalModelID.isInternal(id), id) }
        }
        store.deactivate()
    }

    func testSavePolicyRereadsAndRefusesWhenServerChanged() async throws {
        let store = try await loadedStore()
        let row = try XCTUnwrap(store.rows.first)
        var draft = GatewayKeyPolicyDraft(baseline: row.policy)
        draft.policy.label = "Team B"
        // Meanwhile another client renamed the key.
        installGateway(data: { gatewayPermissionsFixture.replacingOccurrences(of: #""label": "Team A""#, with: #""label": "Other client""#) })
        let saved = await store.savePolicy(key: row.key, draft: draft)
        XCTAssertFalse(saved)
        XCTAssertTrue(posts().isEmpty, "no POST when the server changed")
        XCTAssertEqual(URLProtocolStub.recordedRequests.map { $0.0.httpMethod }, ["GET"], "the save re-read the data first")
        XCTAssertTrue(OasesLocalization.localized("这把 Key 的策略已被其他客户端修改，本次修改没有保存。请关闭编辑器、刷新后重新编辑。", language: .simplifiedChinese).contains("已被其他客户端修改"))
        XCTAssertEqual(store.actionError, GatewayKeysStoreError.changedElsewhere.errorDescription)
        store.deactivate()
    }

    func testSavePolicyPostsLatestUnknownFieldsMergedWithDraft() async throws {
        let store = try await loadedStore()
        let row = try XCTUnwrap(store.rows.first)
        var draft = GatewayKeyPolicyDraft(baseline: row.policy)
        draft.policy.label = "Team B"
        draft.policy.rateLimit.tokensPerDay = 9000
        // SYNTHETIC: the server's object gained a field this app does not know; known fields are unchanged.
        installGateway(data: { gatewayPermissionsFixture.replacingOccurrences(of: #""future_flag": true,"#, with: #""future_flag": true, "another": 1,"#) })
        let saved = await store.savePolicy(key: row.key, draft: draft)
        XCTAssertTrue(saved)
        let body = try XCTUnwrap(posts().first)
        XCTAssertEqual(body["action"] as? String, "save_policy")
        XCTAssertEqual(body["key"] as? String, "sk-cpa-test-key-one")
        let policy = try XCTUnwrap(body["policy"] as? [String: Any])
        XCTAssertEqual(policy["another"] as? Int, 1)
        XCTAssertEqual(policy["future_flag"] as? Bool, true)
        XCTAssertEqual(policy["label"] as? String, "Team B")
        XCTAssertEqual((policy["rate_limit"] as? [String: Any])?["tokens_per_day"] as? Int, 9000)
        XCTAssertEqual((policy["model_provider_pins"] as? [String: [String: String]])?["glm-5"], ["provider": "compat-a", "mode": "only"])
        XCTAssertNil(policy["usage"])
        XCTAssertEqual(
            URLProtocolStub.recordedRequests.map { "\($0.0.httpMethod ?? "") \($0.0.url?.path ?? "")" },
            ["GET /cpa-admin/permissions/api/data", "POST /cpa-admin/permissions/api/save", "GET /cpa-admin/permissions/api/data"],
            "re-read, save, then reload"
        )
        store.deactivate()
    }

    func testSavePolicyNeverDropsPinsWithoutConfirmation() async throws {
        let store = try await loadedStore()
        let row = try XCTUnwrap(store.rows.first)
        var draft = GatewayKeyPolicyDraft(baseline: row.policy)
        draft.policy.allowedModels = ["gpt-5.5"]
        URLProtocolStub.install { request, _ in .json(200, gatewayPermissionsFixture, for: request) }
        let saved = await store.savePolicy(key: row.key, draft: draft)
        XCTAssertFalse(saved)
        XCTAssertTrue(posts().isEmpty)
        XCTAssertEqual(store.actionError, GatewayKeysStoreError.pinsNotConfirmed(["glm-5"]).errorDescription)

        installGateway()
        draft.dropUnreachablePins()
        let confirmed = await store.savePolicy(key: row.key, draft: draft)
        XCTAssertTrue(confirmed)
        let policy = try XCTUnwrap(posts().first?["policy"] as? [String: Any])
        XCTAssertEqual((policy["model_provider_pins"] as? [String: Any])?.count, 0)
        store.deactivate()
    }

    func testLastKeyConflictShowsReadableMessage() async throws {
        let store = try await loadedStore()
        installGateway(save: { (409, #"{"error":"At least one API key must remain configured","code":"last_api_key"}"#) })
        let deleted = await store.deleteKey("sk-cpa-test-key-one")
        XCTAssertFalse(deleted)
        XCTAssertEqual(store.actionError, OasesLocalization.localized("至少要保留一把 API Key（网关内部使用的引擎 Key 也算在内），这把 Key 不能删除。"))
        XCTAssertEqual(posts().first as? [String: String], ["action": "delete_key", "key": "sk-cpa-test-key-one"])
        XCTAssertEqual(store.phase, .loaded)
        store.deactivate()
    }

    func testAddKeyReturnsTheGeneratedKeyOnce() async throws {
        let store = try await loadedStore()
        installGateway()
        let added = await store.addKey(policy: .newKeyDefault)
        let key = try XCTUnwrap(added)
        let body = try XCTUnwrap(posts().first)
        XCTAssertEqual(body["action"] as? String, "add_key")
        XCTAssertEqual(body["key"] as? String, key)
        XCTAssertNotNil(body["policy"] as? [String: Any])

        installGateway(save: { (400, #"{"error":"Key already exists"}"#) })
        let refused = await store.addKey(policy: .newKeyDefault)
        XCTAssertNil(refused)
        XCTAssertNotNil(store.actionError)
        XCTAssertFalse(store.actionError?.contains("sk-cpa-") ?? true, "the key never appears in a message")
        store.deactivate()
    }

    func testSetLabelSendsOnlyTheLabel() async throws {
        let store = try await loadedStore()
        installGateway()
        let saved = await store.setLabel(key: "sk-cpa-test-key-one", label: "  Laptop  ")
        XCTAssertTrue(saved)
        XCTAssertEqual(posts().first as? [String: String], ["action": "set_label", "key": "sk-cpa-test-key-one", "label": "Laptop"])
        store.deactivate()
    }
}
