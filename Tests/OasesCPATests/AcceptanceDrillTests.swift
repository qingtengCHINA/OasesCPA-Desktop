import Foundation
import XCTest
@testable import OasesCPA

/// Opt-in scripted acceptance drill (plan Task 23a): the app's real install, upgrade, rollback,
/// stop and removal scripts (`…ForVerification`) and the app's real API clients against the
/// real pinned packages, on the FIXED loopback ports 8317/18320/18316/18317, in a scratch install
/// root with a scratch HOME. The app itself is never launched.
///
/// Runs only when all of these are set (otherwise skipped):
/// - `OASES_E2E_ACCEPTANCE=1`;
/// - `OASES_E2E_REAL_ARTIFACTS`: a directory with the pinned engine, CPA Manager Plus and Node
///   packages for this Mac under their release file names (served by a curl shim; nothing is
///   downloaded, every other HTTPS request is refused);
/// - `OASES_E2E_GATEWAY_TARBALL` / `_SHA256` / `_VERSION`: the "next" gateway package from
///   `script/e2e/make_gateway_next.sh`, read through the app's own DEBUG override
///   (`GatewayBundle.resolve`).
///
/// Before anything starts, `lsof` must show 8317, 18316, 18317, 18320, 19101 and 19102 free;
/// otherwise the drill fails without starting anything (it never stops what holds a port).
/// Everything it starts is stopped at the end (the app's stop script, then SIGTERM/SIGKILL of
/// anything left), the scratch root is removed with the app's removal script (allowed only for
/// a root the drill created under the scratch directory), and the ports are checked free again.
/// A masked summary (`<install>`, `<scratch>`, no key) is written to `drill-summary.md` in the
/// case directory for `docs/acceptance/`.
final class AcceptanceDrillTests: XCTestCase {
    private static let fixedPorts = [8317, 18316, 18317, 18320, 19101, 19102]
    private static let chatModel = "glm-5"
    private static let packModel = "e2e-pack"

