import Foundation
import XCTest
@testable import OasesCPA

/// A `/cpa-admin/permissions/api/data` body in the shape `server.mjs` sends (`permissions` is the
/// projected effective policy of each key plus a `usage` snapshot; `schema_version`; top-level
/// `usage`). SYNTHETIC parts: `future_flag` (today's gateway projects known fields only and
/// `save_policy` normalizes its input, so it never returns or stores unknown fields; a newer
/// gateway might) and the internal key in `keys` (the open-edition gateway hides it; an older one
/// did not).
let gatewayPermissionsFixture = """
{
  "keys": ["sk-cpa-test-key-one", "pack-engine-test-key"],
  "permissions": {
    "sk-cpa-test-key-one": {
      "label": "Team A",
      "enabled": true,
      "mode": "allowlist",
      "allowed_models": ["glm-5", "gpt-5.5"],
      "denied_models": [],
      "provider_allowlist": [],
      "capabilities": {"chat_completions": true, "responses": true, "messages": true, "image_generation": false, "web_search": false},
      "search_providers": [],
      "model_provider_pins": {"glm-5": {"provider": "compat-a", "mode": "only"}},
      "rate_limit": {"requests_per_minute": 60, "tokens_per_day": null},
      "expires_at": "2026-12-01T00:00:00.000Z",
      "notes": "",
      "legacy_default_allow": false,
      "future_flag": true,
      "usage": {"day": "2026-11-08", "requests": 3, "requests_last_minute": 1, "tokens": 1200, "tokens_per_day": null, "requests_per_minute": 60}
    }
  },
  "groupedModels": {"compat-a": ["glm-5", "pin-a/glm-5"], "认证文件 / 引擎模型": ["gpt-5.5"]},
  "disabledProviders": [],
  "schema_version": 2,
  "usage": {"sk-cpa-test-key-one": {"day": "2026-11-08", "requests": 3, "requests_last_minute": 1, "tokens": 1200, "tokens_per_day": null, "requests_per_minute": 60}}
}
"""

final class GatewayKeyPolicyContractTests: XCTestCase {
    private func decodeData(_ text: String = gatewayPermissionsFixture) throws -> GatewayPermissionsData {
        try JSONDecoder().decode(GatewayPermissionsData.self, from: Data(text.utf8))
    }

