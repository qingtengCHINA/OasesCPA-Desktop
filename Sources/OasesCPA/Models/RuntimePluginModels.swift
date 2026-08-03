import Foundation

struct RuntimePluginsResponse: Decodable, Sendable {
    let pluginsEnabled: Bool
    let pluginsDir: String
    let plugins: [RuntimePlugin]

    private enum CodingKeys: String, CodingKey {
        case pluginsEnabled
        case pluginsDir
        case plugins
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pluginsEnabled = try container.decodeIfPresent(Bool.self, forKey: .pluginsEnabled) ?? false
        pluginsDir = try container.decodeIfPresent(String.self, forKey: .pluginsDir) ?? "plugins"
        plugins = try container.decodeIfPresent([RuntimePlugin].self, forKey: .plugins) ?? []
    }
}

struct RuntimePlugin: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let configured: Bool
    let registered: Bool
    let enabled: Bool
    let effectiveEnabled: Bool
    let supportsOAuth: Bool
    let oauthProvider: String?
    let logo: String
    let configFields: [RuntimePluginConfigField]
    let menus: [RuntimePluginMenu]
    let metadata: RuntimePluginMetadata?

    private enum CodingKeys: String, CodingKey {
        case id
        case path
        case configured
        case registered
        case enabled
        case effectiveEnabled
        // JSONDecoder.convertFromSnakeCase turns supports_oauth into supportsOauth.
        case supportsOAuth = "supportsOauth"
        case oauthProvider
        case logo
        case configFields
        case menus
        case metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        configured = try container.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        registered = try container.decodeIfPresent(Bool.self, forKey: .registered) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        effectiveEnabled = try container.decodeIfPresent(Bool.self, forKey: .effectiveEnabled) ?? false
        supportsOAuth = try container.decodeIfPresent(Bool.self, forKey: .supportsOAuth) ?? false
        oauthProvider = try container.decodeIfPresent(String.self, forKey: .oauthProvider)
        logo = try container.decodeIfPresent(String.self, forKey: .logo) ?? ""
        configFields = try container.decodeIfPresent([RuntimePluginConfigField].self, forKey: .configFields) ?? []
        menus = try container.decodeIfPresent([RuntimePluginMenu].self, forKey: .menus) ?? []
        metadata = try container.decodeIfPresent(RuntimePluginMetadata.self, forKey: .metadata)
    }

    var displayTitle: String {
        let metadataName = metadata?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return metadataName.isEmpty ? id : metadataName
    }

    var effectiveStateTitle: String {
        if effectiveEnabled { return OasesLocalization.localized("已生效") }
        if !registered {
            if configured { return OasesLocalization.localized("已配置，待注册") }
            return path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? OasesLocalization.localized("未发现") : OasesLocalization.localized("已发现，待配置")
        }
        if enabled { return OasesLocalization.localized("等待全局启用") }
        return configured ? OasesLocalization.localized("已停用") : OasesLocalization.localized("待启用")
    }

    var resolvedOAuthProvider: String? {
        guard supportsOAuth else { return nil }
        let provider = oauthProvider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return provider.isEmpty ? id : provider
    }
}

struct RuntimePluginConfigField: Decodable, Hashable, Sendable {
    let name: String
    let type: String
    let enumValues: [String]
    let description: String

    private enum CodingKeys: String, CodingKey {
        case name
        case type
        case enumValues
        case description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "string"
        enumValues = try container.decodeIfPresent([String].self, forKey: .enumValues) ?? []
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    }
}

struct RuntimePluginMetadata: Decodable, Hashable, Sendable {
    let name: String
    let version: String
    let author: String
    let githubRepository: String
    let logo: String
    let configFields: [RuntimePluginConfigField]

    private enum CodingKeys: String, CodingKey {
        case name
        case version
        case author
        case githubRepository
        case logo
        case configFields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        githubRepository = try container.decodeIfPresent(String.self, forKey: .githubRepository) ?? ""
        logo = try container.decodeIfPresent(String.self, forKey: .logo) ?? ""
        configFields = try container.decodeIfPresent([RuntimePluginConfigField].self, forKey: .configFields) ?? []
    }
}