    func testScriptedDeployUpgradeRollbackDrill() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OASES_E2E_ACCEPTANCE"] == "1" else {
            throw XCTSkip("set OASES_E2E_ACCEPTANCE=1 (and the artifact and gateway variables) to run the drill")
        }
        guard let artifacts = environment["OASES_E2E_REAL_ARTIFACTS"], !artifacts.isEmpty else {
            throw XCTSkip("set OASES_E2E_REAL_ARTIFACTS to a directory with the pinned packages")
        }
        let next = GatewayBundle.resolve(environment: environment)
        guard next != .bundled else {
            throw XCTSkip("set OASES_E2E_GATEWAY_TARBALL, _SHA256 and _VERSION (script/e2e/make_gateway_next.sh)")
        }
        let busy = Self.fixedPorts.filter { !Drill.listeners(port: $0).isEmpty }
        guard busy.isEmpty else {
            XCTFail("fixed ports in use: \(busy); nothing was started (the owner's deployment may be running)")
            return
        }

        let drill = try Drill(artifacts: artifacts)
        let root = drill.root.path
        let pins = try DeploymentPinSet.current.deployable()
        let nextPins = pins.with(gateway: next)
        let maintenance = DeploymentMaintenanceService()
        var keys: [String] = []
        var upstreams: [String: Process] = [:]
        defer {
            drill.write(summaryWithSecrets: keys)
        }
        var cleanedUp = false
        func cleanUp() {
            guard !cleanedUp else { return }
            cleanedUp = true
            for process in upstreams.values { drill.stop(process) }
            drill.stopAll()
        }
        defer { cleanUp() }

        // 1. Fresh install on the fixed ports.
        drill.note("## 1. Install (fixed ports)")
        let install = try drill.run(DeploymentExecutor().scriptForVerification(method: .native, installDirectory: root, pins: pins), name: "install")
        drill.note("- install script: exit \(install.status), \(install.seconds) s")
        XCTAssertEqual(install.status, 0, install.stderr)
        guard install.status == 0 else { return }
        let result = try DeploymentExecutor().parseResult(install.stdout)
        let managementKey = result.cpaManagementKey
        let cpampKey = result.cpampAdminKey
        keys += try ["cpa-management-key", "cpamp-admin-key", "pack-engine-key", "pack-store-key"].map(drill.secret)
        drill.note("- `.oases-cpa-versions`: `\(drill.versions())`")
        XCTAssertEqual(drill.versionsJSON()["gateway"], pins.gateway.version)
        for port in [8317, 18320, 18316, 18317] {
            let names = Drill.listeners(port: port)
            drill.note("- listeners on \(port): \(names.joined(separator: ", "))")
            XCTAssertEqual(names, ["127.0.0.1:\(port)"], "port \(port) must listen on IPv4 loopback only")
        }
        let healthz = try await drill.http("GET", "http://127.0.0.1:18320/healthz")
        drill.note("- `GET :18320/healthz`: \(healthz.status) `\(healthz.text)`")
        XCTAssertEqual(healthz.status, 200)

        // 2. Two mock upstreams.
        drill.note("## 2. Mock upstreams A (19101) and B (19102)")
        upstreams["a"] = try drill.startUpstream(name: "a", port: 19101)
        upstreams["b"] = try drill.startUpstream(name: "b", port: 19102)

        // 3. Two compatible providers through the app's append (prefix allocated against the list).
        drill.note("## 3. Compatible providers")
        let engine = URL(string: "http://127.0.0.1:18316")!
        let client = ManagementAPIClient()
        for (name, port) in [("provider-a", 19101), ("provider-b", 19102)] {
            let write = RuntimeOpenAICompatibilityWrite(
                name: name, priority: 0, disabled: false, prefix: "",
                baseURL: "http://127.0.0.1:\(port)/v1",
                apiKeyEntries: [RuntimeProviderAPIKey(apiKey: "upstream-\(name)-\(Drill.randomHex(8))")],
                models: [RuntimeProviderModel(name: Self.chatModel, alias: Self.chatModel), RuntimeProviderModel(name: "mock-chat", alias: "mock-chat")],
                headers: [:], disableCooling: false
            )
            let outcome = try await client.appendOpenAICompatibility(write, allocatePrefixAgainst: [], baseURL: engine, managementKey: managementKey)
            XCTAssertEqual(outcome, .appended)
        }
        let prefixes = drill.configPrefixes()
        drill.note("- prefixes in `config.yaml`: \(prefixes.map { "`\($0.name)` → `\($0.prefix)`" }.joined(separator: ", "))")
        XCTAssertEqual(prefixes.count, 2)
        XCTAssertTrue(prefixes.allSatisfy { $0.prefix.hasPrefix("pin-") })
        XCTAssertEqual(Set(prefixes.map(\.prefix)).count, 2, "prefixes must differ")
        let gateway = GatewayAdminClient(baseURL: URL(string: "http://127.0.0.1:18320")!, managementKey: managementKey)
        let providerIDs = try await drill.waitFor("both providers in the gateway") { () async throws -> [String]? in
            let ids = try await gateway.modelProviders(model: Self.chatModel).providers.map(\.name).sorted()
            return ids.count == 2 ? ids : nil
        }
        drill.note("- gateway providers for `\(Self.chatModel)`: \(providerIDs)")

        // 4. A policy key: only glm-5, 10 requests per minute.
        drill.note("## 4. Policy key (allowlist glm-5, RPM 10)")
        let policyKey = "sk-e2e-\(Drill.randomHex(24))"
        keys.append(policyKey)
        var policy = GatewayKeyPolicy(label: "e2e policy", mode: .allowlist, allowedModels: [Self.chatModel], rateLimit: GatewayRateLimit(requestsPerMinute: 10))
        policy.legacyDefaultAllow = false
        _ = try await gateway.save(.addKey(key: policyKey, policy: policy))
        let first = try await drill.chat(key: policyKey, model: Self.chatModel)
        drill.note("- `POST :8317/v1/chat/completions` (glm-5): \(first.status), content `\(first.content ?? "-")`")
        XCTAssertEqual(first.status, 200, first.text)
        let denied = try await drill.chat(key: policyKey, model: "mock-chat")
        drill.note("- same key, model mock-chat (not allowed): \(denied.status) `\(denied.errorCode ?? "-")`")
        XCTAssertEqual(denied.status, 403)
        let models = try await drill.http("GET", "http://127.0.0.1:8317/v1/models", bearer: policyKey)
        let modelIDs = Drill.ids(models.body)
        drill.note("- `GET :8317/v1/models`: \(models.status), ids \(modelIDs)")
        XCTAssertEqual(models.status, 200)
        XCTAssertFalse(modelIDs.contains { $0.lowercased().hasPrefix("pin-") }, "/v1/models lists an internal pin- id")
        // The per-minute limit, on a second key (RPM 3) so that the policy key keeps its budget.
        let rpmKey = "sk-e2e-\(Drill.randomHex(24))"
        keys.append(rpmKey)
        var rpmPolicy = GatewayKeyPolicy(label: "e2e rpm", mode: .allowlist, allowedModels: [Self.chatModel], rateLimit: GatewayRateLimit(requestsPerMinute: 3))
        rpmPolicy.legacyDefaultAllow = false
        _ = try await gateway.save(.addKey(key: rpmKey, policy: rpmPolicy))
        var rpmStatuses: [String] = []
        for _ in 0..<4 {
            let response = try await drill.chat(key: rpmKey, model: Self.chatModel)
            rpmStatuses.append(response.errorCode.map { "\(response.status) \($0)" } ?? "\(response.status)")
        }
        drill.note("- a key with RPM 3, four calls in a row: \(rpmStatuses)")
        XCTAssertEqual(rpmStatuses.prefix(3).map { $0 }, ["200", "200", "200"])
        XCTAssertTrue(rpmStatuses[3].hasPrefix("429"), rpmStatuses[3])

        // 5. A model pack with a priced member and a pack key (cost limit, monthly reset).
        drill.note("## 5. Model pack and pack key")
        try await gateway.savePacks(.upsertPack(GatewayPackDraft(
            name: "E2E pack", modelID: Self.packModel, mode: .roundRobin,
            members: [GatewayPackMember(model: Self.chatModel, inputUSDPer1M: 1, outputUSDPer1M: 2)]
        )))
        let packs = try await gateway.packsData().packs
        let packID = try XCTUnwrap(packs.first { $0.modelID == Self.packModel }?.id)
        let createdBefore = try await gateway.createPackKeys(GatewayPackKeyBatch(
            packID: packID, count: 1, labelPrefix: "e2e-before-upgrade", totalCostUSD: 5, reset: GatewayResetSchedule(unit: .month, every: 1)
        ))
        let beforeUpgradeKey = try XCTUnwrap(createdBefore.first)
        keys.append(beforeUpgradeKey.key)
        drill.note("- pack key starts with `sk-pk-`: \(beforeUpgradeKey.key.hasPrefix("sk-pk-"))")
        let packCall = try await drill.chat(key: beforeUpgradeKey.key, model: Self.packModel)
        drill.note("- pack key call (model `\(Self.packModel)`): \(packCall.status), answer model `\(packCall.model ?? "-")`")
        XCTAssertEqual(packCall.status, 200, packCall.text)

        // 6. Pin glm-5 to provider A (only): served by A, and what CPA Manager Plus records.
        drill.note("## 6. Pin only = A")
        policy.modelProviderPins = [Self.chatModel: GatewayProviderPin(provider: "provider-a", mode: .only)]
        _ = try await gateway.save(.savePolicy(key: policyKey, policy: policy))
        let pinned = try await drill.chat(key: policyKey, model: Self.chatModel)
        drill.note("- pinned call: \(pinned.status), content `\(pinned.content ?? "-")`")
        XCTAssertEqual(pinned.status, 200, pinned.text)
        XCTAssertEqual(pinned.content, "served-by:a")
        // Successful calls so far: 1 policy key, 3 RPM key, 1 pack key, 1 pinned.
        let collected = try await drill.waitFor("CPA Manager Plus to collect 6 usage events", timeout: 30) { () async throws -> Int? in
            let count = drill.usageEventCount()
            return count >= 6 ? count : nil
        }
        drill.note("- CPA Manager Plus `usage_events`: \(collected) rows; by (model | requested_model | resolved_model | provider | count):")
        for row in drill.usageEventGroups() { drill.note("  - `\(row.joined(separator: " | "))`") }

        // 7. A fails: the pinned request gets A's error and never reaches B.
        drill.note("## 7. A answers 500 (--fail)")
        if let a = upstreams["a"] { drill.stop(a) }
        upstreams["a"] = try drill.startUpstream(name: "a", port: 19101, fail: true, log: "a-fail")
        let bBefore = drill.chatRequests(log: "b")
        let failed = try await drill.chat(key: policyKey, model: Self.chatModel)
        drill.note("- pinned call: \(failed.status) `\(failed.errorMessage ?? "-")`; requests at A while failing: \(drill.chatRequests(log: "a-fail")); new requests at B: \(drill.chatRequests(log: "b") - bBefore)")
        XCTAssertTrue((500...599).contains(failed.status), failed.text)
        XCTAssertEqual(drill.chatRequests(log: "b"), bBefore, "an only pin reached provider B")

        // 8. A disabled in the provider list: 403 pinned_provider_unavailable.
        drill.note("## 8. A disabled")
        try await client.patchOpenAICompatibility(name: "provider-a", value: RuntimeOpenAICompatibilityPatch(disabled: true), baseURL: engine, managementKey: managementKey)
        let refused = try await drill.waitFor("the gateway to refuse the pin", timeout: 30) { () async throws -> Drill.Chat? in
            let response = try await drill.chat(key: policyKey, model: Self.chatModel)
            return response.status == 403 ? response : nil
        }
        drill.note("- pinned call: \(refused.status) `\(refused.errorCode ?? "-")`")
        XCTAssertEqual(refused.errorCode, "pinned_provider_unavailable")

        // 9. CPA Manager Plus `PUT /usage-service/config`: the app's save of a fresh configuration,
        //    CPA Manager Plus's own answer written back, a stale version, the app's save again.
        drill.note("## 9. CPA Manager Plus usage-service config: app save and compare-and-set")
        let cpamp = URL(string: "http://127.0.0.1:18317")!
        func appSave(_ label: String) async {
            do {
                let current = try await client.managerConfig(baseURL: cpamp, managementKey: cpampKey)
                let encoded = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(current.config))) as? [String: Any]
                let targets = (encoded?["codexInspection"] as? [String: Any])?["targetTypes"].map { "\($0)".replacingOccurrences(of: "\n", with: " ") } ?? "absent"
                do {
                    let saved = try await client.saveManagerConfig(current.config, baseURL: cpamp, managementKey: cpampKey)
                    drill.note("- \(label): read `updatedAtMs` \(current.config.updatedAtMs.map(String.init) ?? "none"), sends `codexInspection.targetTypes` \(targets): accepted, `updatedAtMs` now \(saved.config.updatedAtMs.map(String.init) ?? "none")")
                } catch {
                    drill.note("- \(label): read `updatedAtMs` \(current.config.updatedAtMs.map(String.init) ?? "none"), sends `codexInspection.targetTypes` \(targets): REFUSED: \(error.localizedDescription.replacingOccurrences(of: "\n", with: " "))")
                }
            } catch {
                drill.note("- \(label): read failed: \(error.localizedDescription)")
            }
        }
        await appSave("the app's `saveManagerConfig` of the fresh configuration it read")
        let read = try await drill.http("GET", "http://127.0.0.1:18317/usage-service/config", bearer: cpampKey)
        drill.note("- raw `GET /usage-service/config`: \(read.status), ETag `\(read.header("ETag") ?? "none")`, source `\(Drill.string(read.body, "source") ?? "-")`")
        let rawConfig = ((try? JSONSerialization.jsonObject(with: read.body)) as? [String: Any])?["config"] as? [String: Any] ?? [:]
        let rawInspection = rawConfig["codexInspection"] as? [String: Any]
        drill.note("- raw `config` keys: \(rawConfig.keys.sorted()); `codexInspection.targetTypes`: \(rawInspection?["targetTypes"].map { "\($0)".replacingOccurrences(of: "\n", with: " ") } ?? "absent"), `targetType`: \(rawInspection?["targetType"].map { "\($0)" } ?? "absent"), `updatedAtMs`: \(rawConfig["updatedAtMs"].map { "\($0)" } ?? "absent")")
        let roundTrip = try JSONSerialization.data(withJSONObject: ["config": rawConfig])
        let rawSave = try await drill.http("PUT", "http://127.0.0.1:18317/usage-service/config", bearer: cpampKey, json: roundTrip)
        let savedVersion = ((try? JSONSerialization.jsonObject(with: rawSave.body)) as? [String: Any]).flatMap { ($0["config"] as? [String: Any])?["updatedAtMs"] }
        drill.note("- raw PUT of that `config` unchanged: \(rawSave.status), ETag `\(rawSave.header("ETag") ?? "none")`, `updatedAtMs` now \(savedVersion.map { "\($0)" } ?? "none")\(rawSave.status >= 400 ? " `\(rawSave.text.prefix(160))`" : "")")
        var stale = rawConfig
        stale["updatedAtMs"] = 1
        var staleRequest = URLRequest(url: URL(string: "http://127.0.0.1:18317/usage-service/config")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        staleRequest.httpMethod = "PUT"
        staleRequest.setValue("Bearer \(cpampKey)", forHTTPHeaderField: "Authorization")
        staleRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        staleRequest.setValue("\"1\"", forHTTPHeaderField: "If-Match")
        staleRequest.httpBody = try JSONSerialization.data(withJSONObject: ["config": stale])
        let (staleData, staleResponse) = try await SecretBearingURLSession.shared.data(for: staleRequest)
        let staleStatus = (staleResponse as? HTTPURLResponse)?.statusCode ?? -1
        drill.note("- raw PUT with a stale version (`If-Match: \"1\"`, body `updatedAtMs: 1`): \(staleStatus)\(staleStatus >= 400 ? " `\(String(decoding: staleData, as: UTF8.self).prefix(160))`" : " (accepted: no compare-and-set, last writer wins)")")
        await appSave("the app's `saveManagerConfig` again, after CPA Manager Plus stored a configuration once")

        // 10. Upgrade to the next gateway: version up, e2e-format.json, then a second pack key.
        drill.note("## 10. Upgrade to gateway \(next.version)")
        let upgrade = try drill.run(maintenance.upgradeScriptForVerification(method: .native, installDirectory: root, pins: nextPins), name: "upgrade-next")
        drill.note("- upgrade script: exit \(upgrade.status), \(upgrade.seconds) s, backup `\(maintenance.parseResultForVerification(upgrade.stdout).backupName)`")
        XCTAssertEqual(upgrade.status, 0, upgrade.stderr)
        guard upgrade.status == 0 else { return }
        drill.note("- `.oases-cpa-versions`: `\(drill.versions())`")
        XCTAssertEqual(drill.versionsJSON()["gateway"], next.version)
        let upgradedHealth = try await drill.http("GET", "http://127.0.0.1:18320/healthz")
        drill.note("- `/healthz`: \(upgradedHealth.status) `\(upgradedHealth.text)`")
        XCTAssertTrue(upgradedHealth.text.contains("\"version\":\"\(next.version)\""))
        let formatFile = drill.root.appendingPathComponent("gateway-data/e2e-format.json")
        drill.note("- `gateway-data/e2e-format.json`: \(drill.read(formatFile) ?? "missing")")
        XCTAssertEqual(drill.read(formatFile)?.trimmingCharacters(in: .whitespacesAndNewlines), #"{"format":2}"#)
        let createdAfter = try await gateway.createPackKeys(GatewayPackKeyBatch(packID: packID, count: 1, labelPrefix: "e2e-after-upgrade"))
        let afterUpgradeKey = try XCTUnwrap(createdAfter.first)
        keys.append(afterUpgradeKey.key)
        let packKeysAfterUpgrade = try await gateway.packKeys(packID: packID).map(\.label).sorted()
        drill.note("- pack keys after the upgrade: \(packKeysAfterUpgrade)")
        let beforeKeyStillWorks = try await drill.chat(key: beforeUpgradeKey.key, model: Self.packModel)
        drill.note("- the pack key made before the upgrade: \(beforeKeyStillWorks.status)")
        XCTAssertEqual(beforeKeyStillWorks.status, 200, beforeKeyStillWorks.text)

        // 11. "Upgrade" with the bundled (older) gateway: refused, nothing stops.
        drill.note("## 11. Upgrade with the bundled gateway \(pins.gateway.version) (a downgrade)")
        let pidsBefore = drill.pids()
        let downgrade = try drill.run(maintenance.upgradeScriptForVerification(method: .native, installDirectory: root, pins: pins), name: "upgrade-older")
        let refusal = DowngradeRefusal(standardError: downgrade.stderr)
        drill.note("- upgrade script: exit \(downgrade.status); refusal: component `\(refusal?.component ?? "-")`, installed `\(refusal?.installed ?? "-")`, target `\(refusal?.target ?? "-")`")
        XCTAssertEqual(downgrade.status, 22, downgrade.stderr)
        XCTAssertEqual(refusal?.component, "gateway")
        let stillHealthy = try await drill.http("GET", "http://127.0.0.1:18320/healthz")
        drill.note("- afterwards: same pids \(drill.pids() == pidsBefore && drill.pidsAlive()), `/healthz` \(stillHealthy.status) `\(stillHealthy.text)`")
        XCTAssertEqual(drill.pids(), pidsBefore)
        XCTAssertTrue(drill.pidsAlive())
        XCTAssertTrue(stillHealthy.text.contains("\"version\":\"\(next.version)\""))

        // 12. Rollback: the old gateway and its data come back.
        drill.note("## 12. Rollback")
        let rollback = try drill.run(maintenance.rollbackScriptForVerification(method: .native, installDirectory: root), name: "rollback")
        drill.note("- rollback script: exit \(rollback.status), \(rollback.seconds) s")
        XCTAssertEqual(rollback.status, 0, rollback.stderr)
        guard rollback.status == 0 else { return }
        drill.note("- `.oases-cpa-versions`: `\(drill.versions())`")
        XCTAssertEqual(drill.versionsJSON()["gateway"], pins.gateway.version)
        let rolledBackHealth = try await drill.http("GET", "http://127.0.0.1:18320/healthz")
        drill.note("- `/healthz`: \(rolledBackHealth.status) `\(rolledBackHealth.text)`")
        XCTAssertTrue(rolledBackHealth.text.contains("\"version\":\"\(pins.gateway.version)\""))
        drill.note("- `gateway-data/e2e-format.json`: \(drill.read(formatFile) == nil ? "absent" : "present")")
        XCTAssertNil(drill.read(formatFile))
        let packKeysAfterRollback = try await gateway.packKeys(packID: packID).map(\.label).sorted()
        drill.note("- pack keys after the rollback: \(packKeysAfterRollback)")
        XCTAssertFalse(packKeysAfterRollback.contains { $0.hasPrefix("e2e-after-upgrade") })
        XCTAssertTrue(packKeysAfterRollback.contains { $0.hasPrefix("e2e-before-upgrade") })
        let kept = drill.find(named: "gateway-data-after-upgrade")
        drill.note("- newer gateway data kept at: \(kept.map { "`\($0)`" }.joined(separator: ", ")); holds e2e-format.json: \(kept.contains { FileManager.default.fileExists(atPath: "\(root)/\($0)/e2e-format.json") })")
        XCTAssertFalse(kept.isEmpty)
        let engineAfter = try await drill.http("GET", "http://127.0.0.1:18316/v0/management/config", bearer: managementKey)
        let cpampAfter = try await drill.http("GET", "http://127.0.0.1:18317/health")
        let packAfter = try await drill.chat(key: beforeUpgradeKey.key, model: Self.packModel)
        drill.note("- engine management \(engineAfter.status), CPA Manager Plus /health \(cpampAfter.status), pack key made before the upgrade \(packAfter.status)")
        XCTAssertEqual(engineAfter.status, 200)
        XCTAssertEqual(cpampAfter.status, 200)

        // 13. No key in logs, process arguments or curl arguments.
        drill.note("## 13. Secrets")
        let leaks = drill.leaks(of: keys)
        drill.note("- \(keys.count) keys (the 4 key files, 2 client keys, 2 pack keys) searched in `logs/`, `ps -axww` and the curl shim's argv: \(leaks.isEmpty ? "no hit" : leaks.joined(separator: "; "))")
        XCTAssertTrue(leaks.isEmpty, leaks.joined(separator: "; "))

        // 14. Stop with the app's stop script; nothing of the drill may be left.
        drill.note("## 14. Stop and removal")
        let pids = drill.pids()
        let stop = try drill.run(RuntimeLifecycleService().stopScriptForVerification(method: .native, installDirectory: root), name: "stop")
        drill.note("- stop script: exit \(stop.status); the three pids exited: \(!pids.isEmpty && pids.allSatisfy { kill($0, 0) != 0 })")
        XCTAssertEqual(stop.status, 0, stop.stderr)
        cleanUp()
        let remaining = drill.processesUnderRoot()
        drill.note("- processes under `<install>` afterwards: \(remaining.count)")
        XCTAssertEqual(remaining.count, 0)
        let removal = try drill.run(DeploymentRemovalService().scriptForVerification(method: .native, installDirectory: root), name: "removal")
        drill.note("- removal script on the scratch root: exit \(removal.status); root exists afterwards: \(FileManager.default.fileExists(atPath: root))")
        XCTAssertEqual(removal.status, 0, removal.stderr)
        let stillBusy = Self.fixedPorts.filter { !Drill.listeners(port: $0).isEmpty }
        drill.note("- fixed ports still listening: \(stillBusy.isEmpty ? "none" : "\(stillBusy)")")
        XCTAssertTrue(stillBusy.isEmpty)
    }
}

