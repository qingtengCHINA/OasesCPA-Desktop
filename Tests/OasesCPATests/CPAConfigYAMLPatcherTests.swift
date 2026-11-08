import Foundation
import XCTest
@testable import OasesCPA

/// `CPAConfigYAMLPatcher` (Task 19): one scalar of the engine's `config.yaml` read or written by
/// lines, block style only; every other line stays byte for byte. Shapes it does not understand
/// are refused instead of guessed.
final class CPAConfigYAMLPatcherTests: XCTestCase {
    /// The legacy layout the deployments write (top-level keys), with comments and a nested list.
    private let base = """
    # Oases CPA engine
    host: "127.0.0.1"
    port: 18316
    api-keys:
      - "client-key-placeholder"
    openai-compatibility:
      - name: relay
        disable-cooling: true # a provider's own override, not the global key
        base-url: "https://relay.example.test/v1"
    request-retry: 3

    """

    func testSetsMissingTopLevelKeyAtEnd() throws {
        let patched = try CPAConfigYAMLPatcher.setting("true", at: ["disable-cooling"], in: base)
        XCTAssertEqual(patched, base + "disable-cooling: true\n", "appended; every other line unchanged")
        XCTAssertEqual(try CPAConfigYAMLPatcher.value(at: ["disable-cooling"], in: patched), "true")
        XCTAssertNil(try CPAConfigYAMLPatcher.value(at: ["disable-cooling"], in: base), "the provider's nested key is not the global one")
        // A file without a final newline gets one before the new line.
        XCTAssertEqual(try CPAConfigYAMLPatcher.setting("true", at: ["disable-cooling"], in: "port: 1"), "port: 1\ndisable-cooling: true\n")
    }

    func testReplacesExistingScalarKeepingComments() throws {
        let yaml = base + "disable-cooling: false # note\n"
        let patched = try CPAConfigYAMLPatcher.setting("true", at: ["disable-cooling"], in: yaml)
        XCTAssertEqual(patched, base + "disable-cooling: true # note\n")
        XCTAssertEqual(try CPAConfigYAMLPatcher.value(at: ["disable-cooling"], in: yaml), "false")
        // The same value again changes nothing at all.
        XCTAssertEqual(try CPAConfigYAMLPatcher.setting("false", at: ["disable-cooling"], in: yaml), yaml)
    }

    func testAddsNestedKeyWhenParentMissing() throws {
        let patched = try CPAConfigYAMLPatcher.setting("false", at: ["response-compression", "enabled"], in: base)
        XCTAssertEqual(patched, base + "response-compression:\n  enabled: false\n")
        XCTAssertEqual(try CPAConfigYAMLPatcher.value(at: ["response-compression", "enabled"], in: patched), "false")
        // A parent without children (YAML null) gets the child right below it.
        let empty = "response-compression:\nrequest-retry: 3\n"
        XCTAssertEqual(try CPAConfigYAMLPatcher.setting("true", at: ["response-compression", "enabled"], in: empty),
                       "response-compression:\n  enabled: true\nrequest-retry: 3\n")
    }

    func testReplacesNestedKey() throws {
        let yaml = base + "response-compression:\n    enabled: true\n    min-bytes: 1024 # keep\nws-auth: true\n"
        let patched = try CPAConfigYAMLPatcher.setting("false", at: ["response-compression", "enabled"], in: yaml)
        XCTAssertEqual(patched, base + "response-compression:\n    enabled: false\n    min-bytes: 1024 # keep\nws-auth: true\n", "siblings untouched")
        // A missing child goes after the parent's last child, at the children's indentation.
        let withoutEnabled = base + "response-compression:\n    min-bytes: 1024\n\nws-auth: true\n"
        XCTAssertEqual(try CPAConfigYAMLPatcher.setting("false", at: ["response-compression", "enabled"], in: withoutEnabled),
                       base + "response-compression:\n    min-bytes: 1024\n    enabled: false\n\nws-auth: true\n")
    }

    func testRejectsDuplicateKeys() {
        let yaml = base + "disable-cooling: false\ndisable-cooling: true\n"
        XCTAssertThrowsError(try CPAConfigYAMLPatcher.setting("true", at: ["disable-cooling"], in: yaml)) { error in
            XCTAssertEqual(error as? CPAConfigYAMLPatchError, .ambiguous(["disable-cooling"]))
        }
        XCTAssertThrowsError(try CPAConfigYAMLPatcher.value(at: ["disable-cooling"], in: yaml)) { error in
            XCTAssertEqual(error as? CPAConfigYAMLPatchError, .ambiguous(["disable-cooling"]))
        }
        let nested = "response-compression:\n  enabled: true\n  enabled: false\n"
        XCTAssertThrowsError(try CPAConfigYAMLPatcher.setting("true", at: ["response-compression", "enabled"], in: nested)) { error in
            XCTAssertEqual(error as? CPAConfigYAMLPatchError, .ambiguous(["response-compression", "enabled"]))
        }
        // A parent that holds a list or a scalar is not a mapping: refused, never rewritten.
        XCTAssertThrowsError(try CPAConfigYAMLPatcher.setting("true", at: ["response-compression", "enabled"], in: "response-compression:\n  - a\n"))
        XCTAssertThrowsError(try CPAConfigYAMLPatcher.setting("true", at: ["response-compression", "enabled"], in: "response-compression: off\n"))
    }

