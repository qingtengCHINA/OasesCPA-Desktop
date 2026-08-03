import Foundation
import Security

enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            "Keychain 操作失败（OSStatus \(status)）。"
        }
    }
}

enum KeychainStore {
    private static let service = "Oases CPA Credentials"
    private static let legacyService = "dev.oases.cpa.macos.credentials"

    static func save(_ value: String, account: String) throws {
        try saveData(Data(value.utf8), account: account)
    }

    static func saveData(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
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
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unexpectedStatus(addStatus)
        }
    }

    static func load(account: String) throws -> String? {
        guard let data = try loadData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func loadData(account: String) throws -> Data? {
        try loadData(account: account, service: service)
    }

    static func loadLegacyData(account: String) throws -> Data? {
        try loadData(account: account, service: legacyService)
    }

    static func loadLegacy(account: String) throws -> String? {
        guard let data = try loadLegacyData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func loadData(account: String, service: String) throws -> Data? {
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

        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = applicationSupport.appendingPathComponent("Oases CPA/Keys", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = profileID.map { "ssh-deployment-key-\($0.uuidString.lowercased())" } ?? legacyFileName
        let url = directory.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url.path
    }

    static func delete(profileID: UUID?) throws {
        try KeychainStore.delete(account: account(for: profileID))
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = applicationSupport
            .appendingPathComponent("Oases CPA/Keys", isDirectory: true)
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
