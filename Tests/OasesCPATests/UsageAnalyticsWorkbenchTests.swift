import Foundation
import XCTest
@testable import OasesCPA

final class UsageAnalyticsWorkbenchTests: XCTestCase {
    /// Usage analytics is served by CPA Manager Plus (18317) and authorised with its admin key,
    /// in both topologies; the engine management key must never be sent there.
    @MainActor
    func testRequestsGoToCPAMPWithAdminKey() async throws {
        defer { URLProtocolStub.reset() }
        for topology in [DeploymentTopology.gateway, .legacy] {
            URLProtocolStub.install { request, _ in .json(500, #"{"error":"stub"}"#, for: request) }
            let deploymentStore = DeploymentStore(autoProbe: false)
            deploymentStore.attachForTesting(topology: topology, managementKey: "cpa-management-test-key", adminKey: "cpamp-test-key")
            let store = UsageAnalyticsWorkbenchStore(
                deploymentStore: deploymentStore,
                client: ManagementAPIClient(session: URLProtocolStub.makeSession())
            )
            XCTAssertTrue(store.isAttached)
            store.refresh()
            for _ in 0..<200 where store.isLoading || URLProtocolStub.recordedRequests.isEmpty {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let requests = URLProtocolStub.recordedRequests
            XCTAssertEqual(requests.count, 1, "\(topology)")
            let request = try XCTUnwrap(requests.first?.0)
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.url?.port, 18317, "\(topology)")
            XCTAssertEqual(request.url?.path, "/v0/management/monitoring/analytics")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cpamp-test-key")
            XCTAssertNotEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cpa-management-test-key")
            XCTAssertNotNil(requests.first?.1, "the analytics request carries a JSON body")
        }
    }

    @MainActor
    func testWithoutAdminKeyAnalyticsIsNotAttached() {
        let deploymentStore = DeploymentStore(autoProbe: false)
        deploymentStore.attachForTesting(topology: .gateway, managementKey: "cpa-management-test-key", adminKey: "")
        let store = UsageAnalyticsWorkbenchStore(deploymentStore: deploymentStore)
        XCTAssertFalse(store.isAttached, "analytics needs the CPAMP admin key, not the management key")
    }

    func testRequestUsesStableSnakeCaseAndTabSpecificIncludes() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let request = RuntimeUsageAnalyticsRequest(
            tab: .apiKeyRanks,
            range: .recentHour,
            now: now,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            granularity: .hour,
            searchQuery: "  model-a  ",
            models: ["z-model", "a-model", "a-model"],
            providers: ["provider-b", "provider-a"],
            includeFailed: .failed,
            minimumLatencyMS: -2,
            cacheStatus: .hit
        )

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["from_ms"] as? Int64, 1_699_996_400_000)
        XCTAssertEqual(object["search_query"] as? String, "model-a")
        XCTAssertNil(object["fromMs"])

        let filters = try XCTUnwrap(object["filters"] as? [String: Any])
        XCTAssertEqual(filters["models"] as? [String], ["a-model", "z-model"])
        XCTAssertEqual(filters["providers"] as? [String], ["provider-a", "provider-b"])
        XCTAssertEqual(filters["failed_only"] as? Bool, true)
        XCTAssertEqual(filters["min_latency_ms"] as? Int64, 0)
        XCTAssertEqual(filters["cache_status"] as? String, "hit")

        let include = try XCTUnwrap(object["include"] as? [String: Any])
        XCTAssertEqual(include["summary"] as? Bool, true)
        XCTAssertEqual(include["api_key_stats"] as? Bool, true)
        XCTAssertEqual(include["api_key_timeline"] as? Bool, true)
        XCTAssertEqual(include["model_stats"] as? Bool, false)
        XCTAssertEqual(include["credential_stats"] as? Bool, false)
        XCTAssertEqual(include["granularity"] as? String, "hour")
    }

