import XCTest
import Darwin
@testable import OasesCPA

final class RuntimeDecodingTests: XCTestCase {
    func testOpenAICompatibilityDeleteURLUsesStableProviderName() throws {
        let url = try ManagementAPIClient.openAICompatibilityDeleteURL(
            name: "My Provider/中文",
            index: 7,
            baseURL: URL(string: "http://127.0.0.1:8317")!
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/v0/management/openai-compatibility")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "name" })?.value, "My Provider/中文")
        XCTAssertNil(components.queryItems?.first(where: { $0.name == "index" }))
    }

    func testDashboardSummaryDecodesFullManagementResponse() throws {
        let data = Data(
            """
            {
              "generated_at_ms": 1730000000000,
              "today": {
                "total_calls": 12,
                "success_calls": 10,
                "failure_calls": 2,
                "success_rate": 0.8333,
                "input_tokens": 100,
                "output_tokens": 200,
                "cached_tokens": 50,
                "cache_read_tokens": 25,
                "cache_creation_tokens": 25,
                "reasoning_tokens": 10,
                "total_tokens": 300,
                "total_cost": 1.25,
                "average_latency_ms": 420.5,
                "zero_token_calls": 1
              },
              "rolling_30m": {
                "rpm": 2.4,
                "tpm": 60.0,
                "total_calls": 4,
                "total_tokens": 100
              },
              "top_models_today": [{"model": "demo-model", "calls": 12, "tokens": 300, "cost": 1.25, "success_rate": 0.8333}],
              "model_cost_rank": [{"model": "demo-model", "calls": 12, "tokens": 300, "cost": 1.25, "success_rate": 0.8333, "cost_share": 1.0}],
              "traffic_timeline": [{"bucket_ms": 1730000000000, "calls": 12, "tokens": 300, "success": 10, "failure": 2}],
              "today_request_health_timeline": {
                "from_ms": 1730000000000,
                "to_ms": 1730000600000,
                "bucket_ms": 600000,
                "success_calls": 10,
                "failure_calls": 2,
                "total_calls": 12,
                "success_rate": 0.8333,
                "points": [{"bucket_ms": 1730000000000, "calls": 12, "tokens": 300, "success": 10, "failure": 2, "success_rate": 0.8333, "failure_rate": 0.1667, "tone": "warn", "intensity": 1.0, "future": false}]
              },
              "token_mix": [{"key": "input", "tokens": 100, "share": 0.3333}],
              "channel_health": [{"auth_index": 3, "auth_label": "Primary", "account": "masked", "channel": "codex", "source": "oauth", "calls": 12, "failures": 2, "failure_rate": 0.1667, "success_rate": 0.8333, "tokens": 300, "cost": 1.25, "average_latency_ms": 420.5, "tone": "warn"}],
              "recent_failures": [{"timestamp_ms": 1730000000000, "model": "demo-model", "api_key_hash": "hash", "source_hash": "source", "auth_index": 3, "auth_label": "Primary", "endpoint": "/v1/chat/completions", "duration_ms": 420.5, "fail_status_code": 429, "fail_summary": "rate limited"}]
            }
            """.utf8
        )

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let summary = try decoder.decode(RuntimeDashboardSummary.self, from: data)

        XCTAssertEqual(summary.today.totalCalls, 12)
        XCTAssertEqual(summary.modelCostRank?.first?.model, "demo-model")
        XCTAssertEqual(summary.channelHealth?.first?.authIndex, "3")
        XCTAssertEqual(summary.recentFailures?.first?.failStatusCode, 429)
    }

    func testDashboardRangesUseInclusiveCalendarWindows() {
        let now = Date(timeIntervalSince1970: 1_730_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let today = RuntimeDashboardRange.today.startDate(relativeTo: now, calendar: calendar)
        let sevenDays = RuntimeDashboardRange.sevenDays.startDate(relativeTo: now, calendar: calendar)
        let thirtyDays = RuntimeDashboardRange.thirtyDays.startDate(relativeTo: now, calendar: calendar)

        XCTAssertEqual(calendar.dateComponents([.day], from: sevenDays, to: today).day, 6)
        XCTAssertEqual(calendar.dateComponents([.day], from: thirtyDays, to: today).day, 29)
    }

    func testAuthFileDecodesNumericAndStringCompatibilityFields() throws {
        let data = Data(
            """
            {"files":[
              {"name":"numeric.json","type":"codex","auth_index":3,"runtime_only":"true","size":1024,"disabled":false},
              {"name":"string.json","provider":"claude","authIndex":"primary","runtimeOnly":false,"unavailable":true}
            ],"total":2}
            """.utf8
        )

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(RuntimeAuthFilesResponse.self, from: data)

        XCTAssertEqual(response.total, 2)
        XCTAssertEqual(response.files[0].authIndex, "3")
        XCTAssertEqual(response.files[0].runtimeOnly, true)
        XCTAssertEqual(response.files[1].authIndex, "primary")
        XCTAssertEqual(response.files[1].displayStatus, "不可用")
    }

    func testAuthFileStatusPatchUsesCLIProxyAPIFieldNames() throws {
        let patch = RuntimeAuthFileStatusPatch(
            name: "codex.json",
            authIndex: "4",
            disabled: true
        )
        let encoded = try JSONEncoder().encode(patch)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(object["name"] as? String, "codex.json")
        XCTAssertEqual(object["auth_index"] as? String, "4")
        XCTAssertEqual(object["disabled"] as? Bool, true)
        XCTAssertNil(object["authIndex"])
    }

    func testGatewayAPIKeysDecodeAndMaskWithoutExposingTheSecret() throws {
        let response = try JSONDecoder().decode(
            RuntimeAPIKeysResponse.self,
            from: Data(#"{"api-keys":["short-key","sk-cpa-12345678901234567890"]}"#.utf8)
        )
        XCTAssertEqual(response.keys, ["short-key", "sk-cpa-12345678901234567890"])

        let short = RuntimeAPIKey(index: 0, value: response.keys[0])
        let long = RuntimeAPIKey(index: 1, value: response.keys[1])
        XCTAssertEqual(short.maskedValue, "shor••••")
        XCTAssertEqual(long.maskedValue, "sk-cpa-••••7890")
        XCTAssertFalse(short.maskedValue.contains(short.value))
        XCTAssertFalse(long.maskedValue.contains(long.value))
    }

    func testGatewayAPIKeyMutationPayloadsUseDistinctCLIProxyAPIContracts() throws {
        let create = try JSONEncoder().encode(RuntimeAPIKeyAddPatch(value: "sk-cpa-created-value"))
        let createObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: create) as? [String: Any]
        )
        XCTAssertEqual(Set(createObject.keys), ["old", "new"])
        XCTAssertEqual(createObject["old"] as? String, createObject["new"] as? String)

        let replace = try JSONEncoder().encode(
            RuntimeAPIKeyReplacePatch(index: 7, value: "sk-cpa-replacement-value")
        )
        let replaceObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: replace) as? [String: Any]
        )
        XCTAssertEqual(Set(replaceObject.keys), ["index", "value"])
        XCTAssertEqual(replaceObject["index"] as? Int, 7)
        XCTAssertEqual(replaceObject["value"] as? String, "sk-cpa-replacement-value")
        XCTAssertNil(replaceObject["old"])
        XCTAssertNil(replaceObject["new"])
    }

    func testGatewayModelsDecodeDataDirectory() throws {
        let response = try JSONDecoder().decode(
            RuntimeGatewayModelsResponse.self,
            from: Data(
                #"{"object":"list","data":[{"id":"gpt-4o","object":"model","created":1730000000,"owned_by":"openai"},{"id":"claude-3-7-sonnet","display_name":"Claude 3.7 Sonnet","owned_by":"anthropic"}]}"#.utf8
            )
        )

        XCTAssertEqual(response.data.map(\.id), ["gpt-4o", "claude-3-7-sonnet"])
        XCTAssertEqual(response.data[0].title, "gpt-4o")
        XCTAssertEqual(response.data[0].ownedBy, "openai")
        XCTAssertEqual(response.data[1].title, "Claude 3.7 Sonnet")
        XCTAssertEqual(response.data[1].ownedBy, "anthropic")
    }

    func testGeneratedGatewayAPIKeysHaveSafeFormatAndAreUnique() {
        let first = RuntimeAPIKeyGenerator.generate()
        let second = RuntimeAPIKeyGenerator.generate()

        XCTAssertTrue(first.hasPrefix("sk-cpa-"))
        XCTAssertTrue(second.hasPrefix("sk-cpa-"))
        XCTAssertEqual(first.count, 55)
        XCTAssertEqual(second.count, 55)
        XCTAssertTrue(first.dropFirst(7).allSatisfy { $0.isHexDigit })
        XCTAssertTrue(second.dropFirst(7).allSatisfy { $0.isHexDigit })
        XCTAssertNotEqual(first, second)
    }

    func testQuotaProxyRequestUsesAuthIndexAndNeverEmbedsToken() throws {
        let data = Data(
            #"{"files":[{"name":"codex.json","type":"codex","auth_index":"codex-1","id_token":{"chatgpt_account_id":"account-1"}}]}"#.utf8
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let file = try XCTUnwrap(try decoder.decode(RuntimeAuthFilesResponse.self, from: data).files.first)
        let request = try XCTUnwrap(RuntimeQuotaRequestFactory.request(for: file))
        let encoded = try JSONEncoder().encode(
            RuntimeAPICallRequest(
                authIndex: file.authIndex,
                method: request.method,
                url: request.url,
                header: request.headers
            )
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(object["auth_index"] as? String, "codex-1")
        XCTAssertNil(object["authIndex"])
        XCTAssertEqual(request.headers["Authorization"], "Bearer $TOKEN$")
        XCTAssertEqual(request.headers["Chatgpt-Account-Id"], "account-1")
        XCTAssertFalse(String(data: encoded, encoding: .utf8)?.contains("access_token") == true)
        XCTAssertFalse(String(data: encoded, encoding: .utf8)?.contains("refresh_token") == true)
    }

    func testQuotaEvidenceParsesProviderWindows() throws {
        let filesData = Data(
            #"""
            {"files":[
              {"name":"codex.json","type":"codex","auth_index":"codex-1"},
              {"name":"claude.json","type":"claude","auth_index":"claude-1"},
              {"name":"kimi.json","type":"kimi","auth_index":"kimi-1"},
              {"name":"xai.json","type":"xai","auth_index":"xai-1"}
            ]}
            """#.utf8
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let files = try decoder.decode(RuntimeAuthFilesResponse.self, from: filesData).files

        let payloads: [String: String] = [
            "codex.json": #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":42,"reset_after_seconds":3600,"limit_window_seconds":18000},"secondary_window":{"used_percent":8}}}"#,
            "claude.json": #"{"five_hour":{"utilization":31,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":12,"resets_at":"2030-01-02T00:00:00Z"}}"#,
            "kimi.json": #"{"usage":{"used":20,"limit":100,"remaining":80,"reset_in":3600},"limits":[{"name":"weekly","detail":{"used":30,"limit":200,"remaining":170}}]}"#,
            "xai.json": #"{"config":{"credit_usage_percent":27,"billing_period_end":"2030-01-31T00:00:00Z","current_period":{"type":"monthly"}}}"#
        ]

        for file in files {
            let request = try XCTUnwrap(RuntimeQuotaRequestFactory.request(for: file))
            let responseData = try JSONSerialization.data(withJSONObject: [
                "status_code": 200,
                "header": [String: [String]](),
                "body": try XCTUnwrap(payloads[file.name])
            ])
            let response = try decoder.decode(RuntimeAPICallResponse.self, from: responseData)
            let evidence = RuntimeQuotaParser.parse(
                file: file,
                request: request,
                response: response,
                observedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )

            XCTAssertEqual(evidence.status, .success, file.name)
            XCTAssertFalse(evidence.windows.isEmpty, file.name)
        }
    }

    func testQuotaCooldownResponseDecodesProviderEvidence() throws {
        let data = Data(
            """
            {
              "items": [
                {
                  "auth_file_name": "codex.json",
                  "auth_index": "codex-1",
                  "provider": "codex",
                  "window_kind": "five_hour",
                  "recover_at_ms": 1800000000000,
                  "evidence": {
                    "provider": "codex",
                    "actual": 100,
                    "limit": 100,
                    "remaining": 0,
                    "recover_at_ms": 1800000000000,
                    "recover_at_estimated": true,
                    "source": "provider-header"
                  }
                }
              ]
            }
            """.utf8
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(RuntimeQuotaCooldownsResponse.self, from: data)
        let cooldown = try XCTUnwrap(response.items.first)

        XCTAssertEqual(cooldown.authFileName, "codex.json")
        XCTAssertEqual(cooldown.authIndex, "codex-1")
        XCTAssertEqual(cooldown.windowKind, "five_hour")
        XCTAssertEqual(cooldown.evidence?.remaining, 0)
        XCTAssertEqual(cooldown.evidence?.source, "provider-header")
    }

    func testSystemStatusDecodesCollectorAndMigrationState() throws {
        let data = Data(
            """
            {
              "service": "cpa-manager-plus",
              "dbPath": "/var/lib/oases-cpa/manager.db",
              "events": 120,
              "deadLetters": 2,
              "collector": {
                "collector": "running",
                "upstream": "http://127.0.0.1:8317",
                "mode": "auto",
                "transport": "http",
                "queue": "usage",
                "lastConsumedAt": 1730000000000,
                "lastInsertedAt": 1730000001000,
                "totalInserted": 120,
                "totalSkipped": 3,
                "deadLetters": 2,
                "lastError": ""
              },
              "dataMigration": {
                "name": "usage-cache-accounting",
                "status": "completed",
                "lastEventId": 120,
                "targetEventId": 120,
                "processedRows": 120,
                "changedRows": 4,
                "updatedAtMs": 1730000002000
              }
            }
            """.utf8
        )

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let status = try decoder.decode(RuntimeSystemStatus.self, from: data)

        XCTAssertEqual(status.service, "cpa-manager-plus")
        XCTAssertEqual(status.collector?.collector, "running")
        XCTAssertEqual(status.collector?.lastInsertedAt, 1_730_000_001_000)
        XCTAssertEqual(status.dataMigration?.status, "completed")
        XCTAssertEqual(status.deadLetters, 2)
    }

    func testManagerConfigDecodesAndEncodesCPAConnectionAndCollectorSettings() throws {
        let data = Data(
            """
            {
              "config": {
                "cpaConnection": {
                  "cpaBaseUrl": "http://127.0.0.1:8317",
                  "managementKey": "cpa_test_key"
                },
                "collector": {
                  "enabled": true,
                  "collectorMode": "auto",
                  "queue": "usage",
                  "popSide": "right",
                  "batchSize": 100,
                  "pollIntervalMs": 500,
                  "queryLimit": 50000,
                  "tlsSkipVerify": false
                },
                "externalUsageService": {
                  "enabled": false,
                  "serviceBase": ""
                },
                "updatedAtMs": 1730000002000
              },
              "source": "db",
              "cpaUsage": {
                "usageStatisticsEnabled": true,
                "redisUsageQueueRetentionSeconds": 86400
              }
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(RuntimeManagerConfigResponse.self, from: data)
        XCTAssertEqual(response.config.cpaConnection.cpaBaseURL, "http://127.0.0.1:8317")
        XCTAssertEqual(response.config.managementKey, "cpa_test_key")
        XCTAssertEqual(response.config.collector.pollIntervalMs, 500)
        XCTAssertEqual(response.config.isMonitoringEnabled, true)

        let encoded = try JSONEncoder().encode(RuntimeManagerConfigPayload(config: response.config))
        let encodedObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let configObject = try XCTUnwrap(encodedObject["config"] as? [String: Any])
        let connectionObject = try XCTUnwrap(configObject["cpaConnection"] as? [String: Any])
        XCTAssertEqual(connectionObject["cpaBaseUrl"] as? String, "http://127.0.0.1:8317")
        XCTAssertNil(connectionObject["cpaBaseURL"])
    }

    func testRuntimeLogsDecodeFlexibleCursorFields() throws {
        let data = Data(
            """
            {
              "lines": ["2026-08-01 request ok", "2026-08-01 response 200"],
              "line-count": "2",
              "latest-timestamp": 1730000000123,
              "latestAfter": "1730000000456",
              "nextCursor": "cursor-2",
              "cursorReset": "false"
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(RuntimeLogsResponse.self, from: data)
        XCTAssertEqual(response.lines.count, 2)
        XCTAssertEqual(response.lineCount, 2)
        XCTAssertEqual(response.latestTimestamp, 1_730_000_000_123)
        XCTAssertEqual(response.latestAfter, 1_730_000_000_456)
        XCTAssertEqual(response.nextCursor, "cursor-2")
        XCTAssertFalse(response.cursorReset)
    }

    func testOAuthModelsDecodeManagementResponses() throws {
        let start = try JSONDecoder().decode(
            RuntimeOAuthStartResponse.self,
            from: Data(#"{"status":"ok","url":"https://auth.example/codex","state":"state-1"}"#.utf8)
        )
        XCTAssertEqual(start.url, "https://auth.example/codex")
        XCTAssertEqual(start.state, "state-1")

        let waiting = try JSONDecoder().decode(
            RuntimeOAuthStatusResponse.self,
            from: Data(#"{"status":"wait"}"#.utf8)
        )
        XCTAssertEqual(waiting.status, .wait)
        XCTAssertNil(waiting.error)

        let failure = try JSONDecoder().decode(
            RuntimeOAuthStatusResponse.self,
            from: Data(#"{"status":"error","error":"invalid state"}"#.utf8)
        )
        XCTAssertEqual(failure.status, .error)
        XCTAssertEqual(failure.error, "invalid state")

        let callback = try JSONDecoder().decode(
            RuntimeOAuthCallbackResponse.self,
            from: Data(#"{"status":"ok"}"#.utf8)
        )
        XCTAssertEqual(callback.status, .ok)
    }

    func testOpenAICompatibilityModelsDecodeMaskedProviderSummary() throws {
        let data = Data(
            """
            {
              "openai-compatibility": [
                {
                  "name": "relay-a",
                  "priority": 3,
                  "disabled": false,
                  "prefix": "relay",
                  "base-url": "https://relay.example/v1",
                  "api-key-entries": [
                    { "api-key": "sk-test-12345678", "proxy-url": "" }
                  ],
                  "models": [
                    {
                      "name": "upstream-model",
                      "alias": "relay-model",
                      "display-name": "Relay Model",
                      "force-mapping": true,
                      "input-modalities": ["text", "image"],
                      "thinking": { "levels": ["low", "high"] }
                    }
                  ],
                  "headers": { "X-Org": "demo" },
                  "disable-cooling": true,
                  "auth-index": "relay-index"
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(RuntimeOpenAICompatibilityResponse.self, from: data)
        let provider = try XCTUnwrap(response.providers.first)
        XCTAssertEqual(provider.name, "relay-a")
        XCTAssertEqual(provider.baseURL, "https://relay.example/v1")
        XCTAssertEqual(provider.apiKeyEntries.first?.redacted, "sk-t••••5678")
        XCTAssertEqual(provider.models.first?.alias, "relay-model")
        XCTAssertEqual(provider.models.first?.forceMapping, true)
        XCTAssertEqual(provider.models.first?.inputModalities, ["text", "image"])
        XCTAssertNotNil(provider.models.first?.thinking)
        XCTAssertEqual(provider.headers["X-Org"], "demo")
        XCTAssertTrue(provider.disableCooling)
    }

    func testOpenAICompatibilitySummaryCountsRemainAvailableForEditor() throws {
        let data = Data(
            """
            {
              "openai-compatibility": [
                {
                  "name": "relay",
                  "base-url": "https://relay.example/v1",
                  "api-key-entries": [
                    { "api-key": "sk-one" },
                    { "api-key": "sk-two" }
                  ],
                  "models": [
                    { "name": "upstream-a", "alias": "relay-a", "display-name": "Relay A" },
                    { "name": "upstream-b", "alias": "relay-b", "display-name": "Relay B" }
                  ]
                }
              ]
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(RuntimeOpenAICompatibilityResponse.self, from: data)
        let provider = try XCTUnwrap(response.providers.first)
        XCTAssertEqual(provider.apiKeyEntries.count, 2)
        XCTAssertEqual(provider.models.count, 2)
        XCTAssertEqual(provider.models.map(\.alias), ["relay-a", "relay-b"])
    }

    func testOpenAICompatibilityPatchUsesCLIProxyAPIFieldNames() throws {
        let request = RuntimeOpenAICompatibilityPatchRequest(
            name: "relay-a",
            index: 2,
            value: RuntimeOpenAICompatibilityPatch(
                name: "relay-b",
                prefix: "team",
                disabled: false,
                disableCooling: true,
                baseURL: "https://relay.example/v1",
                apiKeyEntries: [
                    RuntimeProviderAPIKey(apiKey: "sk-secret", weight: 3, proxyURL: "http://proxy.example:8080")
                ],
                models: [
                    RuntimeProviderModel(
                        name: "upstream-model",
                        alias: "relay-model",
                        displayName: "Relay Model",
                        forceMapping: true,
                        inputModalities: ["text", "image"],
                        thinking: .object(["levels": .array([.string("low"), .string("high")])])
                    )
                ]
            )
        )
        let encoded = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let value = try XCTUnwrap(object["value"] as? [String: Any])
        XCTAssertEqual(object["name"] as? String, "relay-a")
        XCTAssertEqual(object["index"] as? Int, 2)
        XCTAssertEqual(value["base-url"] as? String, "https://relay.example/v1")
        XCTAssertEqual(value["disable-cooling"] as? Bool, true)
        let apiKeys = try XCTUnwrap(value["api-key-entries"] as? [[String: Any]])
        XCTAssertEqual(apiKeys.first?["api-key"] as? String, "sk-secret")
        XCTAssertEqual(apiKeys.first?["weight"] as? Int, 3)
        XCTAssertEqual(apiKeys.first?["proxy-url"] as? String, "http://proxy.example:8080")
        let models = try XCTUnwrap(value["models"] as? [[String: Any]])
        XCTAssertEqual(models.first?["name"] as? String, "upstream-model")
        XCTAssertEqual(models.first?["force-mapping"] as? Bool, true)
        XCTAssertEqual(models.first?["input-modalities"] as? [String], ["text", "image"])
        XCTAssertNil(value["baseURL"])
    }

    func testOpenAICompatibilityPutUsesCLIProxyAPIFieldNames() throws {
        let provider = RuntimeOpenAICompatibilityWrite(
            name: "relay-a",
            priority: 2,
            disabled: false,
            prefix: "team",
            baseURL: "https://relay.example/v1",
            apiKeyEntries: [RuntimeProviderAPIKey(apiKey: "sk-secret", weight: 4)],
            models: [
                RuntimeProviderModel(
                    name: "upstream-model",
                    alias: "relay-model",
                    image: true,
                    outputModalities: ["text"]
                )
            ],
            headers: ["X-Org": "demo"],
            disableCooling: true
        )
        let encoded = try JSONEncoder().encode([provider])
        let providers = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        let object = try XCTUnwrap(providers.first)
        XCTAssertEqual(object["base-url"] as? String, "https://relay.example/v1")
        XCTAssertEqual(object["priority"] as? Int, 2)
        XCTAssertEqual(object["disable-cooling"] as? Bool, true)
        XCTAssertNil(object["baseURL"])
        XCTAssertNil(object["auth-index"])
        let models = try XCTUnwrap(object["models"] as? [[String: Any]])
        XCTAssertEqual(models.first?["image"] as? Bool, true)
        XCTAssertEqual(models.first?["output-modalities"] as? [String], ["text"])
    }

    func testGeneratedDeploymentAndLifecycleScriptsHaveValidBashSyntax() throws {
        let executor = DeploymentExecutor()
        let lifecycle = RuntimeLifecycleService()
        let probe = DeploymentProbeService()
        let logs = DeploymentLogService()
        let recovery = DeploymentRecoveryService()
        let maintenance = DeploymentMaintenanceService()
        let adoption = ExistingDeploymentAdoptionService()

        for method in DeploymentMethod.allCases {
            try assertBashSyntax(executor.scriptForVerification(method: method, installDirectory: "~/.oases-cpa"))
            try assertBashSyntax(lifecycle.startScriptForVerification(method: method, installDirectory: "~/.oases-cpa"))
            try assertBashSyntax(lifecycle.stopScriptForVerification(method: method, installDirectory: "~/.oases-cpa"))
            try assertBashSyntax(logs.scriptForVerification(method: method, installDirectory: "~/.oases-cpa"))
            try assertBashSyntax(
                recovery.scriptForVerification(
                    method: method,
                    installDirectory: "~/.oases-cpa",
                    backupName: "failed-test"
                )
            )
            try assertBashSyntax(
                maintenance.upgradeScriptForVerification(
                    method: method,
                    installDirectory: "~/.oases-cpa"
                )
            )
            try assertBashSyntax(
                maintenance.rollbackScriptForVerification(
                    method: method,
                    installDirectory: "~/.oases-cpa"
                )
            )
        }
        try assertBashSyntax(probe.commandForVerification(installDirectory: "~/.oases-cpa"))
        try assertBashSyntax(adoption.scriptForVerification(installDirectory: "~/.oases-cpa"))
        try assertBashSyntax(maintenance.latestBackupScriptForVerification(installDirectory: "~/.oases-cpa"))
    }

    func testGeneratedScriptsExpandTildeRelativeToHomeWithoutKeepingLiteralTildeDirectory() {
        let scripts = [
            DeploymentExecutor().scriptForVerification(method: .native, installDirectory: "~/.oases-cpa"),
            DeploymentExecutor().scriptForVerification(method: .docker, installDirectory: "~/.oases-cpa"),
            DeploymentProbeService().commandForVerification(installDirectory: "~/.oases-cpa"),
            ExistingDeploymentAdoptionService().scriptForVerification(installDirectory: "~/.oases-cpa"),
            DeploymentLogService().scriptForVerification(method: .native, installDirectory: "~/.oases-cpa"),
            DeploymentLogService().scriptForVerification(method: .docker, installDirectory: "~/.oases-cpa"),
            RuntimeLifecycleService().startScriptForVerification(method: .native, installDirectory: "~/.oases-cpa"),
            RuntimeLifecycleService().startScriptForVerification(method: .docker, installDirectory: "~/.oases-cpa"),
            RuntimeLifecycleService().stopScriptForVerification(method: .native, installDirectory: "~/.oases-cpa"),
            RuntimeLifecycleService().stopScriptForVerification(method: .docker, installDirectory: "~/.oases-cpa"),
            DeploymentRecoveryService().scriptForVerification(
                method: .native,
                installDirectory: "~/.oases-cpa",
                backupName: "failed-test"
            ),
            DeploymentRecoveryService().scriptForVerification(
                method: .docker,
                installDirectory: "~/.oases-cpa",
                backupName: "failed-test"
            )
        ]

        for script in scripts {
            XCTAssertTrue(script.contains("#\\~/}"), "波浪号前缀必须以字面量模式移除")
            XCTAssertFalse(script.contains("#~/}"), "未转义的波浪号会被 Bash 展开为 HOME 并留下字面量 ~/ 目录")
        }
    }

    func testDeploymentMaintenancePreservesRuntimeRollbackContract() {
        let maintenance = DeploymentMaintenanceService()
        let upgrade = maintenance.upgradeScriptForVerification(
            method: .native,
            installDirectory: "~/.oases-cpa"
        )
        let rollback = maintenance.rollbackScriptForVerification(
            method: .native,
            installDirectory: "~/.oases-cpa"
        )

        XCTAssertTrue(upgrade.contains("upgrade-$(date -u"))
        XCTAssertTrue(upgrade.contains("CLI_VERSION_TAG=\"v7.2.141\""))
        XCTAssertTrue(upgrade.contains("CPAMP_VERSION_TAG=\"v1.11.10\""))
        XCTAssertTrue(upgrade.contains("CLI_EXPECTED_SHA256=\"a70015ee303502e24be64061dd0d5985b2b4600f0605a076b993322d3b7effb\""))
        XCTAssertTrue(upgrade.contains("CPAMP_EXPECTED_SHA256=\"c511e029b34f6f27bec65c2853b47991c1286767371a69d716bea29c8b8cc184\""))
        XCTAssertFalse(upgrade.contains("/releases/latest"))
        XCTAssertFalse(upgrade.contains("checksums.txt"))
        XCTAssertTrue(upgrade.contains("--location"))
        XCTAssertTrue(upgrade.contains("--max-redirs 3"))
        XCTAssertTrue(upgrade.contains("--proto '=https'"))
        XCTAssertTrue(upgrade.contains("--proto-redir '=https'"))
        XCTAssertTrue(upgrade.contains("cli-proxy-api-runtime"))
        XCTAssertTrue(upgrade.contains("OASES_CPA_MAINTENANCE_DETAIL"))
        XCTAssertTrue(rollback.contains("-name 'upgrade-*'"))
        XCTAssertTrue(rollback.contains("cli-proxy-api-run.sh"))
        XCTAssertTrue(rollback.contains("cpamp-run.sh"))
        XCTAssertTrue(rollback.contains("docker compose") == false)
    }

    func testNativeDeploymentUsesCurrentReleaseAssetAndSecretLayout() {
        let script = DeploymentExecutor().scriptForVerification(
            method: .native,
            installDirectory: "~/.oases-cpa"
        )

        XCTAssertTrue(script.contains("CPAMP_PACKAGE=\"cpa-manager-plus_${CPAMP_VERSION_TAG}_${RELEASE_OS}_${CPAMP_ARCH}\""))
        XCTAssertTrue(script.contains("CPAMP_VERSION_TAG=\"v1.11.10\""))
        XCTAssertTrue(script.contains("CPAMP_EXPECTED_SHA256="))
        XCTAssertTrue(script.contains("verify_fixed_archive \"$CPAMP_EXPECTED_SHA256\" \"$CPAMP_PACKAGE.tar.gz\" \"$CPAMP_ARCHIVE_PART\""))
        XCTAssertTrue(script.contains("\"adminKeyFile\": \"../../../secrets/cpamp-admin-key\""))
        XCTAssertTrue(script.contains("\"managementKeyFile\": \"../../../secrets/cpa-management-key\""))
        XCTAssertFalse(script.contains("cpa-manager-plus_${CPAMP_VERSION}_${RELEASE_OS}_${CPAMP_ARCH}"))
    }

    func testNativeDeploymentClosesCredentialPipesBeforeStartingLongRunningServices() {
        let script = DeploymentExecutor().scriptForVerification(
            method: .native,
            installDirectory: "~/.oases-cpa"
        )

        XCTAssertTrue(
            script.contains("exec 3>&- 4>&-"),
            "后台服务必须关闭部署进程的凭据/诊断描述符，否则 Swift Process 永远等不到 EOF"
        )
        XCTAssertTrue(script.contains("nohup \"$CLI_DIR/run.sh\""))
        XCTAssertTrue(script.contains("nohup \"$CPAMP_DIR/run.sh\""))
    }

    func testNativeDeploymentPersistsEveryStageAndPublishesOnlyVerifiedArchives() {
        let script = DeploymentExecutor().scriptForVerification(
            method: .native,
            installDirectory: "~/.oases-cpa",
            controlToken: "test-control-token"
        )

        XCTAssertTrue(script.contains("set_stage()"))
        XCTAssertTrue(script.contains("set_stage \"resolve-cli-version\""))
        XCTAssertTrue(script.contains("set_stage \"download-cli\""))
        XCTAssertTrue(script.contains("set_stage \"wait-cpamp\""))
        XCTAssertTrue(script.contains("stage=%s"))
        XCTAssertTrue(script.contains("pid=%s"))
        XCTAssertTrue(script.contains("control_token=%s"))
        XCTAssertTrue(script.contains("CONTROL_TOKEN='test-control-token'"))
        XCTAssertTrue(script.contains("trap deployment_cancelled TERM INT"))

        XCTAssertTrue(script.contains("CLI_ARCHIVE_PART=\"${CLI_ARCHIVE}.part\""))
        XCTAssertTrue(script.contains("CPAMP_ARCHIVE_PART=\"${CPAMP_ARCHIVE}.part\""))
        XCTAssertTrue(script.contains("tar -tzf \"$CLI_ARCHIVE_PART\""))
        XCTAssertTrue(script.contains("tar -tzf \"$CPAMP_ARCHIVE_PART\""))
        XCTAssertTrue(script.contains("mv \"$CLI_ARCHIVE_PART\" \"$CLI_ARCHIVE\""))
        XCTAssertTrue(script.contains("mv \"$CPAMP_ARCHIVE_PART\" \"$CPAMP_ARCHIVE\""))
        XCTAssertFalse(script.contains("-o \"$CLI_ARCHIVE\""))
        XCTAssertFalse(script.contains("-o \"$CPAMP_ARCHIVE\""))
    }

    func testDockerDeploymentPersistsStagesAndMarksOwnedPartialInstalls() {
        let script = DeploymentExecutor().scriptForVerification(
            method: .docker,
            installDirectory: "~/.oases-cpa",
            controlToken: "test-control-token"
        )

        XCTAssertTrue(script.contains("MANAGED_ROOT_MARKER=\"$INSTALL_ROOT/.oases-cpa-managed\""))
        XCTAssertTrue(script.contains("set_stage()"))
        XCTAssertTrue(script.contains("set_stage \"download-installer\""))
        XCTAssertTrue(script.contains("set_stage \"pull-containers\""))
        XCTAssertTrue(script.contains("set_stage \"finalize\""))
        XCTAssertTrue(script.contains("control_token=%s"))
        XCTAssertTrue(script.contains("CONTROL_TOKEN='test-control-token'"))
        XCTAssertTrue(script.contains("trap deployment_cancelled TERM INT"))
    }

    func testDeploymentProfileCanBeClearedForTargetRebinding() {
        let defaultsKey = "oases.cpa.deployment.profile"
        let previous = UserDefaults.standard.data(forKey: defaultsKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }

        DeploymentProfileStore.save(
            DeploymentProfile(
                targetKind: .ssh,
                deploymentMethod: .docker,
                remoteHost: "vps.example.com",
                remoteUser: "root",
                remotePort: "22",
                privateKeyPath: "/tmp/key",
                installDirectory: "~/.oases-cpa",
                isInstalled: true,
                lastAttachedAt: Date(timeIntervalSince1970: 1_730_000_000)
            )
        )

        let loaded = try? XCTUnwrap(DeploymentProfileStore.load())
        XCTAssertEqual(loaded?.targetKind, .ssh)
        XCTAssertEqual(loaded?.deploymentMethod, .docker)
        XCTAssertEqual(loaded?.remoteHost, "vps.example.com")
        XCTAssertEqual(loaded?.isInstalled, true)

        DeploymentProfileStore.clear()
        XCTAssertNil(DeploymentProfileStore.load())
    }

    func testDeploymentProfileStoreSupportsMultipleTargetsAndActiveSelection() {
        let legacyKey = "oases.cpa.deployment.profile"
        let profilesKey = "oases.cpa.deployment.profiles"
        let activeKey = "oases.cpa.deployment.active-profile"
        let previousLegacy = UserDefaults.standard.data(forKey: legacyKey)
        let previousProfiles = UserDefaults.standard.data(forKey: profilesKey)
        let previousActive = UserDefaults.standard.string(forKey: activeKey)
        defer {
            if let previousLegacy {
                UserDefaults.standard.set(previousLegacy, forKey: legacyKey)
            } else {
                UserDefaults.standard.removeObject(forKey: legacyKey)
            }
            if let previousProfiles {
                UserDefaults.standard.set(previousProfiles, forKey: profilesKey)
            } else {
                UserDefaults.standard.removeObject(forKey: profilesKey)
            }
            if let previousActive {
                UserDefaults.standard.set(previousActive, forKey: activeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: activeKey)
            }
        }

        DeploymentProfileStore.clear()
        let local = DeploymentProfile(
            targetKind: .local,
            deploymentMethod: .native,
            remoteHost: "",
            remoteUser: "root",
            remotePort: "22",
            privateKeyPath: "",
            installDirectory: "~/.oases-cpa-local",
            isInstalled: false,
            lastAttachedAt: nil
        )
        let remote = DeploymentProfile(
            targetKind: .ssh,
            deploymentMethod: .native,
            remoteHost: "vps.example.com",
            remoteUser: "deploy",
            remotePort: "2222",
            privateKeyPath: "/tmp/key",
            installDirectory: "~/.oases-cpa",
            isInstalled: true,
            lastAttachedAt: Date(timeIntervalSince1970: 1_730_000_000)
        )

        DeploymentProfileStore.save(local)
        DeploymentProfileStore.save(remote)
        XCTAssertEqual(DeploymentProfileStore.loadAll().map(\.id), [local.id, remote.id])
        XCTAssertEqual(DeploymentProfileStore.load()?.id, remote.id)

        DeploymentProfileStore.setActive(local.id)
        XCTAssertEqual(DeploymentProfileStore.load()?.id, local.id)
        DeploymentProfileStore.remove(local.id)
        XCTAssertEqual(DeploymentProfileStore.loadAll().map(\.id), [remote.id])
        XCTAssertEqual(DeploymentProfileStore.load()?.id, remote.id)
        DeploymentProfileStore.clear()
    }

    func testDeploymentProfileStoreRemovesDuplicateTargetsAfterAdoption() {
        let legacyKey = "oases.cpa.deployment.profile"
        let profilesKey = "oases.cpa.deployment.profiles"
        let activeKey = "oases.cpa.deployment.active-profile"
        let previousLegacy = UserDefaults.standard.data(forKey: legacyKey)
        let previousProfiles = UserDefaults.standard.data(forKey: profilesKey)
        let previousActive = UserDefaults.standard.string(forKey: activeKey)
        defer {
            if let previousLegacy { UserDefaults.standard.set(previousLegacy, forKey: legacyKey) }
            else { UserDefaults.standard.removeObject(forKey: legacyKey) }
            if let previousProfiles { UserDefaults.standard.set(previousProfiles, forKey: profilesKey) }
            else { UserDefaults.standard.removeObject(forKey: profilesKey) }
            if let previousActive { UserDefaults.standard.set(previousActive, forKey: activeKey) }
            else { UserDefaults.standard.removeObject(forKey: activeKey) }
        }

        DeploymentProfileStore.clear()
        let duplicate = DeploymentProfile(
            targetKind: .local,
            deploymentMethod: .native,
            remoteHost: "",
            remoteUser: "root",
            remotePort: "22",
            privateKeyPath: "",
            installDirectory: "~/.oases-cpa/",
            isInstalled: false,
            lastAttachedAt: nil
        )
        let adopted = DeploymentProfile(
            targetKind: .local,
            deploymentMethod: .native,
            remoteHost: "",
            remoteUser: "root",
            remotePort: "22",
            privateKeyPath: "",
            installDirectory: "~/.oases-cpa",
            isInstalled: true,
            lastAttachedAt: Date()
        )

        DeploymentProfileStore.save(duplicate)
        DeploymentProfileStore.save(adopted)

        XCTAssertEqual(DeploymentProfileStore.loadAll(), [adopted])
        XCTAssertEqual(DeploymentProfileStore.load()?.id, adopted.id)
    }

    func testUninstalledDraftCannotReplaceAnInstalledTargetAtTheSameLocation() {
        let legacyKey = "oases.cpa.deployment.profile"
        let profilesKey = "oases.cpa.deployment.profiles"
        let activeKey = "oases.cpa.deployment.active-profile"
        let previousLegacy = UserDefaults.standard.data(forKey: legacyKey)
        let previousProfiles = UserDefaults.standard.data(forKey: profilesKey)
        let previousActive = UserDefaults.standard.string(forKey: activeKey)
        defer {
            if let previousLegacy { UserDefaults.standard.set(previousLegacy, forKey: legacyKey) }
            else { UserDefaults.standard.removeObject(forKey: legacyKey) }
            if let previousProfiles { UserDefaults.standard.set(previousProfiles, forKey: profilesKey) }
            else { UserDefaults.standard.removeObject(forKey: profilesKey) }
            if let previousActive { UserDefaults.standard.set(previousActive, forKey: activeKey) }
            else { UserDefaults.standard.removeObject(forKey: activeKey) }
        }

        DeploymentProfileStore.clear()
        let installed = DeploymentProfile(
            targetKind: .local,
            deploymentMethod: .native,
            remoteHost: "",
            remoteUser: "root",
            remotePort: "22",
            privateKeyPath: "",
            installDirectory: "~/.oases-cpa",
            isInstalled: true,
            lastAttachedAt: Date()
        )
        let accidentalDraft = DeploymentProfile(
            targetKind: .local,
            deploymentMethod: .native,
            remoteHost: "",
            remoteUser: "root",
            remotePort: "22",
            privateKeyPath: "",
            installDirectory: "~/.oases-cpa/",
            isInstalled: false,
            lastAttachedAt: nil
        )

        DeploymentProfileStore.save(installed)
        let canonical = DeploymentProfileStore.save(accidentalDraft)

        XCTAssertEqual(canonical, installed)
        XCTAssertEqual(DeploymentProfileStore.loadAll(), [installed])
        XCTAssertEqual(DeploymentProfileStore.load()?.id, installed.id)
    }

    func testLifecycleStopScriptsPreserveInstallDirectoryAndStopManagedServices() {
        let lifecycle = RuntimeLifecycleService()
        let native = lifecycle.stopScriptForVerification(method: .native, installDirectory: "~/.oases-cpa")
        let docker = lifecycle.stopScriptForVerification(method: .docker, installDirectory: "~/.oases-cpa")

        XCTAssertTrue(native.contains("kill \"$pid\""))
        XCTAssertTrue(native.contains("ps -p \"$pid\" -o command="))
        XCTAssertTrue(native.contains("expected_root=\"$ROOT/cli-proxy-api\""))
        XCTAssertTrue(native.contains("rm -f \"$pid_file\""))
        XCTAssertTrue(docker.contains("docker compose stop"))
        XCTAssertFalse(native.contains("rm -rf"))
        XCTAssertFalse(docker.contains("docker compose down -v"))

        let recovery = DeploymentRecoveryService().scriptForVerification(
            method: .native,
            installDirectory: "~/.oases-cpa",
            backupName: "failed-test"
        )
        XCTAssertTrue(recovery.contains("managed_process()"))
        XCTAssertTrue(recovery.contains("ps -p \"$pid\" -o command="))
        XCTAssertTrue(recovery.contains("expected_root=\"$ROOT/cli-proxy-api\""))
    }

    func testNativeLifecycleDoesNotKillAnUnrelatedProcessFromAStalePIDFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oases-cpa-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("cli-proxy-api"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("cpamp"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() } }

        try Data("\(unrelated.processIdentifier)\n".utf8)
            .write(to: root.appendingPathComponent("cli-proxy-api.pid"))

        let result = try runShellScript(
            RuntimeLifecycleService().stopScriptForVerification(
                method: .native,
                installDirectory: root.path
            )
        )

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertTrue(unrelated.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cli-proxy-api.pid").path))
    }

    func testNativeDeploymentEndToEndWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["OASES_CPA_RUN_INTEGRATION"] == "1" else {
            throw XCTSkip("Set OASES_CPA_RUN_INTEGRATION=1 to download and run the official native packages.")
        }
        guard tcpPortIsAvailable(8317), tcpPortIsAvailable(18317) else {
            throw XCTSkip("Ports 8317 or 18317 are already in use; the temporary native stack will not disturb an existing CPA deployment.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oases-cpa-e2e-\(UUID().uuidString)")
        let executor = DeploymentExecutor()
        let lifecycle = RuntimeLifecycleService()

        defer {
            _ = try? runShellScript(
                lifecycle.stopScriptForVerification(method: .native, installDirectory: root.path)
            )
            try? FileManager.default.removeItem(at: root)
        }

        let execution = try runShellScript(
            executor.scriptForVerification(method: .native, installDirectory: root.path)
        )
        XCTAssertEqual(
            execution.status,
            0,
            "native deployment failed:\n\(execution.standardError)\n\(execution.standardOutput)"
        )

        let cpaKey = try readSecret(at: root.appendingPathComponent("secrets/cpa-management-key"))
        let cpampKey = try readSecret(at: root.appendingPathComponent("secrets/cpamp-admin-key"))

        try await RuntimeLifecycleService().waitForConnectionHealth(cpaManagementKey: cpaKey)
        let nativeHealthIsGood = await RuntimeLifecycleService().checkConnectionHealth(cpaManagementKey: cpaKey)
        XCTAssertTrue(
            nativeHealthIsGood,
            "后台健康检查应同时确认 CLIProxyAPI 与 CPAMP 可访问"
        )

        try await assertHTTPStatus(
            URL(string: "http://127.0.0.1:8317/v0/management/config")!,
            bearer: cpaKey,
            expected: 200
        )
        try await assertHTTPStatus(
            URL(string: "http://127.0.0.1:18317/health")!,
            expected: 200
        )
        try await assertHTTPStatus(
            URL(string: "http://127.0.0.1:18317/status")!,
            bearer: cpampKey,
            expected: 200
        )
        let managerConfig = try await ManagementAPIClient().managerConfig(
            baseURL: URL(string: "http://127.0.0.1:18317")!,
            managementKey: cpampKey
        )
        XCTAssertEqual(managerConfig.config.cpaConnection.cpaBaseURL, "http://127.0.0.1:8317")
        XCTAssertEqual(managerConfig.config.managementKey, cpaKey)
        try await assertCPAConfigYAMLRoundTrip(
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            managementKey: cpaKey
        )
        try await assertQuotaManagementContract(
            cpaBaseURL: URL(string: "http://127.0.0.1:8317")!,
            cpaManagementKey: cpaKey,
            cpampBaseURL: URL(string: "http://127.0.0.1:18317")!,
            cpampAdminKey: cpampKey
        )
        let sevenDayDashboard = try await ManagementAPIClient().dashboardSummary(
            baseURL: URL(string: "http://127.0.0.1:18317")!,
            managementKey: cpampKey,
            range: .sevenDays
        )
        XCTAssertGreaterThan(sevenDayDashboard.generatedAtMs, 0)
        XCTAssertGreaterThanOrEqual(sevenDayDashboard.today.totalCalls, 0)
        let savedManagerConfig = try await ManagementAPIClient().saveManagerConfig(
            managerConfig.config,
            baseURL: URL(string: "http://127.0.0.1:18317")!,
            managementKey: cpampKey
        )
        XCTAssertEqual(savedManagerConfig.config.cpaConnection.cpaBaseURL, "http://127.0.0.1:8317")
        XCTAssertEqual(savedManagerConfig.config.managementKey, cpaKey)
        try await ManagementAPIClient().setLoggingToFile(
            true,
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            managementKey: cpaKey
        )
        let logs = try await ManagementAPIClient().logs(
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            managementKey: cpaKey
        )
        XCTAssertGreaterThanOrEqual(logs.lineCount, logs.lines.count)
        let providers = try await ManagementAPIClient().openAICompatibility(
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            managementKey: cpaKey
        )
        XCTAssertGreaterThanOrEqual(providers.providers.count, 0)
        try await assertOpenAICompatibilityCRUD(
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            managementKey: cpaKey,
            originalProviders: providers.providers
        )
        try await assertAuthFileCRUD(
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            managementKey: cpaKey
        )
        try await assertGatewayAPIKeyCRUD(
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            managementKey: cpaKey
        )
        try await assertHTTPStatus(
            URL(string: "http://127.0.0.1:18317/management.html")!,
            expected: 200
        )

        let oauth = try await ManagementAPIClient().oauthStart(
            provider: .codex,
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            managementKey: cpaKey
        )
        XCTAssertTrue(oauth.url.hasPrefix("http"))
        let oauthState = try XCTUnwrap(oauth.state)
        let oauthWaiting = try await ManagementAPIClient().oauthStatus(
            state: oauthState,
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            managementKey: cpaKey
        )
        XCTAssertEqual(oauthWaiting.status, .wait)
        try await ManagementAPIClient().cancelOAuth(
            state: oauthState,
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            managementKey: cpaKey
        )

        let maintenanceRequest = DeploymentExecutionRequest(
            target: .local,
            method: .native,
            host: "",
            user: NSUserName(),
            port: "22",
            privateKeyPath: "",
            installDirectory: root.path
        )
        let maintenance = DeploymentMaintenanceService()
        let upgrade = try await maintenance.upgrade(request: maintenanceRequest)
        XCTAssertTrue(upgrade.backupName.hasPrefix("upgrade-"))
        XCTAssertFalse(upgrade.detail.isEmpty)
        try await RuntimeLifecycleService().waitForConnectionHealth(cpaManagementKey: cpaKey)

        let rollback = try await maintenance.rollback(request: maintenanceRequest)
        XCTAssertEqual(rollback.backupName, upgrade.backupName)
        XCTAssertFalse(rollback.detail.isEmpty)
        try await RuntimeLifecycleService().waitForConnectionHealth(cpaManagementKey: cpaKey)
    }

    func testDockerDeploymentEndToEndWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["OASES_CPA_RUN_DOCKER_INTEGRATION"] == "1" else {
            throw XCTSkip("Set OASES_CPA_RUN_DOCKER_INTEGRATION=1 to download the official installer and start a temporary Compose stack.")
        }
        let dockerPath = "/usr/local/bin/docker"
        guard FileManager.default.isExecutableFile(atPath: dockerPath) else {
            throw XCTSkip("Docker CLI is unavailable at /usr/local/bin/docker.")
        }
        let dockerInfo = try runCommand(dockerPath, arguments: ["info"])
        guard dockerInfo.status == 0 else {
            throw XCTSkip("Docker daemon is unavailable: \(dockerInfo.standardError.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard tcpPortIsAvailable(8317), tcpPortIsAvailable(18317) else {
            throw XCTSkip("Ports 8317 or 18317 are already in use; the temporary Docker stack will not disturb them.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oases-cpa-docker-e2e-\(UUID().uuidString)")
        let executor = DeploymentExecutor()
        let lifecycle = RuntimeLifecycleService()

        defer {
            let composeFile = root.appendingPathComponent("compose.yaml")
            if FileManager.default.fileExists(atPath: composeFile.path) {
                _ = try? runCommand(
                    dockerPath,
                    arguments: [
                        "compose",
                        "-f",
                        composeFile.path,
                        "down",
                        "-v",
                        "--remove-orphans"
                    ]
                )
            }
            _ = try? runShellScript(
                lifecycle.stopScriptForVerification(method: .docker, installDirectory: root.path)
            )
            try? FileManager.default.removeItem(at: root)
        }

        let execution = try runShellScript(
            executor.scriptForVerification(method: .docker, installDirectory: root.path)
        )
        XCTAssertEqual(
            execution.status,
            0,
            "Docker deployment failed:\n\(execution.standardError)\n\(execution.standardOutput)\n\(deploymentLogDiagnostic(root: root))"
        )
        guard execution.status == 0 else { return }

        let cpaKey = try readSecret(at: root.appendingPathComponent("secrets/cpa-management-key"))
        let cpampKey = try readSecret(at: root.appendingPathComponent("secrets/cpamp-admin-key"))

        try await RuntimeLifecycleService().waitForConnectionHealth(cpaManagementKey: cpaKey)
        let dockerHealthIsGood = await RuntimeLifecycleService().checkConnectionHealth(cpaManagementKey: cpaKey)
        XCTAssertTrue(
            dockerHealthIsGood,
            "Docker 部署的后台健康检查应同时确认 CLIProxyAPI 与 CPAMP 可访问"
        )
        try await assertHTTPStatus(
            URL(string: "http://127.0.0.1:8317/v0/management/config")!,
            bearer: cpaKey,
            expected: 200
        )
        try await assertHTTPStatus(
            URL(string: "http://127.0.0.1:18317/health")!,
            expected: 200
        )
        try await assertHTTPStatus(
            URL(string: "http://127.0.0.1:18317/status")!,
            bearer: cpampKey,
            expected: 200
        )
        let managerConfig = try await ManagementAPIClient().managerConfig(
            baseURL: URL(string: "http://127.0.0.1:18317")!,
            managementKey: cpampKey
        )
        XCTAssertEqual(managerConfig.config.cpaConnection.cpaBaseURL, "http://cli-proxy-api:8317")
        XCTAssertEqual(managerConfig.config.managementKey, cpaKey)
        try await assertCPAConfigYAMLRoundTrip(
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            managementKey: cpaKey
        )
        try await assertQuotaManagementContract(
            cpaBaseURL: URL(string: "http://127.0.0.1:8317")!,
            cpaManagementKey: cpaKey,
            cpampBaseURL: URL(string: "http://127.0.0.1:18317")!,
            cpampAdminKey: cpampKey
        )
        try await assertAuthFileCRUD(
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            managementKey: cpaKey
        )
        try await assertGatewayAPIKeyCRUD(
            baseURL: URL(string: "http://127.0.0.1:8317")!,
            managementKey: cpaKey
        )
        try await assertHTTPStatus(
            URL(string: "http://127.0.0.1:18317/management.html")!,
            expected: 200
        )
    }

    func testSSHNativeDeploymentEndToEndWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["OASES_CPA_RUN_SSH_INTEGRATION"] == "1" else {
            throw XCTSkip("Set OASES_CPA_RUN_SSH_INTEGRATION=1 to start an isolated local sshd and run the SSH deployment path.")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/sbin/sshd") else {
            throw XCTSkip("/usr/sbin/sshd is unavailable on this Mac.")
        }
        guard tcpPortIsAvailable(8317), tcpPortIsAvailable(18317) else {
            throw XCTSkip("Ports 8317 or 18317 are already in use; the isolated SSH tunnel test will not disturb them.")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oases-cpa-ssh-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let user = NSUserName()
        let clientKey = root.appendingPathComponent("client_key")
        let hostKey = root.appendingPathComponent("host_key")
        let authorizedKeys = root.appendingPathComponent("authorized_keys")
        let sshdConfig = root.appendingPathComponent("sshd_config")
        let sshdLog = root.appendingPathComponent("sshd.log")
        let sshdPid = root.appendingPathComponent("sshd.pid")
        let remoteRoot = root.appendingPathComponent("remote-install")

        var sshd: Process?
        var tunnel: Process?
        var request: DeploymentExecutionRequest?
        var knownHostsPath: String?
        var originalKnownHosts: Data?

        do {
            let knownHostArguments = try SSHConnectionService.connectionArguments(
                port: "22",
                privateKeyPath: clientKey.path
            )
            knownHostsPath = knownHostArguments
                .first(where: { $0.hasPrefix("UserKnownHostsFile=") })
                .map { String($0.dropFirst("UserKnownHostsFile=".count)) }
            if let knownHostsPath {
                originalKnownHosts = try Data(contentsOf: URL(fileURLWithPath: knownHostsPath))
            }

            let clientKeyResult = try runCommand(
                "/usr/bin/ssh-keygen",
                arguments: ["-q", "-t", "ed25519", "-N", "", "-f", clientKey.path]
            )
            XCTAssertEqual(clientKeyResult.status, 0, clientKeyResult.standardError)
            guard clientKeyResult.status == 0 else {
                throw commandFailure("生成 SSH 客户端密钥", result: clientKeyResult)
            }

            let hostKeyResult = try runCommand(
                "/usr/bin/ssh-keygen",
                arguments: ["-q", "-t", "ed25519", "-N", "", "-f", hostKey.path]
            )
            XCTAssertEqual(hostKeyResult.status, 0, hostKeyResult.standardError)
            guard hostKeyResult.status == 0 else {
                throw commandFailure("生成 sshd 主机密钥", result: hostKeyResult)
            }

            let publicKey = try String(contentsOf: URL(fileURLWithPath: clientKey.path + ".pub"), encoding: .utf8)
            try publicKey.write(to: authorizedKeys, atomically: true, encoding: .utf8)
            let permitRootLogin = user == "root" ? "yes" : "no"
            let port = try freeTCPPort()
            let config = """
            Port \(port)
            ListenAddress 127.0.0.1
            HostKey \(hostKey.path)
            PidFile \(sshdPid.path)
            AuthorizedKeysFile \(authorizedKeys.path)
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            ChallengeResponseAuthentication no
            PubkeyAuthentication yes
            UsePAM no
            PermitRootLogin \(permitRootLogin)
            StrictModes no
            AllowUsers \(user)
            AllowTcpForwarding yes
            GatewayPorts no
            X11Forwarding no
            PrintMotd no
            LogLevel ERROR
            """
            try config.write(to: sshdConfig, atomically: true, encoding: .utf8)

            for file in [clientKey, hostKey, authorizedKeys, sshdConfig] {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: file.path
                )
            }
            FileManager.default.createFile(
                atPath: sshdLog.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )

            let validation = try runCommand(
                "/usr/sbin/sshd",
                arguments: ["-t", "-f", sshdConfig.path]
            )
            XCTAssertEqual(validation.status, 0, validation.standardError)
            guard validation.status == 0 else {
                throw commandFailure("校验隔离 sshd 配置", result: validation)
            }

            let sshdProcess = Process()
            sshdProcess.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
            sshdProcess.arguments = ["-D", "-e", "-f", sshdConfig.path]
            let sshdLogHandle = FileHandle(forWritingAtPath: sshdLog.path)
            sshdProcess.standardOutput = sshdLogHandle
            sshdProcess.standardError = sshdLogHandle
            try sshdProcess.run()
            sshd = sshdProcess

            let sshArguments = try SSHConnectionService.connectionArguments(
                port: String(port),
                privateKeyPath: clientKey.path
            )
            let target = "\(user)@127.0.0.1"
            try await waitForSSHConnection(
                process: sshdProcess,
            let hostKeyInspection = try SSHConnectionService.inspectHostKey(
                host: "127.0.0.1",
                port: String(port)
            )
            if case .needsConfirmation(let confirmation) = hostKeyInspection {
                try SSHConnectionService.confirmHostKey(confirmation)
            }
                arguments: sshArguments,
                target: target,
                logURL: sshdLog
            )

            let executionRequest = DeploymentExecutionRequest(
                target: .ssh,
                method: .native,
                host: "127.0.0.1",
                user: user,
                port: String(port),
                privateKeyPath: clientKey.path,
                installDirectory: remoteRoot.path
            )
            request = executionRequest
            let execution = try await DeploymentExecutor().execute(request: executionRequest)
            XCTAssertTrue(execution.cpaManagementKey.hasPrefix("cpa_"))
            XCTAssertTrue(execution.cpampAdminKey.hasPrefix("cpamp_"))

            let tunnelProcess = Process()
            tunnelProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            tunnelProcess.arguments = try SSHConnectionService.tunnelArguments(
                host: "127.0.0.1",
                user: user,
                port: String(port),
                privateKeyPath: clientKey.path
            )
            let nullDevice = FileHandle(forWritingAtPath: "/dev/null")
            tunnelProcess.standardOutput = nullDevice
            tunnelProcess.standardError = nullDevice
            try tunnelProcess.run()
            tunnel = tunnelProcess
            try await Task.sleep(nanoseconds: 500_000_000)
            guard tunnelProcess.isRunning else {
                throw NSError(
                    domain: "OasesCPASSHIntegration",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "SSH 隧道进程未能保持运行。"]
                )
            }

            try await RuntimeLifecycleService().waitForConnectionHealth(
                cpaManagementKey: execution.cpaManagementKey
            )
            let sshHealthIsGood = await RuntimeLifecycleService().checkConnectionHealth(
                cpaManagementKey: execution.cpaManagementKey
            )
            XCTAssertTrue(
                sshHealthIsGood,
                "SSH 隧道下的后台健康检查应确认转发后的 CLIProxyAPI 与 CPAMP 可访问"
            )
            try await assertHTTPStatus(
                URL(string: "http://127.0.0.1:8317/v0/management/config")!,
                bearer: execution.cpaManagementKey,
                expected: 200
            )
            try await assertHTTPStatus(
                URL(string: "http://127.0.0.1:18317/health")!,
                expected: 200
            )
            try await assertHTTPStatus(
                URL(string: "http://127.0.0.1:18317/status")!,
                bearer: execution.cpampAdminKey,
                expected: 200
            )
            let managerConfig = try await ManagementAPIClient().managerConfig(
                baseURL: URL(string: "http://127.0.0.1:18317")!,
                managementKey: execution.cpampAdminKey
            )
            XCTAssertEqual(managerConfig.config.cpaConnection.cpaBaseURL, "http://127.0.0.1:8317")
            XCTAssertEqual(managerConfig.config.managementKey, execution.cpaManagementKey)
            try await assertCPAConfigYAMLRoundTrip(
                baseURL: URL(string: "http://127.0.0.1:8317")!,
                managementKey: execution.cpaManagementKey
            )
            try await assertQuotaManagementContract(
                cpaBaseURL: URL(string: "http://127.0.0.1:8317")!,
                cpaManagementKey: execution.cpaManagementKey,
                cpampBaseURL: URL(string: "http://127.0.0.1:18317")!,
                cpampAdminKey: execution.cpampAdminKey
            )
            try await assertAuthFileCRUD(
                baseURL: URL(string: "http://127.0.0.1:8317")!,
                managementKey: execution.cpaManagementKey
            )
            try await assertGatewayAPIKeyCRUD(
                baseURL: URL(string: "http://127.0.0.1:8317")!,
                managementKey: execution.cpaManagementKey
            )
            try await assertHTTPStatus(
                URL(string: "http://127.0.0.1:18317/management.html")!,
                expected: 200
            )
        } catch {
            await cleanupSSHFixture(
                request: request,
                lifecycle: RuntimeLifecycleService(),
                tunnel: tunnel,
                sshd: sshd,
                knownHostsPath: knownHostsPath,
                originalKnownHosts: originalKnownHosts,
                root: root
            )
            throw error
        }

        await cleanupSSHFixture(
            request: request,
            lifecycle: RuntimeLifecycleService(),
            tunnel: tunnel,
            sshd: sshd,
            knownHostsPath: knownHostsPath,
            originalKnownHosts: originalKnownHosts,
            root: root
        )
    }

    func testDeploymentProbeParsesMethodSpecificPrerequisites() {
        let output = """
        os=Darwin
        arch=arm64
        shell=/bin/zsh
        curl=/usr/bin/curl
        tar=/usr/bin/tar
        openssl=/usr/bin/openssl
        sha256=/usr/bin/shasum
        docker=/usr/local/bin/docker
        docker_compose=yes
        docker_daemon=no
        install_writable=yes
        """

        let probe = DeploymentProbeService().parseForVerification(
            output,
            installDirectory: "~/.oases-cpa"
        )

        XCTAssertTrue(probe.missingDependencies(for: .native).isEmpty)
        XCTAssertEqual(
            probe.missingDependencies(for: .docker),
            ["运行中的 Docker daemon"]
        )
    }

    func testDeploymentProbeRecognizesAnAdoptableManagedDeployment() {
        let probe = DeploymentProbeService().parseForVerification(
            """
            os=Darwin
            arch=arm64
            shell=/bin/zsh
            curl=/usr/bin/curl
            tar=/usr/bin/tar
            openssl=/usr/bin/openssl
            sha256=/usr/bin/shasum
            docker=
            docker_compose=no
            docker_daemon=no
            install_writable=yes
            managed_root=yes
            managed_install=yes
            managed_credentials=yes
            managed_native_runtime=yes
            managed_docker_runtime=no
            """,
            installDirectory: "~/.oases-cpa"
        )

        XCTAssertTrue(probe.hasManagedRoot)
        XCTAssertTrue(probe.hasManagedInstallation)
        XCTAssertTrue(probe.hasRecoverableCredentials)
        XCTAssertTrue(probe.canAdopt(method: .native))
        XCTAssertFalse(probe.canAdopt(method: .docker))
    }

    func testExistingManagedDeploymentCanRestoreItsCredentials() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oases-cpa-adoption-\(UUID().uuidString)")
        let secrets = root.appendingPathComponent("secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".oases-cpa-installed"))
        try Data("cpa_test_management\n".utf8).write(to: secrets.appendingPathComponent("cpa-management-key"))
        try Data("cpamp_test_admin\n".utf8).write(to: secrets.appendingPathComponent("cpamp-admin-key"))
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try await ExistingDeploymentAdoptionService().readCredentials(
            request: DeploymentExecutionRequest(
                target: .local,
                method: .native,
                host: "",
                user: "root",
                port: "22",
                privateKeyPath: "",
                installDirectory: root.path
            )
        )

        XCTAssertEqual(result.cpaManagementKey, "cpa_test_management")
        XCTAssertEqual(result.cpampAdminKey, "cpamp_test_admin")
    }

    func testExistingDeploymentAdoptionRejectsSymlinkedCredentials() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oases-cpa-adoption-symlink-\(UUID().uuidString)")
        let secrets = root.appendingPathComponent("secrets", isDirectory: true)
        let externalSecret = root.appendingPathComponent("external-secret")
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".oases-cpa-installed"))
        try Data("cpa_external\n".utf8).write(to: externalSecret)
        try FileManager.default.createSymbolicLink(
            at: secrets.appendingPathComponent("cpa-management-key"),
            withDestinationURL: externalSecret
        )
        try Data("cpamp_test_admin\n".utf8).write(to: secrets.appendingPathComponent("cpamp-admin-key"))
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await ExistingDeploymentAdoptionService().readCredentials(
                request: DeploymentExecutionRequest(
                    target: .local,
                    method: .native,
                    host: "",
                    user: "root",
                    port: "22",
                    privateKeyPath: "",
                    installDirectory: root.path
                )
            )
            XCTFail("Symlinked credentials must not be adopted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("凭据"))
        }
    }

    func testDeploymentProbeTreatsMissingCommandOutputAsUnavailable() {
        let probe = DeploymentProbeService().parseForVerification(
            """
            os=Linux
            arch=x86_64
            shell=/bin/bash
            curl=
            tar=/usr/bin/tar
            openssl=/usr/bin/openssl
            sha256=
            docker=
            docker_compose=no
            docker_daemon=no
            install_writable=no
            """,
            installDirectory: "/srv/oases-cpa"
        )

        XCTAssertEqual(
            probe.missingDependencies(for: .native),
            ["curl", "shasum / sha256sum", "可写的安装目录"]
        )
        XCTAssertEqual(
            probe.missingDependencies(for: .docker),
            ["curl", "Docker CLI", "Docker Compose", "运行中的 Docker daemon", "可写的安装目录"]
        )
    }

    func testSSHConnectionUsesAnAppScopedKnownHostsFile() throws {
        let arguments = try SSHConnectionService.connectionArguments(
            port: "2222",
            privateKeyPath: "/tmp/oases-cpa-test-key"
        )

        XCTAssertEqual(
            arguments.filter { $0.hasPrefix("StrictHostKeyChecking=") },
            ["StrictHostKeyChecking=yes"]
        )
        XCTAssertFalse(arguments.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertTrue(arguments.contains(where: { $0.hasPrefix("UserKnownHostsFile=") }))
        XCTAssertTrue(arguments.contains("-p"))
        XCTAssertTrue(arguments.contains("2222"))
        XCTAssertTrue(arguments.contains("-i"))
        XCTAssertTrue(arguments.contains("/tmp/oases-cpa-test-key"))

        let knownHostsPath = try SSHConnectionService.prepareKnownHostsFile()
        XCTAssertTrue(knownHostsPath.hasSuffix("Oases CPA/SSH/known_hosts"))
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: knownHostsPath))
    }

    func testSSHKeyMaterialIsScopedPerDeploymentProfile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("oases-cpa-ssh-keys-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let profileA = UUID()
        let profileB = UUID()
        let sourceA = root.appendingPathComponent("key-a")
        let sourceB = root.appendingPathComponent("key-b")
        try Data("private-key-a".utf8).write(to: sourceA)
        try Data("private-key-b".utf8).write(to: sourceB)

        defer {
            try? SSHKeyMaterialStore.delete(profileID: profileA)
            try? SSHKeyMaterialStore.delete(profileID: profileB)
            try? FileManager.default.removeItem(at: root)
        }

        let materializedA = try SSHKeyMaterialStore.save(from: sourceA, profileID: profileA)
        let materializedB = try SSHKeyMaterialStore.save(from: sourceB, profileID: profileB)

        XCTAssertNotEqual(materializedA, materializedB)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: materializedA)), Data("private-key-a".utf8))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: materializedB)), Data("private-key-b".utf8))
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: materializedA)[.posixPermissions] as? NSNumber,
            NSNumber(value: 0o600)
        )
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: materializedB)[.posixPermissions] as? NSNumber,
            NSNumber(value: 0o600)
        )
    }

    func testSSHErrorsBecomeActionableChineseDiagnostics() {
        XCTAssertTrue(
            SSHConnectionService.userFacingError(
                "Host key verification failed.",
                fallback: "fallback"
            ).contains("主机指纹")
        )
        XCTAssertTrue(
            SSHConnectionService.userFacingError(
                "Permission denied (publickey).",
                fallback: "fallback"
            ).contains("公钥认证")
        )
        XCTAssertEqual(
            SSHConnectionService.userFacingError("", fallback: "fallback"),
            "fallback"
        )
    }

    func testDeploymentProbeCommandRunsLocally() throws {
        let command = DeploymentProbeService().commandForVerification(
            installDirectory: "/tmp/oases-cpa-preflight-\(UUID().uuidString)"
        )
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let diagnostic = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
        XCTAssertTrue(output.contains("os="))
        XCTAssertTrue(output.contains("arch="))
        XCTAssertTrue(output.contains("curl="))
        XCTAssertTrue(output.contains("install_writable="))
    }

    func testNativeDeploymentRecoversAStaleAttemptAndKeepsEarlyFailureDiagnostics() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oases CPA Retry \(UUID().uuidString)")
        let oldLogs = root.appendingPathComponent("logs")
        let fakeBin = root.appendingPathComponent("fake-bin")
        try FileManager.default.createDirectory(at: oldLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try Data("timestamp=2026-08-02T09:00:00Z\nstage=download-cli\n".utf8)
            .write(to: root.appendingPathComponent(".oases-cpa-failed"))
        try Data("previous attempt\n".utf8)
            .write(to: oldLogs.appendingPathComponent("deployment.log"))

        let fakeCurl = fakeBin.appendingPathComponent("curl")
        try Data("#!/bin/bash\nprintf '%s\\n' 'simulated download failure' >&2\nexit 22\n".utf8)
            .write(to: fakeCurl)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCurl.path)
        defer { try? FileManager.default.removeItem(at: root) }

        var script = DeploymentExecutor().scriptForVerification(
            method: .native,
            installDirectory: root.path
        )
        script = "PATH='\(fakeBin.path)':$PATH\n" + script
        script = script.replacingOccurrences(of: "for attempt in 1 2 3 4; do", with: "for attempt in 1; do")
        script = script.replacingOccurrences(of: "[ \"$attempt\" -lt 4 ] || return 1", with: "[ \"$attempt\" -lt 1 ] || return 1")
        let result = try runShellScript(script)
        let producedPaths = (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []
        let diagnostic = "status=\(result.status)\nstdout=\(result.standardOutput)\nstderr=\(result.standardError)\npaths=\(producedPaths)"

        XCTAssertNotEqual(result.status, 12, "旧失败标记不应把用户永久锁在重试之外")
        XCTAssertTrue(result.standardError.contains("simulated download failure"), diagnostic)
        let currentLog = root.appendingPathComponent("logs/deployment.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentLog.path), diagnostic)
        let currentLogText = try String(contentsOf: currentLog, encoding: .utf8)
        XCTAssertTrue(currentLogText.contains("simulated download failure"), currentLogText)
        XCTAssertTrue(currentLogText.contains("resolve-cli-version"), currentLogText)

        let backups = root.appendingPathComponent("backups")
        let backupNames = try FileManager.default.contentsOfDirectory(atPath: backups.path)
        let recoveryName = try XCTUnwrap(backupNames.first(where: { $0.hasPrefix("auto-recovery-") }))
        let recoveredRoot = backups.appendingPathComponent(recoveryName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredRoot.appendingPathComponent(".oases-cpa-failed").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredRoot.appendingPathComponent("logs/deployment.log").path))
    }

    func testNativeDeploymentRecoversAnOwnedPartialInstallEvenWhenAttemptMarkerWasLost() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oases CPA Managed Retry \(UUID().uuidString)")
        let staleRuntime = root.appendingPathComponent("cli-proxy-api")
        let fakeBin = root.appendingPathComponent("fake-bin")
        try FileManager.default.createDirectory(at: staleRuntime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try Data("owned-by=oases-cpa\n".utf8)
            .write(to: root.appendingPathComponent(".oases-cpa-managed"))
        try Data("partial archive\n".utf8)
            .write(to: staleRuntime.appendingPathComponent("leftover.txt"))

        let fakeCurl = fakeBin.appendingPathComponent("curl")
        try Data("#!/bin/bash\nprintf '%s\\n' 'simulated managed retry failure' >&2\nexit 22\n".utf8)
            .write(to: fakeCurl)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCurl.path)
        defer { try? FileManager.default.removeItem(at: root) }

        var script = DeploymentExecutor().scriptForVerification(
            method: .native,
            installDirectory: root.path
        )
        script = "PATH='\(fakeBin.path)':$PATH\n" + script
        script = script.replacingOccurrences(of: "for attempt in 1 2 3 4; do", with: "for attempt in 1; do")
        script = script.replacingOccurrences(of: "[ \"$attempt\" -lt 4 ] || return 1", with: "[ \"$attempt\" -lt 1 ] || return 1")
        let result = try runShellScript(script)

        XCTAssertNotEqual(result.status, 12, result.standardError)
        XCTAssertTrue(result.standardError.contains("simulated managed retry failure"), result.standardError)
        let backupRoot = root.appendingPathComponent("backups")
        let backupNames = try FileManager.default.contentsOfDirectory(atPath: backupRoot.path)
        let recoveryName = try XCTUnwrap(backupNames.first(where: { $0.hasPrefix("auto-recovery-") }))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: backupRoot
                    .appendingPathComponent(recoveryName)
                    .appendingPathComponent("cli-proxy-api/leftover.txt")
                    .path
            )
        )
    }

    func testNativeDeploymentStillProtectsAnUnownedPreexistingRuntime() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oases CPA Unowned Runtime \(UUID().uuidString)")
        let runtime = root.appendingPathComponent("cli-proxy-api")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try Data("user data\n".utf8).write(to: runtime.appendingPathComponent("keep.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runShellScript(
            DeploymentExecutor().scriptForVerification(
                method: .native,
                installDirectory: root.path
            )
        )

        XCTAssertEqual(result.status, 12, result.standardError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.appendingPathComponent("keep.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("backups").path))
    }

    func testNativeDeploymentDoesNotClaimAUserDirectoryContainingLogsOrSecrets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oases CPA Unowned User Directory \(UUID().uuidString)")
        let logs = root.appendingPathComponent("logs")
        let secrets = root.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        try Data("keep me\n".utf8).write(to: logs.appendingPathComponent("user.log"))
        try Data("private\n".utf8).write(to: secrets.appendingPathComponent("user-secret"))
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runShellScript(
            DeploymentExecutor().scriptForVerification(
                method: .native,
                installDirectory: root.path
            )
        )

        XCTAssertEqual(result.status, 12, result.standardError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: logs.appendingPathComponent("user.log").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secrets.appendingPathComponent("user-secret").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".oases-cpa-managed").path))
    }

    func testDockerDeploymentDoesNotClaimAUserDirectoryContainingOrdinaryFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oases CPA Docker Unowned Directory \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let userFile = root.appendingPathComponent("notes.txt")
        try Data("keep me\n".utf8).write(to: userFile)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runShellScript(
            DeploymentExecutor().scriptForVerification(
                method: .docker,
                installDirectory: root.path
            )
        )

        XCTAssertEqual(result.status, 12, result.standardError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".oases-cpa-managed").path))
    }

    func testNativeDeploymentLogIncludesAttemptLogAndFailureMarker() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oases CPA Log \(UUID().uuidString)")
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("download failed before services started\n".utf8)
            .write(to: logs.appendingPathComponent("deployment.log"))
        try Data("timestamp=2026-08-02T09:00:00Z\nstage=download-cli\nexit_status=22\n".utf8)
            .write(to: root.appendingPathComponent(".oases-cpa-failed"))
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try runShellScript(
            DeploymentLogService().scriptForVerification(
                method: .native,
                installDirectory: root.path
            )
        )

        XCTAssertEqual(result.status, 0, result.standardError)
        XCTAssertTrue(result.standardOutput.contains("logs/deployment.log"), result.standardOutput)
        XCTAssertTrue(result.standardOutput.contains("download failed before services started"), result.standardOutput)
        XCTAssertTrue(result.standardOutput.contains(".oases-cpa-failed"), result.standardOutput)
        XCTAssertTrue(result.standardOutput.contains("stage=download-cli"), result.standardOutput)
        XCTAssertFalse(result.standardOutput.contains("尚未找到 Oases CPA 日志"), result.standardOutput)
    }

    func testDockerDeploymentRecoversAStaleAttemptAndLogsInstallerDownloadFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oases CPA Docker Retry \(UUID().uuidString)")
        let oldLogs = root.appendingPathComponent("logs")
        let fakeBin = root.appendingPathComponent("fake-bin")
        try FileManager.default.createDirectory(at: oldLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try Data("timestamp=2026-08-02T09:00:00Z\nmethod=docker\nstage=download-installer\n".utf8)
            .write(to: root.appendingPathComponent(".oases-cpa-failed"))
        try Data("previous docker attempt\n".utf8)
            .write(to: oldLogs.appendingPathComponent("deployment.log"))

        let fakeCurl = fakeBin.appendingPathComponent("curl")
        try Data("#!/bin/bash\nprintf '%s\\n' 'simulated installer download failure' >&2\nexit 22\n".utf8)
            .write(to: fakeCurl)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCurl.path)
        let fakeDocker = fakeBin.appendingPathComponent("docker")
        try Data("#!/bin/bash\nexit 0\n".utf8).write(to: fakeDocker)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDocker.path)
        defer { try? FileManager.default.removeItem(at: root) }

        var script = DeploymentExecutor().scriptForVerification(
            method: .docker,
            installDirectory: root.path
        )
        script = "PATH='\(fakeBin.path)':$PATH\n" + script
        script = script.replacingOccurrences(of: "for attempt in 1 2 3 4; do", with: "for attempt in 1; do")
        script = script.replacingOccurrences(of: "[ \"$attempt\" -lt 4 ] || return 1", with: "[ \"$attempt\" -lt 1 ] || return 1")

        let result = try runShellScript(script)

        XCTAssertNotEqual(result.status, 12, result.standardError)
        XCTAssertTrue(result.standardError.contains("simulated installer download failure"), result.standardError)
        let currentLog = root.appendingPathComponent("logs/deployment.log")
        let currentLogText = try String(contentsOf: currentLog, encoding: .utf8)
        XCTAssertTrue(currentLogText.contains("simulated installer download failure"), currentLogText)
        XCTAssertTrue(currentLogText.contains("download-installer"), currentLogText)
        let backupNames = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("backups").path)
        let recoveryName = try XCTUnwrap(backupNames.first(where: { $0.hasPrefix("auto-recovery-") }))
        let recoveredRoot = root.appendingPathComponent("backups").appendingPathComponent(recoveryName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredRoot.appendingPathComponent(".oases-cpa-failed").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recoveredRoot.appendingPathComponent("logs/deployment.log").path))
    }

    func testFailedDeploymentRecoveryMovesGeneratedFilesIntoBackup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Oases CPA Recovery \(UUID().uuidString)")
        let logs = root.appendingPathComponent("logs")
        let secrets = root.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("cli-proxy-api"),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: root.appendingPathComponent(".oases-cpa-failed").path,
            contents: Data("failed\n".utf8)
        )

        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["30"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() } }
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("cli-proxy-api.pid").path,
            contents: Data("\(unrelated.processIdentifier)\n".utf8)
        )
        FileManager.default.createFile(
            atPath: logs.appendingPathComponent("cli-proxy-api.log").path,
            contents: Data("deployment failed\n".utf8)
        )

        defer { try? FileManager.default.removeItem(at: root) }

        let service = DeploymentRecoveryService()
        let script = service.scriptForVerification(
            method: .native,
            installDirectory: root.path,
            backupName: "failed-test"
        )
        let process = Process()
        let input = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-s"]
        process.standardInput = input
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let diagnostic = String(
            data: error.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)

        let backup = root.appendingPathComponent("backups/failed-test")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("cli-proxy-api").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("logs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent("secrets").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cli-proxy-api").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".oases-cpa-failed").path))
        XCTAssertTrue(unrelated.isRunning, "恢复脚本不得按陈旧 PID 误杀非 Oases CPA 进程")
    }

    private func assertBashSyntax(_ script: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", "-s"]
        process.standardInput = input
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let diagnostic = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, diagnostic, file: file, line: line)
    }

    private func runShellScript(_ script: String) throws -> (status: Int32, standardOutput: String, standardError: String) {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-s"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func readSecret(at url: URL) throws -> String {
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(value.isEmpty)
        return value
    }

    private func deploymentLogDiagnostic(root: URL) -> String {
        ["installer.log", "docker-pull.log", "docker-up.log"]
            .compactMap { name -> String? in
                let url = root.appendingPathComponent("logs/(name)")
                guard let contents = try? String(contentsOf: url, encoding: .utf8), !contents.isEmpty else {
                    return nil
                }
                return "--- (name) ---\n(contents)"
            }
            .joined(separator: "\n")
    }

    private func assertOpenAICompatibilityCRUD(
        baseURL: URL,
        managementKey: String,
        originalProviders: [RuntimeOpenAICompatibility]
    ) async throws {
        let client = ManagementAPIClient()
        let originalPayload = originalProviders.map { provider in
            RuntimeOpenAICompatibilityWrite(
                name: provider.name,
                priority: provider.priority,
                disabled: provider.disabled,
                prefix: provider.prefix,
                baseURL: provider.baseURL,
                apiKeyEntries: provider.apiKeyEntries,
                models: provider.models,
                headers: provider.headers,
                disableCooling: provider.disableCooling
            )
        }
        let providerName = "oases-e2e-provider"
        let renamedProviderName = "oases-e2e-provider-renamed"
        let testProvider = RuntimeOpenAICompatibilityWrite(
            name: providerName,
            priority: 7,
            disabled: false,
            prefix: "e2e",
            baseURL: "https://example.invalid/v1",
            apiKeyEntries: [RuntimeProviderAPIKey(apiKey: "oases-e2e-secret", weight: 2)],
            models: [
                RuntimeProviderModel(
                    name: "upstream-e2e-model",
                    alias: "e2e-model",
                    displayName: "E2E Model",
                    forceMapping: true,
                    inputModalities: ["text", "image"]
                )
            ],
            headers: ["X-Oases-E2E": "true"],
            disableCooling: true
        )

        do {
            try await client.replaceOpenAICompatibility(
                originalPayload + [testProvider],
                baseURL: baseURL,
                managementKey: managementKey
            )
            let afterCreate = try await client.openAICompatibility(
                baseURL: baseURL,
                managementKey: managementKey
            )
            let created = try XCTUnwrap(afterCreate.providers.first(where: { $0.name == providerName }))
            XCTAssertEqual(created.apiKeyEntries.first?.apiKey, "oases-e2e-secret")
            XCTAssertEqual(created.models.first?.alias, "e2e-model")
            XCTAssertEqual(created.models.first?.forceMapping, true)
            XCTAssertEqual(created.headers["X-Oases-E2E"], "true")

            let providerIndex = try XCTUnwrap(afterCreate.providers.firstIndex(where: { $0.name == providerName }))
            try await client.patchOpenAICompatibility(
                name: providerName,
                index: providerIndex,
                value: RuntimeOpenAICompatibilityPatch(
                    name: renamedProviderName,
                    prefix: "e2e-renamed",
                    disabled: true,
                    disableCooling: false,
                    baseURL: "https://example.invalid/v2",
                    apiKeyEntries: [RuntimeProviderAPIKey(apiKey: "oases-e2e-secret-2", weight: 3)],
                    models: [
                        RuntimeProviderModel(
                            name: "upstream-e2e-model-2",
                            alias: "e2e-model-2",
                            image: true
                        )
                    ]
                ),
                baseURL: baseURL,
                managementKey: managementKey
            )
            let afterPatch = try await client.openAICompatibility(
                baseURL: baseURL,
                managementKey: managementKey
            )
            let patched = try XCTUnwrap(afterPatch.providers.first(where: { $0.name == renamedProviderName }))
            XCTAssertEqual(patched.baseURL, "https://example.invalid/v2")
            XCTAssertTrue(patched.disabled)
            XCTAssertEqual(patched.apiKeyEntries.first?.apiKey, "oases-e2e-secret-2")
            XCTAssertEqual(patched.apiKeyEntries.first?.weight, 3)
            XCTAssertEqual(patched.models.first?.alias, "e2e-model-2")
            XCTAssertEqual(patched.models.first?.image, true)

            try await client.deleteOpenAICompatibility(
                name: renamedProviderName,
                index: nil,
                baseURL: baseURL,
                managementKey: managementKey
            )
            let afterDelete = try await client.openAICompatibility(
                baseURL: baseURL,
                managementKey: managementKey
            )
            XCTAssertFalse(afterDelete.providers.contains(where: { $0.name == providerName }))
            XCTAssertFalse(afterDelete.providers.contains(where: { $0.name == renamedProviderName }))
        } catch {
            try? await client.replaceOpenAICompatibility(
                originalPayload,
                baseURL: baseURL,
                managementKey: managementKey
            )
            throw error
        }

        try await client.replaceOpenAICompatibility(
            originalPayload,
            baseURL: baseURL,
            managementKey: managementKey
        )
    }

    private func assertAuthFileCRUD(
        baseURL: URL,
        managementKey: String
    ) async throws {
        let client = ManagementAPIClient()
        let name = "oases-e2e-auth.json"
        let initial = Data(#"{"type":"codex","email":"oases-e2e@example.com","priority":4}"#.utf8)
        let replacement = Data(#"{"type":"codex","email":"oases-e2e-replaced@example.com","priority":8}"#.utf8)

        do {
            try await client.uploadAuthFile(
                name: name,
                data: initial,
                baseURL: baseURL,
                managementKey: managementKey
            )
            let afterCreate = try await client.authFiles(
                baseURL: baseURL,
                managementKey: managementKey
            )
            let created = try XCTUnwrap(afterCreate.files.first(where: { $0.name == name }))

            let downloaded = try await client.downloadAuthFile(
                name: name,
                baseURL: baseURL,
                managementKey: managementKey
            )
            let downloadedObject = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: downloaded) as? [String: Any]
            )
            XCTAssertEqual(downloadedObject["email"] as? String, "oases-e2e@example.com")
            XCTAssertEqual(downloadedObject["priority"] as? Int, 4)

            try await client.patchAuthFileStatus(
                RuntimeAuthFileStatusPatch(
                    name: name,
                    authIndex: created.authIndex,
                    disabled: true
                ),
                baseURL: baseURL,
                managementKey: managementKey
            )
            let afterDisable = try await client.authFiles(
                baseURL: baseURL,
                managementKey: managementKey
            )
            XCTAssertEqual(afterDisable.files.first(where: { $0.name == name })?.disabled, true)

            try await client.patchAuthFileStatus(
                RuntimeAuthFileStatusPatch(
                    name: name,
                    authIndex: created.authIndex,
                    disabled: false
                ),
                baseURL: baseURL,
                managementKey: managementKey
            )

            try await client.uploadAuthFile(
                name: name,
                data: replacement,
                baseURL: baseURL,
                managementKey: managementKey
            )
            let replaced = try await client.downloadAuthFile(
                name: name,
                baseURL: baseURL,
                managementKey: managementKey
            )
            let replacedObject = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: replaced) as? [String: Any]
            )
            XCTAssertEqual(replacedObject["email"] as? String, "oases-e2e-replaced@example.com")
            XCTAssertEqual(replacedObject["priority"] as? Int, 8)

            try await client.deleteAuthFile(
                name: name,
                baseURL: baseURL,
                managementKey: managementKey
            )
            let afterDelete = try await client.authFiles(
                baseURL: baseURL,
                managementKey: managementKey
            )
            XCTAssertFalse(afterDelete.files.contains(where: { $0.name == name }))
        } catch {
            try? await client.deleteAuthFile(
                name: name,
                baseURL: baseURL,
                managementKey: managementKey
            )
            throw error
        }
    }

    private func assertGatewayAPIKeyCRUD(
        baseURL: URL,
        managementKey: String
    ) async throws {
        let client = ManagementAPIClient()
        let createdValue = "sk-cpa-oases-e2e-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let rotatedValue = "sk-cpa-oases-e2e-rotated-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        func cleanup() async {
            guard let current = try? await client.apiKeys(
                baseURL: baseURL,
                managementKey: managementKey
            ) else { return }
            for index in current.keys.enumerated()
                .filter({ $0.element == createdValue || $0.element == rotatedValue })
                .map(\.offset)
                .sorted(by: >) {
                try? await client.deleteAPIKey(
                    at: index,
                    baseURL: baseURL,
                    managementKey: managementKey
                )
            }
        }

        do {
            try await client.addAPIKey(
                createdValue,
                baseURL: baseURL,
                managementKey: managementKey
            )
            let afterCreate = try await client.apiKeys(
                baseURL: baseURL,
                managementKey: managementKey
            )
            let createdIndex = try XCTUnwrap(afterCreate.keys.firstIndex(of: createdValue))

            // The native App uses the resulting user API key against the public
            // model endpoint, rather than incorrectly sending the management key.
            let catalog = try await client.gatewayModels(
                baseURL: baseURL,
                apiKey: createdValue
            )
            XCTAssertGreaterThanOrEqual(catalog.data.count, 0)

            try await client.replaceAPIKey(
                at: createdIndex,
                with: rotatedValue,
                baseURL: baseURL,
                managementKey: managementKey
            )
            let afterReplace = try await client.apiKeys(
                baseURL: baseURL,
                managementKey: managementKey
            )
            XCTAssertFalse(afterReplace.keys.contains(createdValue))
            let rotatedIndex = try XCTUnwrap(afterReplace.keys.firstIndex(of: rotatedValue))

            try await client.deleteAPIKey(
                at: rotatedIndex,
                baseURL: baseURL,
                managementKey: managementKey
            )
            let afterDelete = try await client.apiKeys(
                baseURL: baseURL,
                managementKey: managementKey
            )
            XCTAssertFalse(afterDelete.keys.contains(rotatedValue))
        } catch {
            await cleanup()
            throw error
        }
    }

    private func assertCPAConfigYAMLRoundTrip(
        baseURL: URL,
        managementKey: String
    ) async throws {
        let client = ManagementAPIClient()
        let original = try await client.configYAML(
            baseURL: baseURL,
            managementKey: managementKey
        )
        XCTAssertFalse(original.isEmpty)

        try await client.saveConfigYAML(
            original,
            baseURL: baseURL,
            managementKey: managementKey
        )
        let reread = try await client.configYAML(
            baseURL: baseURL,
            managementKey: managementKey
        )
        XCTAssertFalse(reread.isEmpty)
    }

    private func assertQuotaManagementContract(
        cpaBaseURL: URL,
        cpaManagementKey: String,
        cpampBaseURL: URL,
        cpampAdminKey: String
    ) async throws {
        let client = ManagementAPIClient()
        let proxiedStatus = try await client.apiCall(
            RuntimeAPICallRequest(
                authIndex: nil,
                method: "GET",
                url: "http://127.0.0.1:8317/healthz",
                header: ["Accept": "application/json"]
            ),
            baseURL: cpaBaseURL,
            managementKey: cpaManagementKey
        )
        XCTAssertEqual(proxiedStatus.statusCode, 200)
        XCTAssertTrue(proxiedStatus.body.contains("status"))

        let cooldowns = try await client.activeQuotaCooldowns(
            baseURL: cpampBaseURL,
            managementKey: cpampAdminKey
        )
        XCTAssertGreaterThanOrEqual(cooldowns.items.count, 0)
    }

    private func assertHTTPStatus(
        _ url: URL,
        bearer: String? = nil,
        expected: Int
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if let bearer {
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OasesCPAIntegration", code: 1, userInfo: [NSLocalizedDescriptionKey: "No HTTP response from \(url)"])
        }
        XCTAssertEqual(httpResponse.statusCode, expected, url.absoluteString)
    }

    private func runCommand(
        _ executable: String,
        arguments: [String]
    ) throws -> (status: Int32, standardOutput: String, standardError: String) {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func commandFailure(
        _ action: String,
        result: (status: Int32, standardOutput: String, standardError: String)
    ) -> NSError {
        let diagnostic = [result.standardError, result.standardOutput]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return NSError(
            domain: "OasesCPASSHIntegration",
            code: Int(result.status),
            userInfo: [NSLocalizedDescriptionKey: "\(action)失败：\(diagnostic)"]
        )
    }

    private func waitForSSHConnection(
        process: Process,
        arguments: [String],
        target: String,
        logURL: URL
    ) async throws {
        var lastDiagnostic = ""
        for _ in 0..<30 {
            let result = try runCommand(
                "/usr/bin/ssh",
                arguments: arguments + [target, "printf ssh-ready"]
            )
            if result.status == 0 {
                return
            }
            lastDiagnostic = [result.standardError, result.standardOutput]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !process.isRunning {
                let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                throw NSError(
                    domain: "OasesCPASSHIntegration",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "隔离 sshd 未能启动：\(log.isEmpty ? lastDiagnostic : log)"]
                )
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        throw NSError(
            domain: "OasesCPASSHIntegration",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "SSH 连接在 7.5 秒内未就绪：\(lastDiagnostic)"]
        )
    }

    private func cleanupSSHFixture(
        request: DeploymentExecutionRequest?,
        lifecycle: RuntimeLifecycleService,
        tunnel: Process?,
        sshd: Process?,
        knownHostsPath: String?,
        originalKnownHosts: Data?,
        root: URL
    ) async {
        if let request {
            _ = try? runShellScript(
                lifecycle.stopScriptForVerification(
                    method: request.method,
                    installDirectory: request.installDirectory
                )
            )
        }
        terminateProcess(tunnel)
        terminateProcess(sshd)
        if let knownHostsPath, let originalKnownHosts {
            let knownHostsURL = URL(fileURLWithPath: knownHostsPath)
            try? originalKnownHosts.write(to: knownHostsURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: knownHostsURL.path
            )
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func terminateProcess(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        for _ in 0..<20 where process.isRunning {
            usleep(50_000)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            // A forwarded SSH client can remain in a stale Process state after SIGKILL.
            // Do not call waitUntilExit() in that branch: this test helper must never
            // turn a completed deployment assertion into an unbounded cleanup wait.
        }
        // Process.isRunning is the bounded observation we need here. Calling
        // waitUntilExit() after termination can still block on a forwarded SSH
        // client whose Foundation state has already transitioned to not running.
    }

    private func freeTCPPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NSError(domain: "OasesCPASSHIntegration", code: 6, userInfo: [NSLocalizedDescriptionKey: "无法创建测试 TCP socket。"])
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: 0)

        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bindStatus == 0 else {
            throw NSError(domain: "OasesCPASSHIntegration", code: 7, userInfo: [NSLocalizedDescriptionKey: "无法绑定测试 TCP socket。"])
        }

        var boundAddress = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(descriptor, socketAddress, &addressLength)
            }
        }
        guard nameStatus == 0 else {
            throw NSError(domain: "OasesCPASSHIntegration", code: 8, userInfo: [NSLocalizedDescriptionKey: "无法读取测试 TCP 端口。"])
        }
        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    private func tcpPortIsAvailable(_ port: Int) -> Bool {
        if let listenerCheck = try? runCommand(
            "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        ) {
            if listenerCheck.status == 0 {
                return false
            }
            if listenerCheck.status == 1 {
                return true
            }
        }

        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: 0)

        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        return bindStatus == 0
    }
}