    private func json(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func testDecodesPolicyAndPreservesUnknownFields() throws {
        let data = try decodeData()
        XCTAssertEqual(data.schemaVersion, 2)
        let policy = try XCTUnwrap(data.policies["sk-cpa-test-key-one"])
        XCTAssertEqual(policy.label, "Team A")
        XCTAssertEqual(policy.mode, .allowlist)
        XCTAssertEqual(policy.allowedModels, ["glm-5", "gpt-5.5"])
        XCTAssertEqual(policy.modelProviderPins["glm-5"], GatewayProviderPin(provider: "compat-a", mode: .only))
        XCTAssertEqual(policy.rateLimit, GatewayRateLimit(requestsPerMinute: 60, tokensPerDay: nil))
        XCTAssertEqual(policy.expiresAt, GatewayDates.date(from: "2026-12-01T00:00:00.000Z"))
        XCTAssertEqual(policy.legacyDefaultAllow, false)
        XCTAssertEqual(policy.extra["future_flag"], .boolean(true))
        XCTAssertNil(policy.extra["usage"], "usage is a read-only snapshot, not a policy field")
        XCTAssertEqual(data.usage["sk-cpa-test-key-one"]?.tokens, 1200)
        XCTAssertEqual(data.usage["sk-cpa-test-key-one"]?.requestsPerMinute, 60)
        XCTAssertEqual(data.groupedModels["compat-a"], ["glm-5", "pin-a/glm-5"])
    }

    func testUsageInsideThePolicyIsUsedWhenTheTopLevelHasNone() throws {
        let data = try decodeData(gatewayPermissionsFixture.replacingOccurrences(
            of: #""usage": {"sk-cpa-test-key-one": {"day": "2026-11-08", "requests": 3, "requests_last_minute": 1, "tokens": 1200, "tokens_per_day": null, "requests_per_minute": 60}}"#,
            with: #""usage": {}"#
        ))
        XCTAssertEqual(data.usage["sk-cpa-test-key-one"]?.requests, 3)
    }

    func testSavePolicyBodyIsExplicitAndOmitsUsageAndAttestation() throws {
        var policy = GatewayKeyPolicy(
            label: "CI",
            capabilities: GatewayCapabilities(imageGeneration: false),
            rateLimit: GatewayRateLimit(requestsPerMinute: nil, tokensPerDay: 5000),
            expiresAt: GatewayDates.date(from: "2026-12-01T00:00:00.000Z"),
            legacyDefaultAllow: true,
            extra: ["future_flag": .boolean(true)]
        )
        // Even if an unknown-field map held them, these two are never written.
        policy.extra["usage"] = .object([:])
        policy.extra["attestation"] = .object([:])
        let body = try json(GatewayKeysSaveAction.savePolicy(key: "sk-cpa-test-key-one", policy: policy))
        XCTAssertEqual(body["action"] as? String, "save_policy")
        XCTAssertEqual(body["key"] as? String, "sk-cpa-test-key-one")
        let encoded = try XCTUnwrap(body["policy"] as? [String: Any])
        XCTAssertEqual(encoded["future_flag"] as? Bool, true)
        XCTAssertEqual((encoded["model_provider_pins"] as? [String: Any])?.count, 0)
        XCTAssertEqual(encoded["search_providers"] as? [String], [])
        let capabilities = try XCTUnwrap(encoded["capabilities"] as? [String: Bool])
        XCTAssertEqual(Set(capabilities.keys), ["chat_completions", "responses", "messages", "image_generation", "web_search"])
        XCTAssertEqual(capabilities["image_generation"], false)
        let rate = try XCTUnwrap(encoded["rate_limit"] as? [String: Any])
        XCTAssertTrue(rate["requests_per_minute"] is NSNull)
        XCTAssertEqual(rate["tokens_per_day"] as? Int, 5000)
        XCTAssertEqual(encoded["expires_at"] as? String, "2026-12-01T00:00:00.000Z")
        XCTAssertEqual(encoded["legacy_default_allow"] as? Bool, true)
        XCTAssertNil(encoded["usage"])
        XCTAssertNil(encoded["attestation"])

        // No expiry and no marker: both still written (null, and the effective value).
        let open = try json(GatewayKeyPolicy(allowedModels: ["a"]))
        XCTAssertTrue(open["expires_at"] is NSNull)
        XCTAssertEqual(open["legacy_default_allow"] as? Bool, false)
    }

    func testEachActionBody() throws {
        let add = try json(GatewayKeysSaveAction.addKey(key: "sk-cpa-new", policy: .newKeyDefault))
        XCTAssertEqual(Set(add.keys), ["action", "key", "policy"])
        XCTAssertEqual(add["action"] as? String, "add_key")
        XCTAssertEqual(add["key"] as? String, "sk-cpa-new")
        let delete = try json(GatewayKeysSaveAction.deleteKey(key: "sk-cpa-old"))
        XCTAssertEqual(delete as? [String: String], ["action": "delete_key", "key": "sk-cpa-old"])
        let label = try json(GatewayKeysSaveAction.setLabel(key: "sk-cpa-old", label: "Laptop"))
        XCTAssertEqual(label as? [String: String], ["action": "set_label", "key": "sk-cpa-old", "label": "Laptop"])
    }

    func testDraftWarnsBeforeDroppingPins() {
        let baseline = GatewayKeyPolicy(
            allowedModels: ["glm-5", "gpt-5.5"],
            legacyDefaultAllow: false,
            modelProviderPins: ["glm-5": GatewayProviderPin(provider: "compat-a", mode: .only)]
        )
        var draft = GatewayKeyPolicyDraft(baseline: baseline)
        XCTAssertEqual(draft.pinsThatWouldBeDropped(), [])
        draft.policy.allowedModels = ["gpt-5.5"]
        XCTAssertEqual(draft.pinsThatWouldBeDropped(), ["glm-5"])

        // Canonical comparison, like the gateway's: "CC-GLM-5" still allows "glm-5".
        draft.policy.allowedModels = ["CC-GLM-5"]
        XCTAssertEqual(draft.pinsThatWouldBeDropped(), [])

        // A denylist keeps no pin; "every model" has room for none either.
        draft.policy.mode = .denylist
        XCTAssertEqual(draft.pinsThatWouldBeDropped(), ["glm-5"])
        XCTAssertFalse(draft.validationErrors().isEmpty, "a denylist with pins cannot be saved before the user confirms")
        draft.policy.mode = .allowlist
        draft.allowsAllModels = true
        XCTAssertEqual(draft.pinsThatWouldBeDropped(), ["glm-5"])

        // Confirmed: the pins go, and nothing blocks the save any more.
        draft.dropUnreachablePins()
        XCTAssertEqual(draft.policy.modelProviderPins, [:])
        XCTAssertEqual(draft.pinsThatWouldBeDropped(), [])
        XCTAssertEqual(draft.validationErrors(), [])

        // A pin the user removed is not a loss.
        var removed = GatewayKeyPolicyDraft(baseline: baseline)
        removed.setPin(nil, for: "glm-5")
        removed.policy.allowedModels = ["gpt-5.5"]
        XCTAssertEqual(removed.pinsThatWouldBeDropped(), [])
    }

    func testDraftValidationErrors() {
        var draft = GatewayKeyPolicyDraft(baseline: GatewayKeyPolicy())
        XCTAssertEqual(draft.validationErrors(), [])
        draft.policy.label = String(repeating: "a", count: 101)
        draft.policy.notes = String(repeating: "n", count: 1001)
        draft.policy.rateLimit = GatewayRateLimit(requestsPerMinute: 0, tokensPerDay: -5)
        XCTAssertEqual(draft.validationErrors().count, 4)
    }

    func testDraftOfAPolicyWithoutMarkerNeverWidensWhenEmptied() throws {
        // An old policy allows one model and has no marker: emptying the list must allow nothing.
        var draft = GatewayKeyPolicyDraft(baseline: GatewayKeyPolicy(allowedModels: ["glm-5"], legacyDefaultAllow: nil))
        draft.policy.allowedModels = []
        XCTAssertFalse(draft.allowsAllModels)
        XCTAssertEqual(try json(draft.policy)["legacy_default_allow"] as? Bool, false)
        XCTAssertTrue(draft.hasChanges, "emptying the list is a change")
    }

    func testGeneratedKeyMatchesGatewayFormat() throws {
        let regex = try NSRegularExpression(pattern: "^[a-zA-Z0-9_-]+$")
        for _ in 0..<20 {
            let key = RuntimeAPIKeyGenerator.generate()
            XCTAssertLessThanOrEqual(key.count, 256)
            XCTAssertNotNil(regex.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)))
        }
    }

    func testEmptiedAllowlistEncodesLegacyDefaultAllowFalse() throws {
        var draft = GatewayKeyPolicyDraft(baseline: GatewayKeyPolicy(legacyDefaultAllow: true))
        XCTAssertTrue(draft.allowsAllModels)
        draft.allowsAllModels = false
        draft.policy.allowedModels = ["glm-5"]
        draft.policy.allowedModels = []
        let encoded = try json(draft.policy)
        XCTAssertEqual(encoded["legacy_default_allow"] as? Bool, false)
        XCTAssertEqual(encoded["allowed_models"] as? [String], [])
    }

    func testAllModelsToggleEncodesTrueWithEmptyList() throws {
        var draft = GatewayKeyPolicyDraft(baseline: GatewayKeyPolicy(allowedModels: ["glm-5"], legacyDefaultAllow: false))
        XCTAssertFalse(draft.allowsAllModels)
        draft.allowsAllModels = true
        let encoded = try json(draft.policy)
        XCTAssertEqual(encoded["legacy_default_allow"] as? Bool, true)
        XCTAssertEqual(encoded["allowed_models"] as? [String], [])
        XCTAssertEqual(encoded["mode"] as? String, "allowlist")
    }

    func testProvidersResponsePreservesUnknownFields() throws {
        // Shape of describeModelProviders (server.mjs); "future" is SYNTHETIC.
        let response = try JSONDecoder().decode(GatewayModelProvidersResponse.self, from: Data("""
        {"model":"glm-5","providers":[
          {"id":"compat-a","kind":"compat","name":"compat-a","priority":2,"prefix":"pin-a","draggable":true,"upstreamModel":"glm-5-0414","future":"x"},
          {"id":"oauth:codex","kind":"oauth","name":"Codex 账号 ×3","priority":0,"prefix":null,"draggable":false,"upstreamModel":"glm-5"}
        ]}
        """.utf8))
        XCTAssertEqual(response.providers.map(\.kind), [.compat, .oauth])
        XCTAssertEqual(response.pinnableProviders.map(\.name), ["compat-a"])
        let first = try XCTUnwrap(response.providers.first)
        XCTAssertEqual(first.extra["future"], .string("x"))
        XCTAssertNil(response.providers[1].prefix)
        let reencoded = try json(first)
        XCTAssertEqual(reencoded["future"] as? String, "x")
        XCTAssertEqual(reencoded["kind"] as? String, "compat")
    }

    func testInternalKeyConflictHasAReadableMessage() throws {
        let error = GatewayAdminError.from(
            status: 409,
            data: Data(#"{"success":false,"error":"The internal engine key is managed by the gateway","code":"internal_key"}"#.utf8),
            secrets: []
        )
        XCTAssertEqual(error.errorDescription, OasesLocalization.localized("这把 Key 是网关内部使用的引擎 Key，由网关自己管理，不能修改或删除。"))
    }
}

