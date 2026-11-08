import Foundation
import XCTest
@testable import OasesCPA

/// `listPacks` / `keyView` / `resetView` shapes (gateway/packs.mjs). "future*" fields are
/// SYNTHETIC (a newer gateway's additions).
let gatewayPackJSON = """
{"id":"pk_0123456789abcdef","name":"Team chat","model_id":"team-chat","enabled":true,"identity":true,"mode":"primary_backup",
 "members":[{"model":"glm-5","input_usd_per_1m":0.3,"output_usd_per_1m":1.2},{"model":"deepseek-chat","input_usd_per_1m":null,"output_usd_per_1m":null}],
 "failover":{"first_byte_timeout_ms":30000,"max_attempts":2},"created_at":"2026-11-01T00:00:00.000Z","updated_at":"2026-11-02T03:04:05.678Z",
 "key_count":2,"active_key_count":1,"future_pack":{"x":1}}
"""

let gatewayPackKeyJSON = """
{"id":"pkk_0123456789abcdef","pack_id":"pk_0123456789abcdef","label":"team-1","tail":"Ab9z","enabled":true,"status":"active",
 "expires_at":"2026-12-01T00:00:00.000Z","limits":{"total_tokens":1000000,"total_cost_usd":null},
 "usage":{"prompt_tokens":10,"completion_tokens":5,"tokens":15,"cost_usd":0.000123456,"requests":2,"last_used_at":"2026-11-07T10:00:00.000Z"},
 "reset":{"unit":"month","every":1,"anchor_at":"2026-11-01T00:00:00.000Z","next_reset_at":"2026-12-01T00:00:00.000Z","last_reset_at":null},
 "lifetime":{"prompt_tokens":100,"completion_tokens":50,"tokens":150,"cost_usd":0.5,"requests":9},
 "bound":false,"owner_id":null,"bound_at":null,"created_at":"2026-11-01T00:00:00.000Z","future_key":true}
"""

final class GatewayPackContractTests: XCTestCase {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func draft(members: [GatewayPackMember] = [GatewayPackMember(model: "glm-5")]) -> GatewayPackDraft {
        GatewayPackDraft(name: "Team", modelID: "team-chat", mode: .roundRobin, members: members, failover: .defaults(memberCount: members.count))
    }

    func testDecodesPackAndKeyViewsWithUnknownFields() throws {
        let pack = try JSONDecoder().decode(GatewayPack.self, from: Data(gatewayPackJSON.utf8))
        XCTAssertEqual(pack.modelID, "team-chat")
        XCTAssertEqual(pack.mode, .primaryBackup)
        XCTAssertEqual(pack.members.first?.inputUSDPer1M, Decimal(string: "0.3"))
        XCTAssertNil(pack.members.last?.inputUSDPer1M)
        XCTAssertFalse(pack.isPriced)
        XCTAssertEqual(pack.failover, GatewayPackFailover(firstByteTimeoutMs: 30_000, maxAttempts: 2))
        XCTAssertEqual(pack.keyCount, 2)
        XCTAssertEqual(pack.activeKeyCount, 1)
        XCTAssertEqual(pack.updatedAt, GatewayDates.date(from: "2026-11-02T03:04:05.678Z"))
        XCTAssertEqual(pack.extra["future_pack"], .object(["x": .number(1)]))
        // Re-encoded, the unknown field is still there.
        XCTAssertNotNil(try json(pack)["future_pack"])

        let key = try JSONDecoder().decode(GatewayPackKey.self, from: Data(gatewayPackKeyJSON.utf8))
        XCTAssertEqual(key.packID, pack.id)
        XCTAssertEqual(key.status, .active)
        XCTAssertEqual(key.limits.totalTokens, 1_000_000)
        XCTAssertNil(key.limits.totalCostUSD)
        XCTAssertEqual(key.usage.tokens, 15)
        XCTAssertEqual(key.usage.costUSD, Decimal(string: "0.000123456"))
        XCTAssertEqual(key.reset?.unit, .month)
        XCTAssertEqual(key.reset?.nextResetAt, GatewayDates.date(from: "2026-12-01T00:00:00.000Z"))
        XCTAssertNil(key.reset?.lastResetAt)
        XCTAssertEqual(key.lifetime.requests, 9)
        XCTAssertFalse(key.bound)
        XCTAssertEqual(key.extra["future_key"], .boolean(true))
        XCTAssertEqual(key.maskedKey, "sk-pk-••••Ab9z")
        XCTAssertEqual(GatewayPackKeyStatus(rawValue: "quarantined"), .other("quarantined"))
    }