struct RuntimePluginMenu: Decodable, Hashable, Sendable {
    let path: String
    let menu: String
    let description: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        menu = try container.decodeIfPresent(String.self, forKey: .menu) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case menu
        case description
    }
}

struct RuntimePluginEnabledPatch: Encodable, Sendable {
    let enabled: Bool
}

enum RuntimePluginConfigValidator {
    static func canonicalData(from text: String) -> Data? {
        canonicalData(from: Data(text.utf8))
    }

    static func canonicalData(from data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ),
        object is [String: Any],
        JSONSerialization.isValidJSONObject(object) else {
            return nil
        }

        return try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    static func formattedText(from data: Data) -> String? {
        guard let canonicalData = canonicalData(from: data) else { return nil }
        return String(decoding: canonicalData, as: UTF8.self) + "\n"
    }
}

struct RuntimePluginStoreResponse: Decodable, Sendable {
    let pluginsEnabled: Bool
    let pluginsDir: String
    let sources: [RuntimePluginStoreSource]
    let sourceErrors: [RuntimePluginStoreSourceError]
    let plugins: [RuntimePluginStoreEntry]

    private enum CodingKeys: String, CodingKey {
        case pluginsEnabled
        case pluginsDir
        case sources
        case sourceErrors
        case plugins
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pluginsEnabled = try container.decodeIfPresent(Bool.self, forKey: .pluginsEnabled) ?? false
        pluginsDir = try container.decodeIfPresent(String.self, forKey: .pluginsDir) ?? "plugins"
        sources = try container.decodeIfPresent([RuntimePluginStoreSource].self, forKey: .sources) ?? []
        sourceErrors = try container.decodeIfPresent([RuntimePluginStoreSourceError].self, forKey: .sourceErrors) ?? []
        plugins = try container.decodeIfPresent([RuntimePluginStoreEntry].self, forKey: .plugins) ?? []
    }
}

struct RuntimePluginStoreSource: Decodable, Hashable, Sendable {
    let id: String
    let name: String
    let url: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case url
    }
}

struct RuntimePluginStoreSourceError: Decodable, Hashable, Sendable {
    let sourceID: String
    let sourceName: String
    let sourceURL: String
    let message: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID = "sourceId"
        case sourceName
        case sourceURL = "sourceUrl"
        case message
    }

    var sourceTitle: String {
        if !sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return sourceName }
        if !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return sourceID }
        return sourceURL
    }
}

struct RuntimePluginStorePlatform: Decodable, Hashable, Sendable {
    let goos: String
    let goarch: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        goos = try container.decodeIfPresent(String.self, forKey: .goos) ?? ""
        goarch = try container.decodeIfPresent(String.self, forKey: .goarch) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case goos
        case goarch
    }

    var title: String {
        [goos, goarch].filter { !$0.isEmpty }.joined(separator: "/")
    }
}

struct RuntimePluginStoreEntry: Decodable, Hashable, Sendable {
    let storeID: String
    let sourceID: String
    let sourceName: String
    let sourceURL: String
    let id: String
    let name: String
    let description: String
    let author: String
    let version: String
    let repository: String
    let installType: String
    let authRequired: Bool
    let authConfigured: Bool
    let platforms: [RuntimePluginStorePlatform]
    let logo: String
    let homepage: String
    let license: String
    let tags: [String]
    let installed: Bool
    let installedVersion: String
    let installedSourceID: String
    let installSourceStatus: String
    let path: String
    let configured: Bool
    let registered: Bool
    let enabled: Bool
    let effectiveEnabled: Bool
    let updateAvailable: Bool