/// Pure logic of the shared editor components.
final class GatewayKeyComponentTests: XCTestCase {
    func testLimitFieldParsing() {
        XCTAssertEqual(LimitFields.parse(""), .success(nil))
        XCTAssertEqual(LimitFields.parse("  "), .success(nil))
        XCTAssertEqual(LimitFields.parse("60"), .success(60))
        XCTAssertEqual(LimitFields.parse("1,000,000"), .success(1_000_000))
        XCTAssertEqual(LimitFields.parse("0"), .failure(.notPositiveInteger))
        XCTAssertEqual(LimitFields.parse("-3"), .failure(.notPositiveInteger))
        XCTAssertEqual(LimitFields.parse("1.5"), .failure(.notPositiveInteger))
        XCTAssertEqual(LimitFields.parse("١٢"), .failure(.notPositiveInteger), "only ASCII digits")
        XCTAssertEqual(LimitFields.parseDecimal("2.5"), .success(2.5))
        XCTAssertEqual(LimitFields.parseDecimal(""), .success(nil))
        XCTAssertEqual(LimitFields.parseDecimal("0"), .failure(.notPositiveNumber))
    }

    func testPickerOptionsDropInternalIDs() {
        let options = ModelMultiPicker.options(from: ["compat-a": ["glm-5", "pin-a/glm-5", "cc-pin-a/x"], "empty": ["pin-b/y"], "认证文件 / 引擎模型": ["gpt-5.5"]])
        XCTAssertEqual(Set(options.map(\.group)), ["compat-a", "认证文件 / 引擎模型"], "a group of internal ids only is dropped")
        XCTAssertEqual(options.first { $0.group == "compat-a" }?.models, ["glm-5"])
    }

    func testPinEditorOffersCompatProvidersOnly() {
        let providers = [
            GatewayModelProvider(id: "compat-a", kind: .compat, name: "compat-a", priority: 2, prefix: "pin-a", draggable: true, upstreamModel: "glm-5"),
            GatewayModelProvider(id: "oauth:codex", kind: .oauth, name: "Codex 账号 ×3", priority: 1, prefix: nil, draggable: false, upstreamModel: "glm-5"),
            GatewayModelProvider(id: "compat-b", kind: .compat, name: "compat-b", priority: 0, prefix: "team-b", draggable: true, upstreamModel: "glm-5")
        ]
        XCTAssertEqual(ProviderPinEditor.options(from: providers), ["compat-a", "compat-b"])
    }

    func testMaskShowsFirstAndLastFour() {
        XCTAssertEqual(GatewayKeyRow.mask("client-key-for-mask-test"), "clie••••test")
        XCTAssertEqual(GatewayKeyRow.mask("short"), "••••")
    }
}