    func testValidationRules() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func errors(_ change: (inout GatewayPackDraft) -> Void) -> [String] {
            var value = draft()
            change(&value)
            return GatewayPackValidation.errors(pack: value)
        }
        XCTAssertEqual(errors { _ in }, [], "a valid draft")
        XCTAssertFalse(errors { $0.name = String(repeating: "a", count: 101) }.isEmpty, "name 101")
        XCTAssertEqual(errors { $0.name = String(repeating: "a", count: 100) }, [])
        XCTAssertFalse(errors { $0.modelID = "  " }.isEmpty, "model_id empty")
        XCTAssertFalse(errors { $0.modelID = String(repeating: "m", count: 65) }.isEmpty, "model_id 65")
        XCTAssertFalse(errors { $0.modelID = "team\u{0007}chat" }.isEmpty, "control character")
        XCTAssertFalse(errors { $0.members = []; $0.failover.maxAttempts = 1 }.isEmpty, "0 members")
        XCTAssertFalse(errors { $0.members = (1...9).map { GatewayPackMember(model: "m\($0)") } }.isEmpty, "9 members")
        XCTAssertFalse(errors { $0.members = [GatewayPackMember(model: "GLM-5"), GatewayPackMember(model: "glm-5")] }.isEmpty, "duplicate ignoring case")
        XCTAssertFalse(errors { $0.members = [GatewayPackMember(model: "glm-5", inputUSDPer1M: -1, outputUSDPer1M: 1)] }.isEmpty, "price -1")
        XCTAssertFalse(errors { $0.failover.firstByteTimeoutMs = 999 }.isEmpty, "timeout 999")
        XCTAssertFalse(errors { $0.failover.firstByteTimeoutMs = 120_001 }.isEmpty, "timeout 120001")
        XCTAssertEqual(errors { $0.failover.firstByteTimeoutMs = 120_000 }, [])
        XCTAssertFalse(errors { $0.failover.maxAttempts = 0 }.isEmpty, "max_attempts 0")
        XCTAssertFalse(errors { $0.failover.maxAttempts = 2 }.isEmpty, "max_attempts > members")
        XCTAssertFalse(GatewayPackValidation.errors(pack: draft(), hasCostLimitedKeys: true).isEmpty, "cost keys need prices")

