import Foundation
import XCTest
@testable import OasesCPA

/// Engine- and CPA Manager Plus-sourced model names are shown as public names (`pin-x/…` removed).
final class PublicModelNameTests: XCTestCase {
    func testPublicNameStripsInternalPrefixes() {
        let cases = ["pin-a/glm-5": "glm-5", "cc-pin-a/glm-5": "glm-5", "pin-b/pin-a/x": "x", "glm-5": "glm-5",
                     "cc-glm-5": "cc-glm-5", "openrouter/auto": "openrouter/auto", "my-pin-x/model": "my-pin-x/model", "pin-x": "pin-x"]
        for (raw, expected) in cases { XCTAssertEqual(InternalModelID.publicName(raw), expected, raw) }
    }

    func testIsInternalMatchesThePanelPattern() {
        // Vectors of the panel's utils/internalPrefix.test.ts.
        XCTAssertTrue(InternalModelID.isInternal("pin-x/glm-5.3-flash"))
        XCTAssertTrue(InternalModelID.isInternal("pin-mistral-student/zai-glm-5-3"))
        XCTAssertFalse(InternalModelID.isInternal("openrouter/auto"))
        XCTAssertFalse(InternalModelID.isInternal("glm-5.3-flash"))
        XCTAssertFalse(InternalModelID.isInternal("pin-x"))
        XCTAssertFalse(InternalModelID.isInternal("pin-/model"))
        XCTAssertFalse(InternalModelID.isInternal("my-pin-x/model"))
        // A user-chosen routing prefix is configuration and stays visible (ruling L8).
        XCTAssertFalse(InternalModelID.isInternal("team-a/glm-5"))
        XCTAssertEqual(InternalModelID.publicName("team-a/glm-5"), "team-a/glm-5")
    }

    func testPublicTextRemovesInternalHeadsFromFreeText() {
        XCTAssertEqual(InternalModelID.publicText("upstream rejected pin-a/glm-5: 429"), "upstream rejected glm-5: 429")
        XCTAssertEqual(InternalModelID.publicText("model \"cc-pin-b/pin-a/x\" missing"), "model \"x\" missing")
        XCTAssertEqual(InternalModelID.publicText("my-pin-x/model stays"), "my-pin-x/model stays")
        XCTAssertEqual(InternalModelID.publicText("no ids here"), "no ids here")
    }

    func testQueryVariantsMatchIOSAnalyticsModels() {
        XCTAssertEqual(
            InternalModelID.queryVariants(for: "glm-5", prefixes: ["pin-a", "", "pin-b", "pin-a"]),
            ["glm-5", "pin-a/glm-5", "pin-b/glm-5"]
        )
    }

    func testMergeByPublicNameSumsRows() throws {
        struct Row: Equatable { let model: String; let calls: Int; let cost: Double }
        let merged = InternalModelID.mergeByPublicName(
            [Row(model: "pin-a/glm-5", calls: 3, cost: 0.3), Row(model: "glm-5", calls: 2, cost: 0.2), Row(model: "gpt-5.5", calls: 1, cost: 0.1)],
            name: \.model,
            merge: { Row(model: InternalModelID.publicName($0.model), calls: $0.calls + $1.calls, cost: $0.cost + $1.cost) }
        )
        XCTAssertEqual(merged.map(\.calls), [5, 1])
        XCTAssertEqual(merged.map { InternalModelID.publicName($0.model) }, ["glm-5", "gpt-5.5"])

        // The dashboard's top models: counts and cost add up, the success rate is weighted by calls.
        let dashboard = try decodeDashboard(topModels: """
        [{"model":"pin-a/glm-5","calls":3,"tokens":30,"cost":0.3,"success_rate":1.0},
         {"model":"glm-5","calls":2,"tokens":20,"cost":0.2,"success_rate":0.5},
         {"model":"gpt-5.5","calls":1,"tokens":10,"cost":0.1,"success_rate":1.0}]
        """)
        let top = dashboard.publicTopModels
        XCTAssertEqual(top.map(\.model), ["glm-5", "gpt-5.5"])
        XCTAssertEqual(top.map(\.calls), [5, 1])
        XCTAssertEqual(top.map(\.tokens), [50, 10])
        XCTAssertEqual(top[0].cost, 0.5, accuracy: 1e-9)
        XCTAssertEqual(top[0].successRate, (3 * 1.0 + 2 * 0.5) / 5, accuracy: 1e-9)
    }