/// The scratch case of the drill: install root, HOME, curl shim, no egress, a masked log.
private final class Drill: @unchecked Sendable {
    struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
        let seconds: Int
    }

    struct HTTP {
        let status: Int
        let headers: [AnyHashable: Any]
        let body: Data
        var text: String { String(decoding: body, as: UTF8.self) }
        func header(_ name: String) -> String? {
            headers.first { ($0.key as? String)?.lowercased() == name.lowercased() }?.value as? String
        }
    }

    struct Chat {
        let status: Int
        let text: String
        let content: String?
        let model: String?
        let errorCode: String?
        let errorMessage: String?
    }

    let caseDirectory: URL
    let root: URL
    let home: URL
    let argvLog: URL
    let environment: [String: String]
    let repository: URL
    private var lines: [String] = []

    init(artifacts: String) throws {
        let fileManager = FileManager.default
        caseDirectory = FakeArtifacts.scratchRoot.appendingPathComponent("acceptance-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fileManager.createDirectory(at: caseDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let bin = caseDirectory.appendingPathComponent("bin")
        home = caseDirectory.appendingPathComponent("home")
        for directory in [bin, home] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        root = caseDirectory.appendingPathComponent("root")
        argvLog = caseDirectory.appendingPathComponent("curl-argv.log")
        fileManager.createFile(atPath: argvLog.path, contents: Data())
        repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try Data(#"""
        #!/bin/bash
        line='curl'; for arg in "$@"; do line="$line $arg"; done
        printf '%s\n' "$line" >> "$E2E_ARGV_LOG"
        url=""; out=""; prev=""
        for arg in "$@"; do
          if [ "$prev" = "-o" ]; then out="$arg"; fi
          case "$arg" in https://*) url="$arg" ;; esac
          prev="$arg"
        done
        case "$url" in
          https://github.com/*/releases/download/*|https://nodejs.org/dist/*)
            exec cp "$E2E_ARTIFACTS/$(basename "$url")" "$out" ;;
          https://*) echo "e2e: refused $url" >&2; exit 7 ;;
        esac
        exec /usr/bin/curl "$@"
        """#.utf8).write(to: bin.appendingPathComponent("curl"))
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("curl").path)
        environment = [
            "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": home.path,
            "TMPDIR": caseDirectory.path,
            "LC_ALL": "C",
            "E2E_ARGV_LOG": argvLog.path,
            "E2E_ARTIFACTS": artifacts,
            // A closed loopback port as proxy: no egress for the engine and the panel.
            "HTTPS_PROXY": "http://127.0.0.1:9",
            "HTTP_PROXY": "http://127.0.0.1:9",
            "https_proxy": "http://127.0.0.1:9",
            "http_proxy": "http://127.0.0.1:9",
            "NO_PROXY": "127.0.0.1,localhost",
            "no_proxy": "127.0.0.1,localhost",
            "MODEL_CATALOG_URL": "off",
        ]
        note("# Acceptance drill summary (masked)")
    }

    // MARK: Log

    func note(_ line: String) { lines.append(line) }

    func write(summaryWithSecrets secrets: [String]) {
        var text = lines.joined(separator: "\n") + "\n"
        for secret in secrets where !secret.isEmpty { text = text.replacingOccurrences(of: secret, with: "<key>") }
        text = text.replacingOccurrences(of: root.path, with: "<install>")
            .replacingOccurrences(of: caseDirectory.path, with: "<scratch>/drill")
            .replacingOccurrences(of: NSHomeDirectory(), with: "<home>")
        try? Data(text.utf8).write(to: caseDirectory.appendingPathComponent("drill-summary.md"))
    }

    // MARK: Scripts and processes

    func run(_ script: String, name: String) throws -> Run {
        let scriptURL = caseDirectory.appendingPathComponent("\(name).sh")
        let stdoutURL = caseDirectory.appendingPathComponent("\(name).stdout")
        let stderrURL = caseDirectory.appendingPathComponent("\(name).stderr")
        try Data(script.utf8).write(to: scriptURL)
        FileManager.default.createFile(atPath: stdoutURL.path, contents: Data())
        FileManager.default.createFile(atPath: stderrURL.path, contents: Data())
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        process.environment = environment
        process.currentDirectoryURL = caseDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        let started = Date()
        try process.run()
        process.waitUntilExit()
        try stdoutHandle.close()
        try stderrHandle.close()
        return Run(status: process.terminationStatus,
                   stdout: (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "",
                   stderr: (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "",
                   seconds: Int(Date().timeIntervalSince(started).rounded()))
    }

    /// A mock upstream on a fixed loopback port, run by the drill's own pinned Node.
    func startUpstream(name: String, port: Int, fail: Bool = false, log: String? = nil) throws -> Process {
        let logName = log ?? name
        let out = caseDirectory.appendingPathComponent("upstream-\(logName).log")
        let err = caseDirectory.appendingPathComponent("upstream-\(logName).err")
        FileManager.default.createFile(atPath: out.path, contents: Data())
        FileManager.default.createFile(atPath: err.path, contents: Data())
        let process = Process()
        process.executableURL = root.appendingPathComponent("node/current/bin/node")
        process.arguments = [repository.appendingPathComponent("script/e2e/mock-upstream.mjs").path, "--port", "\(port)", "--name", name] + (fail ? ["--fail"] : [])
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path]
        process.currentDirectoryURL = caseDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = try FileHandle(forWritingTo: err)
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (read(err) ?? "").contains("listening on http://127.0.0.1:\(port)/v1") { return process }
            usleep(100_000)
        }
        stop(process)
        throw NSError(domain: "drill", code: 3, userInfo: [NSLocalizedDescriptionKey: "mock upstream \(name) did not start"])
    }

    func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(100_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    /// The pids of the three managed processes, from their pid files.
    func pids() -> [Int32] {
        DeploymentScriptFragments.managedProcesses(topology: .gateway).map(\.pidFile).compactMap {
            read(root.appendingPathComponent($0)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    func pidsAlive() -> Bool {
        let pids = pids()
        return pids.count == 3 && pids.allSatisfy { kill($0, 0) == 0 }
    }

    /// SIGTERM, then SIGKILL after 30 s, for every process whose command line is under the root.
    func stopAll() {
        var targets = Set(pids().filter { $0 > 1 })
        targets.formUnion(processesUnderRoot())
        for pid in targets { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, targets.contains(where: { kill($0, 0) == 0 }) { usleep(100_000) }
        for pid in targets where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    func processesUnderRoot() -> [Int32] {
        let list = Self.run("/bin/ps", ["-axww", "-o", "pid=,command="])
        return list.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(root.path), let space = trimmed.firstIndex(of: " ") else { return nil }
            return Int32(trimmed[..<space])
        }
    }

    static func listeners(port: Int) -> [String] {
        run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"])
            .split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }

    static func run(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Files

    func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    func secret(_ name: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent("secrets/\(name)"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func versions() -> String {
        (read(root.appendingPathComponent(".oases-cpa-versions")) ?? "missing")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined()
    }

    func versionsJSON() -> [String: String] {
        guard let data = read(root.appendingPathComponent(".oases-cpa-versions"))?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return object
    }

    /// `name` / `prefix` pairs of the openai-compatibility entries in config.yaml.
    func configPrefixes() -> [(name: String, prefix: String)] {
        var result: [(String, String)] = []
        var name: String?
        for raw in (read(root.appendingPathComponent("cli-proxy-api/config.yaml")) ?? "").split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- name:") { name = Self.yamlValue(line.dropFirst("- name:".count)) }
            if line.hasPrefix("prefix:"), let current = name {
                result.append((current, Self.yamlValue(line.dropFirst("prefix:".count))))
                name = nil
            }
        }
        return result
    }

    private static func yamlValue(_ value: Substring) -> String {
        value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// Chat completion requests a mock upstream logged.
    func chatRequests(log: String) -> Int {
        (read(caseDirectory.appendingPathComponent("upstream-\(log).log")) ?? "")
            .split(separator: "\n").filter { $0.contains("\"path\":\"/v1/chat/completions\"") }.count
    }

    /// CPA Manager Plus's stored usage events, read-only from its SQLite file.
    private func usageQuery(_ sql: String) -> [[String]] {
        let database = root.appendingPathComponent("cpamp/data/usage.sqlite").path
        guard FileManager.default.fileExists(atPath: database) else { return [] }
        let output = Self.run("/usr/bin/sqlite3", ["-readonly", "-separator", "\t", database, sql])
        return output.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    func usageEventCount() -> Int {
        Int(usageQuery("select count(*) from usage_events").first?.first ?? "") ?? 0
    }

    func usageEventGroups() -> [[String]] {
        usageQuery("""
        select model, coalesce(requested_model, ''), coalesce(resolved_model, ''), coalesce(provider, ''), count(*)
        from usage_events group by 1, 2, 3, 4 order by min(id)
        """)
    }

    /// Paths (relative to the root) of directories with this name.
    func find(named name: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var found: [String] = []
        while let path = enumerator.nextObject() as? String {
            if (path as NSString).lastPathComponent == name { found.append(path) }
        }
        return found.sorted()
    }

    /// Where any of the keys appears: the deployment's logs, every process argument, curl's argv.
    func leaks(of keys: [String]) -> [String] {
        var sources: [(String, String)] = [("ps", Self.run("/bin/ps", ["-axww", "-o", "command="])), ("curl argv", read(argvLog) ?? "")]
        let logs = root.appendingPathComponent("logs")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? [] {
            sources.append(("logs/\(name)", read(logs.appendingPathComponent(name)) ?? ""))
        }
        for name in ["upgrade-next", "upgrade-older", "rollback", "stop"] {
            sources.append(("\(name) output", (read(caseDirectory.appendingPathComponent("\(name).stdout")) ?? "") + (read(caseDirectory.appendingPathComponent("\(name).stderr")) ?? "")))
        }
        var hits: [String] = []
        for (index, key) in keys.enumerated() where !key.isEmpty {
            for (source, text) in sources where text.contains(key) { hits.append("key #\(index) in \(source)") }
        }
        return hits
    }

    // MARK: HTTP

    func http(_ method: String, _ url: String, bearer: String? = nil, json: Data? = nil) async throws -> HTTP {
        var request = URLRequest(url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let json {
            request.httpBody = json
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await SecretBearingURLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        return HTTP(status: http?.statusCode ?? -1, headers: http?.allHeaderFields ?? [:], body: data)
    }

    func chat(key: String, model: String) async throws -> Chat {
        let body = try JSONSerialization.data(withJSONObject: ["model": model, "messages": [["role": "user", "content": "hi"]], "max_tokens": 8])
        let response = try await http("POST", "http://127.0.0.1:8317/v1/chat/completions", bearer: key, json: body)
        let object = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        let message = ((object?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        let error = object?["error"] as? [String: Any]
        return Chat(status: response.status, text: response.text, content: message, model: object?["model"] as? String,
                    errorCode: error?["code"] as? String, errorMessage: error?["message"] as? String)
    }

    func waitFor<T>(_ what: String, timeout: TimeInterval = 20, _ probe: () async throws -> T?) async throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                if let value = try await probe() { return value }
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw NSError(domain: "drill", code: 4, userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(what) (\(lastError.map { String(describing: $0) } ?? "no answer"))"])
    }

    static func ids(_ data: Data) -> [String] {
        (((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.sorted()
    }

    static func string(_ data: Data, _ key: String) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?[key] as? String
    }

    static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
