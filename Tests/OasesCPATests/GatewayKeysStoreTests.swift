import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import OasesCPA

@MainActor
final class GatewayKeysStoreTests: XCTestCase {
    private static let fingerprint = SHA256.hash(data: Data("pack-engine-test-key".utf8)).map { String(format: "%02x", $0) }.joined()

    override func tearDown() async throws {
        URLProtocolStub.reset()
        // XCTestCase.tearDown() does nothing; its async form would send `self` across isolation,
        // which the Swift 6.1 toolchain of Xcode 16 rejects.
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
        // The user is told what happened, in both languages (the English text is a real translation).
        let source = "这把 Key 的策略已被其他客户端修改，本次修改没有保存。请关闭编辑器、刷新后重新编辑。"
        XCTAssertEqual(store.actionError, OasesLocalization.localized(source))
        XCTAssertEqual(store.actionError, GatewayKeysStoreError.changedElsewhere.errorDescription)
        XCTAssertNotEqual(OasesLocalization.localized(source, language: .english), source)
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

    // MARK: - Batch-5 review follow-ups (batch 7a, step 0)

    /// The add can outlast the request and still succeed: after a timeout the key list is read
    /// again and, when the generated key is there, it is returned for the one-time display.
    func testAddKeyTimeoutReturnsTheKeyWhenTheGatewayListsIt() async throws {
        let store = try await loadedStore()
        final class Added: @unchecked Sendable {
            private let lock = NSLock()
            private var key: String?
            func set(_ value: String?) { lock.lock(); key = value; lock.unlock() }
            func get() -> String? { lock.lock(); defer { lock.unlock() }; return key }
        }
        let added = Added()
        URLProtocolStub.install { request, body in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/cpa-admin/permissions/api/data"):
                guard let key = added.get() else { return .json(200, gatewayPermissionsFixture, for: request) }
                return .json(200, gatewayPermissionsFixture.replacingOccurrences(of: #""keys": ["#, with: #""keys": ["\#(key)", "#), for: request)
            case ("POST", "/cpa-admin/permissions/api/save"):
                // The gateway adds the key but the answer never arrives in time.
                let object = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
                added.set(object?["key"] as? String)
                return .failure(.timedOut, for: request)
            default: return .json(404, #"{"error":"Not found"}"#, for: request)
            }
        }
        let key = await store.addKey(policy: GatewayKeyPolicy(label: "New"))
        XCTAssertNotNil(key, "the listed key is returned")
        // Compared without printing either value (test output never shows key material).
        XCTAssertTrue(key == added.get(), "it is the generated key")
        XCTAssertNil(store.actionError)

        // A timeout after which the key is NOT listed stays a failure.
        added.set(nil)
        URLProtocolStub.install { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/cpa-admin/permissions/api/data"): return .json(200, gatewayPermissionsFixture, for: request)
            default: return .failure(.timedOut, for: request)
            }
        }
        let missing = await store.addKey(policy: GatewayKeyPolicy(label: "New"))
        XCTAssertNil(missing)
        XCTAssertNotNil(store.actionError)
        // A refusal (4xx) is never re-read.
        installGateway(save: { (400, #"{"error":"bad"}"#) })
        let refused = await store.addKey(policy: GatewayKeyPolicy(label: "New"))
        XCTAssertNil(refused)
        XCTAssertEqual(URLProtocolStub.recordedRequests.filter { $0.0.httpMethod == "GET" }.count, 0, "no re-read after a 4xx")
        store.deactivate()
    }

    /// Labels and notes are counted and cleaned like the gateway does (UTF-16 units, control
    /// characters removed; `<`/`>` removed from labels).
    func testLabelsAndNotesFollowTheGatewaysNormalization() {
        XCTAssertEqual(GatewayKeyPolicy.normalizedNotes("line one\nline two\t\u{0007}!"), "line oneline two!")
        XCTAssertEqual(GatewayKeyPolicy.normalizedLabel("  <Team> A\n "), "Team A")
        let emoji = String(repeating: "😀", count: 60)
        XCTAssertEqual(GatewayKeyPolicy.normalizedLabel(emoji).utf16.count, 100, "cut at 100 UTF-16 units")
        XCTAssertEqual(GatewayKeyPolicy.normalizedLabel(emoji), String(repeating: "😀", count: 50), "never half a character")
        var draft = GatewayKeyPolicyDraft(baseline: .projectedDefault)
        draft.policy.label = String(repeating: "😀", count: 51)
        XCTAssertEqual(draft.validationErrors().count, 1, "51 emoji are 102 UTF-16 units")
        draft.policy.label = String(repeating: "😀", count: 50)
        draft.policy.notes = String(repeating: "\n", count: 2_000) + "ok"
        XCTAssertEqual(draft.validationErrors(), [], "removed characters do not count")
    }

    // MARK: - One-time key sheet and copying

    func testNewKeySnippetHasTheEndpointAndTheKey() {
        XCTAssertEqual(
            GatewayNewKeySheet.snippet(baseURL: "http://127.0.0.1:8317/v1", key: "demo-key-1234"),
            "OPENAI_BASE_URL=http://127.0.0.1:8317/v1\nOPENAI_API_KEY=demo-key-1234"
        )
    }

    func testSecretCopyIsMarkedConcealedAndPlainCopyIsNot() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        OasesPasteboard.copySecret("demo-secret", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "demo-secret")
        XCTAssertTrue(pasteboard.types?.contains(OasesPasteboard.concealedType) ?? false)

        OasesPasteboard.copy("http://127.0.0.1:8317/v1", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "http://127.0.0.1:8317/v1")
        XCTAssertFalse(pasteboard.types?.contains(OasesPasteboard.concealedType) ?? true, "a plain copy replaces the marker")
    }

    func testKeyTableTextsUseTheMaskAndCompactNumbers() {
        var policy = GatewayKeyPolicy.newKeyDefault
        policy.rateLimit.tokensPerDay = 2_000_000
        policy.rateLimit.requestsPerMinute = 60
        let row = GatewayKeyRow(
            key: "demo-0000000000000000abcd",
            policy: policy,
            usage: GatewayKeyUsage(day: "d", requests: 1, requestsLastMinute: 3, tokens: 12_345, tokensPerDay: 2_000_000, requestsPerMinute: 60)
        )
        XCTAssertEqual(row.maskedKey, "demo••••abcd")
        let usage = GatewayKeysTable.usageText(row)
        XCTAssertTrue(usage.contains("12.3K"), usage)
        XCTAssertTrue(usage.contains("2.0M"), usage)
        XCTAssertTrue(usage.contains("3 / 60"), usage)
        XCTAssertFalse(usage.contains("abcd"), "no key material in the usage text")
    }

    func testFirstProviderNameComesFromTheEndpointHost() {
        XCTAssertEqual(FirstProviderForm.providerName(forBaseURL: "https://api.deepseek.com/v1"), "deepseek")
        XCTAssertEqual(FirstProviderForm.providerName(forBaseURL: " https://openrouter.ai/api "), "openrouter")
        XCTAssertEqual(FirstProviderForm.providerName(forBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"), "dashscope")
        XCTAssertEqual(FirstProviderForm.providerName(forBaseURL: "http://127.0.0.1:11434/v1"), "127.0.0.1")
        XCTAssertEqual(FirstProviderForm.providerName(forBaseURL: "http://localhost:8080"), "localhost")
        XCTAssertEqual(FirstProviderForm.providerName(forBaseURL: "not a url"), "not a url")
    }
}