    func testResponseDecodesAllWorkbenchDimensions() throws {
        let json = #"""
        {
          "generated_at_ms": 1700000000000,
          "granularity": "hour",
          "summary": {
            "total_calls": 12,
            "success_calls": 10,
            "failure_calls": 2,
            "success_rate": 0.8333,
            "input_tokens": 100,
            "output_tokens": 50,
            "cached_tokens": 5,
            "cache_read_tokens": 5,
            "cache_creation_tokens": 0,
            "cache_hit_rate": 0.1,
            "reasoning_tokens": 0,
            "total_tokens": 150,
            "total_cost": 0.12,
            "average_cost_per_call": 0.01,
            "average_latency_ms": 40,
            "p95_latency_ms": 80,
            "p95_ttft_ms": 20,
            "zero_token_calls": 0,
            "rpm_30m": 2,
            "tpm_30m": 30,
            "avg_daily_requests": 12,
            "avg_daily_tokens": 150,
            "approx_tasks": 1,
            "approx_task_failures": 0,
            "approx_task_success_rate": 1,
            "zero_token_models": []
          },
          "summary_comparison": {"from_ms": 1, "to_ms": 2, "total_calls": 8, "success_calls": 7, "failure_calls": 1, "success_rate": 0.875, "total_tokens": 90, "total_cost": 0.08},
          "timeline": [{"bucket_ms": 1700000000000, "label": "10:00", "calls": 12, "tokens": 150, "success": 10, "failure": 2, "input_tokens": 100, "output_tokens": 50, "cached_tokens": 5, "total_tokens": 150, "cost": 0.12, "average_latency_ms": 40, "p95_latency_ms": 80, "success_rate": 0.83, "failure_rate": 0.17}],
          "model_stats": [{"model": "gpt-4o", "calls": 12, "success_calls": 10, "failure_calls": 2, "success_rate": 0.83, "input_tokens": 100, "output_tokens": 50, "cached_tokens": 5, "total_tokens": 150, "cost": 0.12}],
          "api_key_stats": [{"id": "key-1", "api_key_hash": "sk-…1234", "calls": 12, "success_calls": 10, "failure_calls": 2, "success_rate": 0.83, "input_tokens": 100, "output_tokens": 50, "total_tokens": 150, "cost": 0.12}],
          "credential_stats": [{"id": "cred-1", "auth_file_snapshot": "openai.json", "calls": 12, "success_calls": 10, "failure_calls": 2, "success_rate": 0.83, "input_tokens": 100, "output_tokens": 50, "total_tokens": 150, "cost": 0.12}],
          "filter_options": {"models": ["gpt-4o"], "api_key_hashes": ["sk-…1234"], "providers": ["openai"], "auth_files": ["openai.json"], "accounts": [], "account_count": 1, "api_key_count": 1},
          "heatmap": [{"weekday": 1, "hour": 10, "calls": 12, "success": 10, "failure": 2, "tokens": 150, "cost": 0.12, "failure_rate": 0.17}],
          "anomaly_points": [{"bucket_ms": 1, "bucket_end_ms": 2, "label": "10:00", "severity": "medium", "metric_keys": ["failure_rate"], "calls": 12, "total_tokens": 150, "cost": 0.12, "failure_rate": 0.17, "request_change": 0.1, "cost_change": 0.1, "tokens_per_request_change": 0.1, "cache_hit_rate_change": 0, "failure_rate_change": 0.1, "latency_p95_change": 0.2}],
          "drilldown_preview": {"items": [{"event_hash": "event-1", "timestamp_ms": 1, "model": "gpt-4o", "endpoint": "/v1/chat/completions", "api_key_hash": "sk-…1234", "auth_index": "0", "auth_provider_snapshot": "openai", "total_tokens": 150, "latency_ms": 80, "failed": false, "fail_summary": ""}], "next_before_ms": 0, "next_before_id": 0, "has_more": false, "total_count": 1}
        }
        """#.data(using: .utf8)!

        let decoder = JSONDecoder()
        let response = try decoder.decode(RuntimeUsageAnalyticsResponse.self, from: json)
        XCTAssertEqual(response.summary?.totalCalls, 12)
        XCTAssertEqual(response.timeline.count, 1)
        XCTAssertEqual(response.modelStats.first?.model, "gpt-4o")
        XCTAssertEqual(response.apiKeyStats.first?.apiKeyHash, "sk-…1234")
        XCTAssertEqual(response.credentialStats.first?.authFileSnapshot, "openai.json")
        XCTAssertEqual(response.heatmap.first?.weekday, 1)
        XCTAssertEqual(response.anomalyPoints.first?.severity, "medium")
        XCTAssertEqual(response.drilldownPreview?.items.first?.eventHash, "event-1")
    }

    func testResponseTreatsTabScopedAnalyticsFieldsAsOptional() throws {
        let json = #"""
        {
          "generated_at_ms": 1700000000000,
          "granularity": "hour",
          "summary": {"total_calls": 1, "success_calls": 1},
          "timeline": [{"bucket_ms": 1700000000000, "calls": 1, "tokens": 3}],
          "api_key_timeline": [{"api_key_hash": "masked", "bucket_ms": 1700000000000}],
          "credential_timeline": [{"id": "credential", "bucket_ms": 1700000000000}],
          "drilldown_preview": {
            "items": [{"timestamp_ms": 1700000000000, "model": "gpt-test"}],
            "has_more": false
          }
        }
        """#.data(using: .utf8)!

        let response = try JSONDecoder().decode(RuntimeUsageAnalyticsResponse.self, from: json)
        XCTAssertEqual(response.summary?.totalCalls, 1)
        XCTAssertEqual(response.summary?.totalTokens, 0)
        XCTAssertEqual(response.timeline.first?.totalTokens, 3)
        XCTAssertEqual(response.timeline.first?.successRate, 0)
        XCTAssertEqual(response.apiKeyTimeline.first?.cost, 0)
        XCTAssertEqual(response.credentialTimeline.first?.label, "")
        XCTAssertEqual(response.drilldownPreview?.items.first?.model, "gpt-test")
        XCTAssertEqual(response.drilldownPreview?.totalCount, 1)
    }

    func testPresentationSortingIsDeterministic() {
        let values = [
            RuntimeUsageAnalyticsModelStat(model: "z", calls: 5, successCalls: 5, failureCalls: 0, successRate: 1, inputTokens: 0, outputTokens: 0, cachedTokens: 0, totalTokens: 10, cost: 0.1),
            RuntimeUsageAnalyticsModelStat(model: "a", calls: 5, successCalls: 5, failureCalls: 0, successRate: 1, inputTokens: 0, outputTokens: 0, cachedTokens: 0, totalTokens: 10, cost: 0.1),
            RuntimeUsageAnalyticsModelStat(model: "b", calls: 8, successCalls: 7, failureCalls: 1, successRate: 0.875, inputTokens: 0, outputTokens: 0, cachedTokens: 0, totalTokens: 10, cost: 0.2)
        ]
        XCTAssertEqual(RuntimeUsageAnalyticsPresentation.sortedModels(values).map(\.model), ["b", "a", "z"])
        XCTAssertEqual(RuntimeUsageAnalyticsPresentation.percentage(0.8333), "83.3%")
    }
}

/// The client decodes CPA Manager Plus's snake_case analytics answer (a key strategy on the
/// decoder would make every snake_case CodingKey miss and read zeros).
final class UsageAnalyticsClientDecodingTests: XCTestCase {
    func testClientDecodesTheSnakeCaseSummary() async throws {
        defer { URLProtocolStub.reset() }
        URLProtocolStub.install { request, _ in
            .json(200, #"{"generated_at_ms":1700000000000,"summary":{"total_calls":12,"success_calls":10,"failure_calls":2,"total_cost":0.12},"model_stats":[{"model":"glm-5","calls":12,"success_calls":10,"failure_calls":2,"success_rate":0.83,"input_tokens":100,"output_tokens":50,"cached_tokens":5,"total_tokens":150,"cost":0.12}]}"#, for: request)
        }
        let response = try await ManagementAPIClient(session: URLProtocolStub.makeSession()).usageAnalytics(
            RuntimeUsageAnalyticsRequest(tab: .overview),
            baseURL: URL(string: "http://127.0.0.1:18317")!,
            managementKey: "test-cpamp-admin"
        )
        XCTAssertEqual(response.generatedAtMs, 1_700_000_000_000)
        XCTAssertEqual(response.summary?.totalCalls, 12)
        XCTAssertEqual(response.summary?.successCalls, 10)
        XCTAssertEqual(response.summary?.totalCost, 0.12)
        XCTAssertEqual(response.modelStats.first?.calls, 12)
    }

    /// Siblings of the analytics bug: models with snake_case keys decoded by a
    /// `.convertFromSnakeCase` decoder never saw those fields. The engine's `/v1/models`
    /// (`display_name`, `owned_by`), an auth file's models and a cooldown's evidence.
    func testSnakeCaseFieldsDecodeThroughTheRealClients() async throws {
        defer { URLProtocolStub.reset() }
        URLProtocolStub.install { request, _ in
            switch request.url?.path {
            case "/v1/models":
                return .json(200, #"{"object":"list","data":[{"id":"glm-5","object":"model","display_name":"GLM 5","owned_by":"zhipu"},{"id":"pin-a/glm-5","display_name":"x"}]}"#, for: request)
            case "/usage-service/quota-cooldowns":
                return .json(200, #"{"items":[{"auth_file_name":"codex.json","auth_index":"3","recover_at_ms":1700000000000,"window_kind":"weekly","evidence":{"provider":"codex","window_kind":"weekly","observed_at_ms":1699999000000,"recover_at_ms":1700000000000,"recover_at_estimated":true}}]}"#, for: request)
            default:
                return .json(200, #"{"models":[{"id":"gpt-5.5","display_name":"GPT 5.5","type":"chat","owned_by":"openai"}]}"#, for: request)
            }
        }
        let client = ManagementAPIClient(session: URLProtocolStub.makeSession())
        let base = try XCTUnwrap(URL(string: "http://127.0.0.1:18316"))

        let catalog = try await client.gatewayModels(baseURL: base, apiKey: nil)
        XCTAssertEqual(catalog.data.map(\.id), ["glm-5"], "internal ids dropped")
        XCTAssertEqual(catalog.data.first?.displayName, "GLM 5")
        XCTAssertEqual(catalog.data.first?.ownedBy, "zhipu")

        let models = try await client.authFileWorkbenchModels(name: "codex.json", baseURL: base, managementKey: "test-management-key")
        XCTAssertEqual(models.models.first?.displayName, "GPT 5.5")
        XCTAssertEqual(models.models.first?.ownedBy, "openai")
        XCTAssertEqual(models.models.first?.type, "chat")

        let cooldowns = try await client.activeQuotaCooldowns(baseURL: base, managementKey: "test-management-key")
        let evidence = try XCTUnwrap(cooldowns.items.first?.evidence)
        XCTAssertEqual(cooldowns.items.first?.authFileName, "codex.json")
        XCTAssertEqual(evidence.windowKind, "weekly")
        XCTAssertEqual(evidence.observedAtMs, 1_699_999_000_000)
        XCTAssertEqual(evidence.recoverAtMs, 1_700_000_000_000)
        XCTAssertEqual(evidence.recoverAtEstimated, true)

        // The same models decode with a plain decoder too.
        let plain = try JSONDecoder().decode(RuntimeGatewayModel.self, from: Data(#"{"id":"m","display_name":"M","owned_by":"o"}"#.utf8))
        XCTAssertEqual(plain.displayName, "M")
        XCTAssertEqual(plain.ownedBy, "o")
    }
}