    func testRejectsFlowStyle() {
        let yaml = base + "response-compression: {enabled: true}\n"
        XCTAssertThrowsError(try CPAConfigYAMLPatcher.setting("false", at: ["response-compression", "enabled"], in: yaml)) { error in
            XCTAssertEqual(error as? CPAConfigYAMLPatchError, .flowStyle(["response-compression"]))
        }
        XCTAssertThrowsError(try CPAConfigYAMLPatcher.value(at: ["response-compression", "enabled"], in: yaml)) { error in
            XCTAssertEqual(error as? CPAConfigYAMLPatchError, .flowStyle(["response-compression"]))
        }
        XCTAssertThrowsError(try CPAConfigYAMLPatcher.setting("true", at: ["disable-cooling"], in: "disable-cooling: [true]\n")) { error in
            XCTAssertEqual(error as? CPAConfigYAMLPatchError, .flowStyle(["disable-cooling"]))
        }
        // Another key's flow value (the engine writes `oauth-request-scoped-errors: {}`) is left alone.
        let other = base + "oauth-request-scoped-errors: {}\n"
        XCTAssertEqual(try CPAConfigYAMLPatcher.setting("true", at: ["disable-cooling"], in: other), other + "disable-cooling: true\n")
        // The refusal tells the user where to go instead.
        XCTAssertTrue(CPAConfigYAMLPatchError.flowStyle(["response-compression"]).localizedDescription.contains("配置文件编辑器")
                      || CPAConfigYAMLPatchError.flowStyle(["response-compression"]).localizedDescription.contains("configuration file editor"))
    }

    func testQuotedKeysCRLFAndValueReading() throws {
        let yaml = "\"disable-cooling\": 'true'\r\nport: 1\r\n"
        XCTAssertEqual(try CPAConfigYAMLPatcher.value(at: ["disable-cooling"], in: yaml), "true", "quotes removed")
        XCTAssertEqual(try CPAConfigYAMLPatcher.setting("false", at: ["disable-cooling"], in: yaml), "\"disable-cooling\": false\r\nport: 1\r\n")
        XCTAssertEqual(try CPAConfigYAMLPatcher.setting("true", at: ["ws-auth"], in: yaml), yaml + "ws-auth: true\r\n", "the file's line ending")
        XCTAssertNil(try CPAConfigYAMLPatcher.value(at: ["disable-cooling"], in: "disable-cooling:\n"), "an empty value is null")
        XCTAssertThrowsError(try CPAConfigYAMLPatcher.setting("a\nb", at: ["disable-cooling"], in: yaml), "one plain scalar only")
    }

    /// The file exactly as CLIProxyAPI v8.0.51 rewrote it on the probe engine (after its own
    /// writes and one `PUT config.yaml`; secret, port and path replaced): the engine appends
    /// blocks and writes `oauth-request-scoped-errors: {}` in flow style.
    private let engineWritten = """
    # Probe engine (start_probe_engine.sh): legacy layout, loopback only.
    host: "127.0.0.1"
    port: 40000
    auth-dir: "<scratch>/probe-engine/auths"
    api-keys: []
    remote-management:
      allow-remote: false
      secret-key: "<masked>"
      disable-control-panel: true
    response-compression:
      enabled: true
    credential-concurrency:
      cpa-heartbeat-timeout: 3s
      cpa-cancel-bound: 5s
      reclaim-grace: 5s
      cleanup-interval: 5s
      release-flush-interval: 250ms
      release-max-backoff: 2s
      busy-retry-min: 250ms
      busy-retry-max: 1s
      max-limit: 1000000
    credential-in-flight:
      snapshot-interval: 2s
      stale-after: 10s
      max-part-bytes: 262144
      max-part-count: 64
      max-revision-bytes: 16777216
      max-aggregate-groups: 100000
      max-details: 10000
      max-string-bytes: 256
      staging-retention: 1m
    discovery:
      service-type: _ai-gateway._tcp
      subtypes:
        - _chat-completions
        - _responses
        - _messages
        - _generate-content
        - _interactions
    redis-usage-queue-retention-seconds: 60
    disable-cooling: true # probe
    request-retry: 0
    max-retry-credentials: 2
    ws-auth: true
    oauth-request-scoped-errors: {}

    """

    func testEngineWrittenConfigChangesOneLine() throws {
        XCTAssertEqual(try CPAConfigYAMLPatcher.value(at: ["disable-cooling"], in: engineWritten), "true")
        XCTAssertEqual(try CPAConfigYAMLPatcher.value(at: ["response-compression", "enabled"], in: engineWritten), "true")
        let cooling = try CPAConfigYAMLPatcher.setting("false", at: ["disable-cooling"], in: engineWritten)
        XCTAssertEqual(cooling, engineWritten.replacingOccurrences(of: "disable-cooling: true # probe", with: "disable-cooling: false # probe"))
        let compression = try CPAConfigYAMLPatcher.setting("false", at: ["response-compression", "enabled"], in: engineWritten)
        XCTAssertEqual(compression, engineWritten.replacingOccurrences(of: "response-compression:\n  enabled: true", with: "response-compression:\n  enabled: false"))
        XCTAssertEqual(try CPAConfigYAMLPatcher.value(at: ["discovery", "service-type"], in: engineWritten), "_ai-gateway._tcp")
        XCTAssertThrowsError(try CPAConfigYAMLPatcher.value(at: ["discovery", "subtypes"], in: engineWritten), "a list is not a scalar")
    }
}
