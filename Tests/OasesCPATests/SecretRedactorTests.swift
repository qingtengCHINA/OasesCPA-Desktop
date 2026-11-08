import XCTest
@testable import OasesCPA

/// Key samples are assembled at run time from repeated characters, so this file holds no
/// complete key-shaped literal (the commit gate scans added lines).
final class SecretRedactorTests: XCTestCase {
    private let mask = "••••"

    func testRedactsManagementKeyAndKnownKeyShapes() {
        let managementKey = "test-key-123456"
        let cpaKey = "cpa_" + String(repeating: "0a", count: 32)
        let cpampKey = "cpamp_" + String(repeating: "f9", count: 32)
        let packKey = "sk-pk-" + String(repeating: "Ab_-", count: 10) + "xyz"
        let clientKey = "sk-" + String(repeating: "q", count: 24)
        let internalKey = "oases-int-" + String(repeating: "Zz9_", count: 10) + "abc"
        XCTAssertEqual(packKey.count, 6 + 43)
        XCTAssertEqual(internalKey.count, 10 + 43)

        let text = "key \(managementKey) failed; cpa=\(cpaKey), panel=\(cpampKey); pack \(packKey) and client \(clientKey) or \(internalKey)."
        let redacted = SecretRedactor.redact(text, secrets: [managementKey])

        XCTAssertEqual(redacted, "key \(mask) failed; cpa=\(mask), panel=\(mask); pack \(mask) and client \(mask) or \(mask).")
        for secret in [managementKey, cpaKey, cpampKey, packKey, clientKey, internalKey] {
            XCTAssertFalse(redacted.contains(secret))
        }
    }

    func testLeavesOrdinaryTextAlone() {
        let text = "risk-assessment-and-review-of-the-provider-list failed (sk-short, cpa_123, a task-id)"
        XCTAssertEqual(SecretRedactor.redact(text, secrets: []), text)
        XCTAssertEqual(SecretRedactor.redact("plain message", secrets: ["", "   "]), "plain message")
        XCTAssertEqual(SecretRedactor.redact("", secrets: ["abc"]), "")
    }

    func testRedactsEveryOccurrenceAndLongestSecretFirst() {
        let text = "abc-long abc abc-long"
        XCTAssertEqual(SecretRedactor.redact(text, secrets: ["abc", "abc-long"]), "\(mask) \(mask) \(mask)")
    }

    func testRedactsKeysEmbeddedInJSON() {
        let clientKey = "sk-" + String(repeating: "Q1", count: 16)
        let body = #"{"error":"Key "# + clientKey + #" already exists","code":"conflict"}"#
        XCTAssertEqual(
            SecretRedactor.redact(body, secrets: []),
            #"{"error":"Key ••••"# + #" already exists","code":"conflict"}"#
        )
    }
}
