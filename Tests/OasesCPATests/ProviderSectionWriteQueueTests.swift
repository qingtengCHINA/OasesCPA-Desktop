import Foundation
import XCTest
@testable import OasesCPA

/// The app's provider writes (the engine has no compare-and-set): one section's writes run one
/// after another, and a provider edit whose second write fails says what was already stored.
@MainActor
final class ProviderSectionWriteQueueTests: XCTestCase {
    /// Holds an operation until the test opens it.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isOpen = false

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private final class Log {
        private(set) var lines: [String] = []
        func append(_ line: String) { lines.append(line) }
    }

    private struct Failure: Error {}

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testWritesOfOneSectionRunOneAfterAnother() async throws {
        let queue = ProviderSectionWriteQueue()
        let gate = Gate()
        let log = Log()

        let first = Task { @MainActor in
            try await queue.run(section: "openai-compatibility") { () async throws -> Void in
                log.append("first start")
                await gate.wait()
                log.append("first end")
                throw Failure()
            }
        }
        await settle()
        let second = Task { @MainActor in
            try await queue.run(section: "openai-compatibility") {
                log.append("second")
                return 2
            }
        }
        let otherSection = Task { @MainActor in
            try await queue.run(section: "gemini-api-key") {
                log.append("other section")
                return 3
            }
        }
        await settle()
        XCTAssertEqual(log.lines, ["first start", "other section"], "the second write waits; another section does not")
        XCTAssertEqual(queue.pendingSections, ["openai-compatibility"])

        gate.open()
        do {
            try await first.value
            XCTFail("the first write fails")
        } catch is Failure {}
        let secondValue = try await second.value
        let otherValue = try await otherSection.value
        XCTAssertEqual(secondValue, 2, "a failed write does not block the next one")
        XCTAssertEqual(otherValue, 3)
        XCTAssertEqual(log.lines, ["first start", "other section", "first end", "second"])
        await settle()
        XCTAssertEqual(queue.pendingSections, [], "nothing is left queued")
    }

    /// A provider edit is a PATCH and then a whole-list priority write. When the second fails,
    /// the message says the other settings were saved (and the list is read again) instead of
    /// a bare error that suggests nothing was stored.
    func testFailedPriorityWriteSaysTheOtherSettingsWereSaved() async throws {
        URLProtocolStub.install { request, _ in
            switch (request.httpMethod ?? "", request.url?.path ?? "") {
            case ("PATCH", "/v0/management/openai-compatibility"):
                return .json(200, #"{"status":"ok"}"#, for: request)
            case ("GET", "/v0/management/config"):
                return .json(200, #"{"openai-compatibility":[{"name":"provider-a","base-url":"http://127.0.0.1:1/v1","priority":1}]}"#, for: request)
            case ("PUT", "/v0/management/openai-compatibility"):
                return .json(500, #"{"error":"write failed"}"#, for: request)
            case ("GET", "/v0/management/openai-compatibility"):
                return .json(200, #"{"openai-compatibility":[{"name":"provider-a","base-url":"http://127.0.0.1:1/v1","priority":1}]}"#, for: request)
            default:
                return .json(404, #"{"error":"unexpected"}"#, for: request)
            }
        }
        let deploymentStore = DeploymentStore(autoProbe: false)
        deploymentStore.attachForTesting(topology: .gateway, managementKey: "cpa-management-test-key", adminKey: "cpamp-test-key")
        let store = RuntimeDataStore()
        store.makeManagementClient = { ManagementAPIClient(session: URLProtocolStub.makeSession()) }

        store.patchOpenAICompatibility(
            name: "provider-a",
            index: 0,
            value: RuntimeOpenAICompatibilityPatch(name: "provider-a", priority: 5, disabled: false),
            using: deploymentStore
        )
        for _ in 0..<300 where store.isSavingProviders || store.providerErrorMessage == nil || store.isLoadingProviders {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let message = try XCTUnwrap(store.providerErrorMessage)
        let reason = ManagementAPIError.server(status: 500, message: #"{"error":"write failed"}"#).localizedDescription
        XCTAssertEqual(message, RuntimeDataStoreError.providerPriorityNotSaved(otherChangesSaved: true, reason: reason).localizedDescription)
        XCTAssertTrue(message.contains(reason), message)
        XCTAssertNotEqual(
            OasesLocalization.localizedFormat("该服务的其他设置已保存，但优先级没有保存：%@ 列表已刷新，请重新设置优先级。", language: .english, "x"),
            OasesLocalization.localizedFormat("该服务的其他设置已保存，但优先级没有保存：%@ 列表已刷新，请重新设置优先级。", language: .simplifiedChinese, "x"),
            "the message has an English translation"
        )
        let methods = URLProtocolStub.recordedRequests.map { "\($0.0.httpMethod ?? "") \($0.0.url?.path ?? "")" }
        XCTAssertEqual(methods, [
            "PATCH /v0/management/openai-compatibility",
            "GET /v0/management/config",
            "PUT /v0/management/openai-compatibility",
            "GET /v0/management/openai-compatibility"
        ], "the list is read again after the partial save")
        XCTAssertTrue(store.hasLoadedOpenAICompatibility)

        // A PATCH that carried only the priority stored nothing else.
        XCTAssertFalse(RuntimeOpenAICompatibilityPatch(priority: 5).changesOtherThanPriority)
        XCTAssertTrue(RuntimeOpenAICompatibilityPatch(name: "provider-a", priority: 5).changesOtherThanPriority)
        XCTAssertNotEqual(
            RuntimeDataStoreError.providerPriorityNotSaved(otherChangesSaved: false, reason: "r").localizedDescription,
            RuntimeDataStoreError.providerPriorityNotSaved(otherChangesSaved: true, reason: "r").localizedDescription
        )
    }
}