    func testCPAMPSourcedNamesAreShownAsPublicNames() throws {
        let dashboard = try decodeDashboard(
            topModels: #"[{"model":"pin-a/glm-5","calls":3,"tokens":30,"cost":0.3,"success_rate":1.0},{"model":"glm-5","calls":1,"tokens":10,"cost":0.1,"success_rate":1.0}]"#,
            costRank: #"[{"model":"pin-a/glm-5","calls":3,"tokens":30,"cost":0.3,"success_rate":1.0,"cost_share":0.75},{"model":"glm-5","calls":1,"tokens":10,"cost":0.1,"success_rate":1.0,"cost_share":0.25}]"#
        )
        let rank = dashboard.publicModelCostRank
        XCTAssertEqual(rank.map(\.model), ["glm-5"])
        XCTAssertEqual(rank[0].costShare, 1.0, accuracy: 1e-9)
        XCTAssertEqual(dashboard.recentFailures?.map(\.displayModel), ["glm-5"])

        let analytics = try JSONDecoder().decode(RuntimeUsageAnalyticsResponse.self, from: Data("""
        {
          "generated_at_ms": 1730000000000,
          "granularity": "hour",
          "model_stats": [
            {"model":"pin-a/glm-5","calls":3,"success_calls":3,"failure_calls":0,"success_rate":1,"input_tokens":1,"output_tokens":2,"cached_tokens":0,"total_tokens":3,"cost":0.3},
            {"model":"glm-5","calls":1,"success_calls":0,"failure_calls":1,"success_rate":0,"input_tokens":1,"output_tokens":1,"cached_tokens":0,"total_tokens":2,"cost":0.1}
          ],
          "recent_failures": [{"timestamp_ms":1730000000000,"model":"pin-a/glm-5","api_key_hash":"h","source":"s","auth_index":"1","endpoint":"/v1/chat/completions","fail_summary":"pin-a/glm-5 rate limited"}],
          "drilldown_preview": {"items":[{"event_hash":"e1","timestamp_ms":1,"model":"cc-pin-a/glm-5","endpoint":"/v1/messages"}]},
          "filter_options": {"models":["glm-5","pin-a/glm-5"]}
        }
        """.utf8))
        let stats = analytics.publicModelStats
        XCTAssertEqual(stats.map(\.model), ["glm-5"])
        XCTAssertEqual(stats[0].calls, 4)
        XCTAssertEqual(stats[0].successCalls, 3)
        XCTAssertEqual(stats[0].failureCalls, 1)
        XCTAssertEqual(stats[0].totalTokens, 5)
        XCTAssertEqual(stats[0].successRate, 0.75, accuracy: 1e-9)
        XCTAssertEqual(analytics.recentFailures.map(\.displayModel), ["glm-5"])
        XCTAssertEqual(analytics.recentFailures.map(\.displayFailSummary), ["glm-5 rate limited"])
        XCTAssertEqual(analytics.drilldownPreview?.items.map(\.displayModel), ["glm-5"])
        XCTAssertEqual(analytics.filterOptions?.publicModels, ["glm-5"])

        let eventJSON = try JSONDecoder().decode(RuntimeJSONValue.self, from: Data("""
        {"event_hash":"e1","timestamp_ms":1730000000000,"model":"pin-a/glm-5","resolved_model":"pin-a/glm-5-0414","fail_summary":"pin-a/glm-5 failed"}
        """.utf8))
        let event = try XCTUnwrap(RuntimeMonitoringEvent(value: eventJSON))
        XCTAssertEqual(event.displayModel, "glm-5")
        XCTAssertEqual(event.displayResolvedModel, "glm-5-0414")
        XCTAssertEqual(event.displayFailSummary, "glm-5 failed")

        let shown = dashboard.publicTopModels.map(\.model) + rank.map(\.model)
            + (dashboard.recentFailures ?? []).map(\.displayModel)
            + stats.map(\.model) + analytics.recentFailures.map(\.displayModel)
            + (analytics.drilldownPreview?.items ?? []).map(\.displayModel)
            + (analytics.filterOptions?.publicModels ?? [])
            + [event.displayModel, event.displayResolvedModel]
        for name in shown {
            XCTAssertFalse(name.hasPrefix("pin-") || name.contains("/pin-"), name)
        }
    }