    private enum CodingKeys: String, CodingKey {
        case storeID = "storeId"
        case sourceID = "sourceId"
        case sourceName
        case sourceURL = "sourceUrl"
        case id
        case name
        case description
        case author
        case version
        case repository
        case installType
        case authRequired
        case authConfigured
        case platforms
        case logo
        case homepage
        case license
        case tags
        case installed
        case installedVersion
        case installedSourceID = "installedSourceId"
        case installSourceStatus
        case path
        case configured
        case registered
        case enabled
        case effectiveEnabled
        case updateAvailable
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storeID = try container.decodeIfPresent(String.self, forKey: .storeID) ?? ""
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        repository = try container.decodeIfPresent(String.self, forKey: .repository) ?? ""
        installType = try container.decodeIfPresent(String.self, forKey: .installType) ?? ""
        authRequired = try container.decodeIfPresent(Bool.self, forKey: .authRequired) ?? false
        authConfigured = try container.decodeIfPresent(Bool.self, forKey: .authConfigured) ?? false
        platforms = try container.decodeIfPresent([RuntimePluginStorePlatform].self, forKey: .platforms) ?? []
        logo = try container.decodeIfPresent(String.self, forKey: .logo) ?? ""
        homepage = try container.decodeIfPresent(String.self, forKey: .homepage) ?? ""
        license = try container.decodeIfPresent(String.self, forKey: .license) ?? ""
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        installed = try container.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        installedVersion = try container.decodeIfPresent(String.self, forKey: .installedVersion) ?? ""
        installedSourceID = try container.decodeIfPresent(String.self, forKey: .installedSourceID) ?? ""
        installSourceStatus = try container.decodeIfPresent(String.self, forKey: .installSourceStatus) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        configured = try container.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        registered = try container.decodeIfPresent(Bool.self, forKey: .registered) ?? false
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        effectiveEnabled = try container.decodeIfPresent(Bool.self, forKey: .effectiveEnabled) ?? false
        updateAvailable = try container.decodeIfPresent(Bool.self, forKey: .updateAvailable) ?? false
    }

    var displayTitle: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? id : trimmedName
    }

    var sourceTitle: String {
        let trimmedName = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? sourceID : trimmedName
    }

    var versionSummary: String {
        if installed && updateAvailable, !installedVersion.isEmpty, !version.isEmpty {
            return "\(installedVersion) → \(version)"
        }
        if installed, !installedVersion.isEmpty { return installedVersion }
        return version
    }
}

struct RuntimePluginStoreInstallRequest: Encodable, Sendable {
    let version: String
}

struct RuntimePluginStoreInstallResult: Decodable, Sendable {
    let status: String
    let sourceID: String
    let sourceName: String
    let sourceURL: String
    let id: String
    let version: String
    let installType: String
    let path: String
    let pluginsEnabled: Bool
    let restartRequired: Bool

    private enum CodingKeys: String, CodingKey {
        case status
        case sourceID = "sourceId"
        case sourceName
        case sourceURL = "sourceUrl"
        case id
        case version
        case installType
        case path
        case pluginsEnabled
        case restartRequired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID) ?? ""
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        installType = try container.decodeIfPresent(String.self, forKey: .installType) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        pluginsEnabled = try container.decodeIfPresent(Bool.self, forKey: .pluginsEnabled) ?? false
        restartRequired = try container.decodeIfPresent(Bool.self, forKey: .restartRequired) ?? false
    }
}

struct RuntimePluginDeleteResult: Decodable, Sendable {
    let status: String
    let id: String
    let path: String
    let fileDeleted: Bool
    let configuredRemoved: Bool
    let restartRequired: Bool

    private enum CodingKeys: String, CodingKey {
        case status
        case id
        case path
        case fileDeleted
        case configuredRemoved
        case restartRequired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        fileDeleted = try container.decodeIfPresent(Bool.self, forKey: .fileDeleted) ?? false
        configuredRemoved = try container.decodeIfPresent(Bool.self, forKey: .configuredRemoved) ?? false
        restartRequired = try container.decodeIfPresent(Bool.self, forKey: .restartRequired) ?? false
    }
}