        let pack = GatewayPack(id: "pk_1", name: "Team", modelID: "team-chat", mode: .roundRobin,
                               members: [GatewayPackMember(model: "glm-5")], failover: .defaults(memberCount: 1))
        func batchErrors(_ change: (inout GatewayPackKeyBatch) -> Void) -> [String] {
            var value = GatewayPackKeyBatch(packID: pack.id)
            change(&value)
            return GatewayPackValidation.errors(batch: value, pack: pack, now: now)
        }
        XCTAssertEqual(batchErrors { _ in }, [])
        XCTAssertFalse(batchErrors { $0.count = 0 }.isEmpty, "count 0")
        XCTAssertFalse(batchErrors { $0.count = 501 }.isEmpty, "count 501")
        XCTAssertEqual(batchErrors { $0.count = 500 }, [])
        XCTAssertFalse(batchErrors { $0.labelPrefix = String(repeating: "l", count: 81) }.isEmpty, "label_prefix 81")
        XCTAssertFalse(batchErrors { $0.reset = GatewayResetSchedule(unit: .day, every: 367) }.isEmpty, "day 367")
        XCTAssertFalse(batchErrors { $0.reset = GatewayResetSchedule(unit: .week, every: 53) }.isEmpty, "week 53")
        XCTAssertFalse(batchErrors { $0.reset = GatewayResetSchedule(unit: .month, every: 25) }.isEmpty, "month 25")
        XCTAssertEqual(batchErrors { $0.reset = GatewayResetSchedule(unit: .month, every: 24, anchorAt: now.addingTimeInterval(86_400)) }, [])
        XCTAssertFalse(batchErrors { $0.reset = GatewayResetSchedule(unit: .day, every: 1, anchorAt: now.addingTimeInterval(86_401)) }.isEmpty, "anchor > now + 1 day")
        // A cost limit while a member has no price: the same meaning as the gateway's pricing_required.
        XCTAssertEqual(batchErrors { $0.totalCostUSD = 5 }, [GatewayPackValidation.pricingRequiredMessage])
        XCTAssertFalse(batchErrors { $0.totalTokens = 0 }.isEmpty)
        var priced = pack
        priced.members = [GatewayPackMember(model: "glm-5", inputUSDPer1M: 0.3, outputUSDPer1M: 1.2)]
        XCTAssertEqual(GatewayPackValidation.errors(batch: GatewayPackKeyBatch(packID: pack.id, totalCostUSD: 5), pack: priced, now: now), [])
    }

    func testUpdateKeyEncodesClearAsNullAndKeepAsAbsent() throws {
        var patch = GatewayPackKeyPatch(keyID: "pkk_0123456789abcdef")
        patch.label = .keep
        patch.totalCostUSD = .clear
        patch.enabled = .set(false)
        patch.expiresAt = .set(Date(timeIntervalSince1970: 1_800_000_000))
        let body = try json(GatewayPacksSaveAction.updateKey(patch))
        XCTAssertEqual(body["action"] as? String, "update_key")
        XCTAssertEqual(body["key_id"] as? String, "pkk_0123456789abcdef")
        XCTAssertNil(body["label"], "keep is not written")
        XCTAssertTrue(body["total_cost_usd"] is NSNull, "clear is null")
        XCTAssertEqual(body["enabled"] as? Bool, false)
        XCTAssertEqual(body["expires_at"] as? String, "2027-01-15T08:00:00.000Z")
        XCTAssertNil(body["total_tokens"])
        XCTAssertNil(body["reset"])
        var clearing = GatewayPackKeyPatch(keyID: "k")
        clearing.reset = .clear
        XCTAssertTrue(try json(GatewayPacksSaveAction.updateKey(clearing))["reset"] is NSNull, "null = never restore")
    }

    func testCreateKeysBody() throws {
        let anchor = try XCTUnwrap(GatewayDates.date(from: "2026-11-01T00:00:00.000Z"))
        let batch = GatewayPackKeyBatch(packID: "pk_0123456789abcdef", count: 3, labelPrefix: " team ",
                                        reset: GatewayResetSchedule(unit: .month, every: 1, anchorAt: anchor))
        let body = try json(GatewayPacksSaveAction.createKeys(batch))
        XCTAssertEqual(body["action"] as? String, "create_keys")
        XCTAssertEqual(body["pack_id"] as? String, "pk_0123456789abcdef")
        XCTAssertEqual(body["count"] as? Int, 3)
        XCTAssertEqual(body["label_prefix"] as? String, "team")
        let reset = try XCTUnwrap(body["reset"] as? [String: Any])
        XCTAssertEqual(reset["unit"] as? String, "month")
        XCTAssertEqual(reset["every"] as? Int, 1)
        XCTAssertEqual(reset["anchor_at"] as? String, "2026-11-01T00:00:00.000Z")
        XCTAssertEqual(Set(reset.keys), ["unit", "every", "anchor_at"], "the gateway's own fields are not sent")
        XCTAssertEqual(Set(body.keys), ["action", "pack_id", "count", "label_prefix", "reset"], "unset limits are not written")

        // The other actions.
        XCTAssertEqual(try json(GatewayPacksSaveAction.deletePack(id: "pk_1")) as NSDictionary, ["action": "delete_pack", "pack_id": "pk_1"])
        XCTAssertEqual(try json(GatewayPacksSaveAction.resetUsage(keyID: "k")) as NSDictionary, ["action": "reset_usage", "key_id": "k"])
        XCTAssertEqual(try json(GatewayPacksSaveAction.deleteKey(keyID: "k")) as NSDictionary, ["action": "delete_key", "key_id": "k"])
        XCTAssertEqual(try json(GatewayPacksSaveAction.unbindKey(keyID: "k")) as NSDictionary, ["action": "unbind_key", "key_id": "k"])
        let upsert = try json(GatewayPacksSaveAction.upsertPack(draft(members: [GatewayPackMember(model: " glm-5 ", inputUSDPer1M: 0.3)])))
        XCTAssertEqual(upsert["action"] as? String, "upsert_pack")
        let pack = try XCTUnwrap(upsert["pack"] as? [String: Any])
        XCTAssertNil(pack["id"], "a new pack has no id")
        XCTAssertEqual(pack["model_id"] as? String, "team-chat")
        XCTAssertEqual(pack["mode"] as? String, "round_robin")
        let member = try XCTUnwrap((pack["members"] as? [[String: Any]])?.first)
        XCTAssertEqual(member["model"] as? String, "glm-5")
        XCTAssertEqual(member["input_usd_per_1m"] as? Double, 0.3)
        XCTAssertTrue(member["output_usd_per_1m"] is NSNull)
        XCTAssertEqual(pack["failover"] as? [String: Int], ["first_byte_timeout_ms": 30_000, "max_attempts": 1])
    }
}