    @MainActor
    func testFilterSelectionExpandsToRawVariants() throws {
        let store = UsageAnalyticsWorkbenchStore(baseURL: URL(string: "http://127.0.0.1:18317")!, managementKey: "test-admin-key")
        store.applyResponseForTesting(try JSONDecoder().decode(RuntimeUsageAnalyticsResponse.self, from: Data("""
        {"generated_at_ms":1,"granularity":"hour","filter_options":{"models":["glm-5","pin-a/glm-5","gpt-5.5"]}}
        """.utf8)))
        XCTAssertEqual(store.filterOptions?.publicModels, ["glm-5", "gpt-5.5"])
        store.selectedModels = ["glm-5"]
        let request = store.makeRequest(now: Date(timeIntervalSince1970: 1_730_000_000))
        XCTAssertEqual(request.filters.models, ["glm-5", "pin-a/glm-5"])
    }

    func testPriceCandidatesUsePublicNames() {
        let candidates = RuntimeDataStore.priceCandidates(
            usage: ["pin-a/glm-5", "glm-5"],
            gateway: ["glm-5", "pin-a/glm-5"],
            topModels: ["cc-pin-a/glm-5"],
            costRank: ["pin-b/pin-a/glm-5", "  ", "bad\nname"]
        )
        XCTAssertEqual(candidates, ["glm-5"])
    }

    func testMonitoringFiltersEncodeOnlyNonEmptyFields() throws {
        var filters = RuntimeMonitoringEventsRequest.Filters()
        filters.models = ["glm-5", "pin-a/glm-5"]
        filters.minLatencyMS = 1500
        let request = RuntimeMonitoringEventsRequest(
            range: .today,
            now: Date(timeIntervalSince1970: 1_735_689_600),
            searchQuery: "",
            failedOnly: false,
            filters: filters
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let encoded = try XCTUnwrap(json["filters"] as? [String: Any])
        XCTAssertEqual(Set(encoded.keys), ["models", "min_latency_ms", "failed_only"])
        XCTAssertEqual(encoded["models"] as? [String], ["glm-5", "pin-a/glm-5"])
        XCTAssertEqual(encoded["min_latency_ms"] as? Int, 1500)
        XCTAssertEqual(encoded["failed_only"] as? Bool, false)

        // Every field, with CPA Manager Plus's JSON names (monitoring/service.go Filters).
        var all = RuntimeMonitoringEventsRequest.Filters()
        all.models = ["m"]; all.providers = ["p"]; all.accounts = ["a"]; all.apiKeyHashes = ["h"]
        all.requestTypes = ["chat"]; all.headerErrorKinds = ["quota"]; all.minLatencyMS = 1; all.cacheStatus = "hit"
        let full = RuntimeMonitoringEventsRequest(range: .today, searchQuery: "", failedOnly: true, filters: all)
        let fullJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any])
        XCTAssertEqual(
            Set((fullJSON["filters"] as? [String: Any] ?? [:]).keys),
            ["models", "providers", "accounts", "api_key_hashes", "request_types", "header_error_kinds", "min_latency_ms", "cache_status", "failed_only"]
        )
        // The next page keeps the filters.
        let next = full.nextPage(after: RuntimeMonitoringEventsCursor(beforeMs: 5, beforeId: 6))
        let nextJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(next)) as? [String: Any])
        XCTAssertEqual((nextJSON["filters"] as? [String: Any])?["cache_status"] as? String, "hit")
        XCTAssertEqual((nextJSON["filters"] as? [String: Any])?["failed_only"] as? Bool, true)
    }

    // MARK: - Fixtures

    private func decodeDashboard(topModels: String = "[]", costRank: String = "[]") throws -> RuntimeDashboardSummary {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RuntimeDashboardSummary.self, from: Data("""
        {
          "generated_at_ms": 1730000000000,
          "today": {"total_calls":4,"success_calls":4,"failure_calls":0,"success_rate":1,"total_tokens":40,"total_cost":0.4,"average_latency_ms":10,"zero_token_calls":0},
          "rolling_30m": {"rpm":1,"tpm":1,"total_calls":1,"total_tokens":1},
          "top_models_today": \(topModels),
          "model_cost_rank": \(costRank),
          "recent_failures": [{"timestamp_ms":1730000000000,"model":"pin-a/glm-5","api_key_hash":"h","source_hash":"s","auth_index":1,"endpoint":"/v1/chat/completions"}]
        }
        """.utf8))
    }
}
