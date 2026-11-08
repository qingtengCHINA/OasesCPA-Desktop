import Foundation
import XCTest
@testable import OasesCPA

@MainActor
final class ModelPacksStoreTests: XCTestCase {
    override func tearDown() async throws {
        URLProtocolStub.reset()
        // XCTestCase.tearDown() does nothing; its async form would send `self` across isolation,
        // which the Swift 6.1 toolchain of Xcode 16 rejects.
    }

    private func dataBody(engineKeyReady: Bool = true) -> String {
        """
        {"store_available":true,"persistence_failing":false,"engine_key_ready":\(engineKeyReady),
         "packs":[\(gatewayPackJSON)],"models":["deepseek-chat","glm-5","pin-a/glm-5"]}
        """
    }

    /// Answers by path; `save` answers `POST /cpa-admin/packs/save`.
    private func install(engineKeyReady: Bool = true, save: @escaping @Sendable (Data?) -> (Int, String) = { _ in (200, #"{"ok":true}"#) }) {
        let data = dataBody(engineKeyReady: engineKeyReady)
        URLProtocolStub.install { request, body in
            switch request.url?.path {
            case "/cpa-admin/packs/data": return .json(200, data, for: request)
            case "/cpa-admin/packs/keys": return .json(200, #"{"keys":[\#(gatewayPackKeyJSON)]}"#, for: request)
            case "/cpa-admin/packs/save":
                let (status, text) = save(body)
                return .json(status, text, for: request)
            default: return .json(404, #"{"error":"Not found"}"#, for: request)
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func loadedStore(engineKeyReady: Bool = true) async throws -> ModelPacksStore {
        install(engineKeyReady: engineKeyReady)
        let store = ModelPacksStore(provider: FakeGatewayClientProvider())
        store.activate()
        try await waitUntil { store.phase == .loaded }
        XCTAssertEqual(store.phase, .loaded)
        return store
    }

    func testLoadsPacksKeysAndModelsWithoutInternalIDs() async throws {
        let store = try await loadedStore()
        XCTAssertEqual(store.packs.map(\.id), ["pk_0123456789abcdef"])
        XCTAssertEqual(store.keysByPack["pk_0123456789abcdef"]?.map(\.id), ["pkk_0123456789abcdef"])
        XCTAssertEqual(store.models, ["deepseek-chat", "glm-5"])
        let keysRequest = try XCTUnwrap(URLProtocolStub.recordedRequests.first { $0.0.url?.path == "/cpa-admin/packs/keys" })
        XCTAssertEqual(keysRequest.0.url?.query, "pack_id=pk_0123456789abcdef")
        XCTAssertEqual(keysRequest.0.value(forHTTPHeaderField: "x-management-key"), "fake-key")
        store.deactivate()
    }

    func testCreatedKeysAreClearedOnDismiss() async throws {
        let store = try await loadedStore()
        // Built at run time; never a real key.
        let plain = "sk-pk-" + String(repeating: "Q", count: 43)
        install(save: { _ in (200, #"{"keys":[{"id":"pkk_new","key":"\#(plain)","tail":"QQQQ","label":"team-1"}]}"#) })
        var batch = GatewayPackKeyBatch(packID: "pk_0123456789abcdef", count: 1, labelPrefix: "team-1")
        batch.totalTokens = 1000
        let created = await store.createKeys(batch)
        XCTAssertTrue(created)
        XCTAssertEqual(store.revealedKeys.map(\.key), [plain])
        XCTAssertNil(store.actionError)
        let post = try XCTUnwrap(URLProtocolStub.recordedRequests.first { $0.0.httpMethod == "POST" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(post.1)) as? [String: Any])
        XCTAssertEqual(body["action"] as? String, "create_keys")
        XCTAssertEqual(body["total_tokens"] as? Int, 1000)
        store.dismissRevealedKeys()
        XCTAssertTrue(store.revealedKeys.isEmpty)

        // Leaving the page with the sheet still up forgets them as well.
        _ = await store.createKeys(batch)
        XCTAssertFalse(store.revealedKeys.isEmpty)
        store.deactivate()
        XCTAssertTrue(store.revealedKeys.isEmpty)
    }

    func testEngineKeyNotReadyShowsBanner() async throws {
        let store = try await loadedStore(engineKeyReady: false)
        XCTAssertFalse(store.engineKeyReady)
        store.deactivate()
        let ready = try await loadedStore()
        XCTAssertTrue(ready.engineKeyReady)
        ready.deactivate()
    }

    func testErrorCodesMapToMessages() async throws {
        let store = try await loadedStore()
        let cases: [(Int, String, String)] = [
            (400, "pricing_required", GatewayPackValidation.pricingRequiredMessage),
            (404, "not_found", OasesLocalization.localized("这个模型包或 Key 已不存在（可能已被其他客户端删除），请刷新后再试。")),
            (409, "conflict", OasesLocalization.localized("与网关当前的数据冲突，本次修改没有保存；请刷新后再试。")),
            (503, "unavailable", OasesLocalization.localized("网关的模型包数据暂时不可用（无法读取或写入），模型包 Key 也已暂停服务；请检查网关数据目录后重试。")),
        ]
        for (status, code, message) in cases {
            install(save: { _ in (status, #"{"error":"raw server text","code":"\#(code)"}"#) })
            let succeeded = await store.resetUsage(keyID: "pkk_0123456789abcdef")
            XCTAssertFalse(succeeded, code)
            XCTAssertEqual(store.actionError, message, code)
            XCTAssertFalse(store.actionError?.contains("raw server text") ?? true, code)
        }
        // English texts exist for all four.
        for source in ["这个模型包或 Key 已不存在（可能已被其他客户端删除），请刷新后再试。", "与网关当前的数据冲突，本次修改没有保存；请刷新后再试。",
                       "网关的模型包数据暂时不可用（无法读取或写入），模型包 Key 也已暂停服务；请检查网关数据目录后重试。", "设置总花费上限前，每个成员模型都需要输入和输出价格。"] {
            XCTAssertNotEqual(OasesLocalization.localized(source, language: .english), source, source)
        }
        store.deactivate()
    }

    func testInvalidChangesAreRefusedLocallyWithoutARequest() async throws {
        let store = try await loadedStore()
        install()
        // The pack has an unpriced member: no cost limit.
        let refused = await store.createKeys(GatewayPackKeyBatch(packID: "pk_0123456789abcdef", totalCostUSD: 5))
        XCTAssertFalse(refused)
        XCTAssertEqual(store.actionError, GatewayPackValidation.pricingRequiredMessage)
        XCTAssertTrue(store.revealedKeys.isEmpty)
        XCTAssertFalse(URLProtocolStub.recordedRequests.contains { $0.0.httpMethod == "POST" }, "nothing was sent")
        store.deactivate()
    }

    func testUnauthorizedSaveLatchesWithoutRetry() async throws {
        let provider = FakeGatewayClientProvider()
        install()
        let store = ModelPacksStore(provider: provider)
        store.activate()
        try await waitUntil { store.phase == .loaded }
        install(save: { _ in (401, #"{"error":"Unauthorized management key"}"#) })
        let succeeded = await store.deleteKey(keyID: "pkk_0123456789abcdef")
        XCTAssertFalse(succeeded)
        XCTAssertEqual(provider.rejectedKeys, ["fake-key"])
        XCTAssertEqual(store.phase, .unavailable(.credentialsRejected))
        XCTAssertEqual(URLProtocolStub.recordedRequests.filter { $0.0.httpMethod == "POST" }.count, 1, "no retry")
        store.deactivate()
    }

    /// The pack service's 429 `rate_limited` (`packs.mjs` `HTTP_STATUS`) is shown as text, and an
    /// update is checked by `GatewayPackValidation.errors(patch:pack:now:)` before it is sent.
    func testRateLimitedAndPatchValidationAreReadable() async throws {
        let store = try await loadedStore()
        install(save: { _ in (429, #"{"error":"raw server text","code":"rate_limited"}"#) })
        let succeeded = await store.resetUsage(keyID: "pkk_0123456789abcdef")
        XCTAssertFalse(succeeded)
        XCTAssertEqual(store.actionError, OasesLocalization.localized("操作过于频繁，网关暂时拒绝了这次修改；请稍后再试。"))
        XCTAssertNotEqual(OasesLocalization.localized("操作过于频繁，网关暂时拒绝了这次修改；请稍后再试。", language: .english),
                          "操作过于频繁，网关暂时拒绝了这次修改；请稍后再试。")

        install()
        var patch = GatewayPackKeyPatch(keyID: "pkk_0123456789abcdef")
        patch.totalCostUSD = .set(5)
        let refused = await store.updateKey(patch)
        XCTAssertFalse(refused, "the key's pack has an unpriced member")
        XCTAssertEqual(store.actionError, GatewayPackValidation.pricingRequiredMessage)
        XCTAssertFalse(URLProtocolStub.recordedRequests.contains { $0.0.httpMethod == "POST" }, "nothing was sent")
        store.deactivate()
    }

    /// After a 401 the editor still has something to show (the latch leaves `actionError` empty).
    func testFailedMutationAlwaysHasAMessage() async throws {
        let store = try await loadedStore()
        install(save: { _ in (401, #"{"error":"Unauthorized management key"}"#) })
        let succeeded = await store.deleteKey(keyID: "pkk_0123456789abcdef")
        XCTAssertFalse(succeeded)
        XCTAssertNil(store.actionError)
        XCTAssertEqual(store.mutationFailureMessage, GatewayAdminError.unauthorized.errorDescription)
        store.deactivate()
    }
}
