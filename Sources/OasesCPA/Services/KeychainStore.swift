import Foundation
import Security

enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            OasesLocalization.localizedFormat("Keychain 操作失败（OSStatus %d）。", status)
        }
    }
}

enum KeychainStore {
    private static let service = "Oases CPA Credentials"
    /// Service name early builds wrote entries under: "<bundle identifier>.credentials".
    /// Derived at run time so the source carries no build identity; it is only read.
    private static var legacyService: String? {
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else { return nil }
        return "\(identifier).credentials"
    }

#if DEBUG
    /// The Keychain of a test: a dictionary keyed by "<service>\u{0}<account>".
    final class TestBackend: @unchecked Sendable {
        fileprivate var items: [String: Data] = [:]
        fileprivate let lock = NSLock()
        init() {}
    }

    nonisolated(unsafe) private static var testBackend: TestBackend?

    /// Runs `operation` against an in-memory Keychain. Tests must never read or write the
    /// user's real Keychain (the service name is not bundle-scoped, so the app's real
    /// credentials would be reachable).
    static func withInMemoryKeychainForTesting<T>(_ operation: () throws -> T) rethrows -> T {
        let previous = testBackend
        testBackend = TestBackend()
        defer { testBackend = previous }
        return try operation()
    }

    /// The same for asynchronous store-level tests (main actor, so no other test swaps it).
    @MainActor
    static func withInMemoryKeychainForTesting<T>(_ operation: @MainActor () async throws -> T) async rethrows -> T {
        let previous = testBackend
        testBackend = TestBackend()
        defer { testBackend = previous }
        return try await operation()
    }

    /// nil outside tests; a backend inside `withInMemoryKeychainForTesting`; otherwise a test
    /// process gets an error instead of the real Keychain.
    private static func testBackendOrRefusal() throws -> TestBackend? {
        if let testBackend { return testBackend }
        if NSClassFromString("XCTestCase") != nil {
            throw KeychainStoreError.unexpectedStatus(errSecNotAvailable)
        }
        return nil
    }
#endif

    static func save(_ value: String, account: String) throws {
        try saveData(Data(value.utf8), account: account)
    }

    static func saveData(_ data: Data, account: String) throws {
#if DEBUG
        if let backend = try testBackendOrRefusal() {
            backend.lock.lock(); defer { backend.lock.unlock() }
            backend.items["\(service)\u{0}\(account)"] = data
            return
        }
#endif
        let query = baseQuery(account: account)
        // High-value secrets (SSH private keys, CPA/CPAMP admin keys) must
        // not sync to iCloud Keychain or be restorable on a different
        // device from a backup, so this is intentionally more restrictive
        // than `kSecAttrAccessibleAfterFirstUnlock`.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        addQuery[kSecAttrLabel as String] = "Oases CPA"
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus == errSecDuplicateItem {
            // Another writer raced us between the update and add above and
            // has since created the item; retry the update instead of
            // failing so this remains correct without a broader lock.
            let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard retryStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(retryStatus)
            }
            return
        }
        throw KeychainStoreError.unexpectedStatus(addStatus)
    }

    static func load(account: String) throws -> String? {
        guard let data = try loadData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func loadData(account: String) throws -> Data? {
        try loadData(account: account, service: service)
    }

    static func loadLegacyData(account: String) throws -> Data? {
        guard let legacyService else { return nil }
        return try loadData(account: account, service: legacyService)
    }

    static func loadLegacy(account: String) throws -> String? {
        guard let data = try loadLegacyData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func loadData(account: String, service: String) throws -> Data? {
#if DEBUG
        if let backend = try testBackendOrRefusal() {
            backend.lock.lock(); defer { backend.lock.unlock() }
            return backend.items["\(service)\u{0}\(account)"]
        }
#endif
        var query = baseQuery(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
        return result as? Data
    }

    static func delete(account: String) throws {
#if DEBUG
        if let backend = try testBackendOrRefusal() {
            backend.lock.lock(); defer { backend.lock.unlock() }
            backend.items["\(service)\u{0}\(account)"] = nil
            return
        }
#endif
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        baseQuery(account: account, service: service)
    }

    private static func baseQuery(account: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum SSHKeyMaterialStore {
    private static let legacyAccount = "ssh-private-key"
    private static let legacyFileName = "ssh-deployment-key"

#if DEBUG
    nonisolated(unsafe) private static var keysDirectoryOverride: URL?

    /// Runs `operation` with the materialized keys under `directory` instead of the app's
    /// Application Support folder.
    static func withKeysDirectoryForTesting<T>(_ directory: URL, operation: () throws -> T) rethrows -> T {
        let previous = keysDirectoryOverride
        keysDirectoryOverride = directory
        defer { keysDirectoryOverride = previous }
        return try operation()
    }
#endif

    private static func keysDirectory() throws -> URL {
#if DEBUG
        if let keysDirectoryOverride { return keysDirectoryOverride }
        if NSClassFromString("XCTestCase") != nil {
            throw KeychainStoreError.unexpectedStatus(errSecNotAvailable)
        }
#endif
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("Oases CPA/Keys", isDirectory: true)
    }

    static func save(from url: URL, profileID: UUID?) throws -> String {
        let hasSecurityScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let data = try Data(contentsOf: url)
        try KeychainStore.saveData(data, account: account(for: profileID))
        return try materialize(profileID: profileID)
    }

    static func materialize(profileID: UUID?, allowLegacyFallback: Bool = false) throws -> String {
        let targetAccount = account(for: profileID)
        var data = try KeychainStore.loadData(account: targetAccount)

        if data == nil, allowLegacyFallback, profileID != nil {
            data = try KeychainStore.loadLegacyData(account: targetAccount)
            if data == nil {
                data = try KeychainStore.loadLegacyData(account: legacyAccount)
            }
            if let data {
                // Migrate the old single-target credential only for an
                // already-installed legacy profile. New profiles must not
                // inherit another target's private key.
                try KeychainStore.saveData(data, account: targetAccount)
            }
        }

        guard let data else {
            throw KeychainStoreError.unexpectedStatus(errSecItemNotFound)
        }

        let directory = try keysDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = profileID.map { "ssh-deployment-key-\($0.uuidString.lowercased())" } ?? legacyFileName
        let url = directory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url.path
    }

    static func delete(profileID: UUID?) throws {
        try KeychainStore.delete(account: account(for: profileID))
        let url = try keysDirectory()
            .appendingPathComponent(profileID.map { "ssh-deployment-key-\($0.uuidString.lowercased())" } ?? legacyFileName)
        try? FileManager.default.removeItem(at: url)
    }

    static func deleteLegacy() throws {
        try KeychainStore.delete(account: legacyAccount)
        try delete(profileID: nil)
    }

    private static func account(for profileID: UUID?) -> String {
        guard let profileID else { return legacyAccount }
        return "ssh-private-key-\(profileID.uuidString)"
    }
}
