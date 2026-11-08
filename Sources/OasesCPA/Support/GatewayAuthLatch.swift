import CryptoKit
import Foundation

/// Remembers the management key the gateway rejected with 401, so that no client sends it
/// again: every failed attempt lengthens the gateway's global back-off (up to 10 s), so
/// background refreshes with a stale key must stop at the first 401. The latch is cleared
/// only when the key changes or the user asks to verify again.
///
/// Only a SHA-256 fingerprint of the key is kept, never the key.
struct GatewayAuthLatch: Sendable, Equatable {
    private var rejectedFingerprint: String?

    mutating func reject(key: String) {
        rejectedFingerprint = Self.fingerprint(key)
    }

    mutating func clear() {
        rejectedFingerprint = nil
    }

    func allows(key: String) -> Bool {
        guard let rejectedFingerprint else { return true }
        return rejectedFingerprint != Self.fingerprint(key)
    }

    private static func fingerprint(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
