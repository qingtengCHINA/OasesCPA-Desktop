import Foundation

struct DeploymentProfile: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    var targetKind: DeploymentTargetKind
    var deploymentMethod: DeploymentMethod
    var remoteHost: String
    var remoteUser: String
    var remotePort: String
    var privateKeyPath: String
    var installDirectory: String
    var isInstalled: Bool
    var lastAttachedAt: Date?
    /// Saved by app 0.1.4 and later; profiles saved before have no value and are `legacy`.
    var topology: DeploymentTopology
    /// SHA-256 of the gateway's internal engine key, reported by the install script (fd 3);
    /// the key itself never leaves the target. Nil for Docker and for older profiles.
    var packEngineKeyFingerprint: String?

    init(
        id: UUID = UUID(),
        targetKind: DeploymentTargetKind,
        deploymentMethod: DeploymentMethod,
        remoteHost: String,
        remoteUser: String,
        remotePort: String,
        privateKeyPath: String,
        installDirectory: String,
        isInstalled: Bool,
        lastAttachedAt: Date?,
        topology: DeploymentTopology = .legacy,
        packEngineKeyFingerprint: String? = nil
    ) {
        self.id = id
        self.targetKind = targetKind
        self.deploymentMethod = deploymentMethod
        self.remoteHost = remoteHost
        self.remoteUser = remoteUser
        self.remotePort = remotePort
        self.privateKeyPath = privateKeyPath
        self.installDirectory = installDirectory
        self.isInstalled = isInstalled
        self.lastAttachedAt = lastAttachedAt
        self.topology = topology
        self.packEngineKeyFingerprint = packEngineKeyFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case targetKind
        case deploymentMethod
        case remoteHost
        case remoteUser
        case remotePort
        case privateKeyPath
        case installDirectory
        case isInstalled
        case lastAttachedAt
        case topology
        case packEngineKeyFingerprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        targetKind = try container.decode(DeploymentTargetKind.self, forKey: .targetKind)
        deploymentMethod = try container.decode(DeploymentMethod.self, forKey: .deploymentMethod)
        remoteHost = try container.decode(String.self, forKey: .remoteHost)
        remoteUser = try container.decode(String.self, forKey: .remoteUser)
        remotePort = try container.decode(String.self, forKey: .remotePort)
        privateKeyPath = try container.decode(String.self, forKey: .privateKeyPath)
        installDirectory = try container.decode(String.self, forKey: .installDirectory)
        isInstalled = try container.decode(Bool.self, forKey: .isInstalled)
        lastAttachedAt = try container.decodeIfPresent(Date.self, forKey: .lastAttachedAt)
        topology = try container.decodeIfPresent(DeploymentTopology.self, forKey: .topology) ?? .legacy
        packEngineKeyFingerprint = try container.decodeIfPresent(String.self, forKey: .packEngineKeyFingerprint)
    }

    var displayName: String {
        switch targetKind {
        case .local:
            return OasesLocalization.localized("本机 Mac")
        case .ssh:
            let host = remoteHost.isEmpty ? OasesLocalization.localized("未填写主机") : remoteHost
            return "\(remoteUser.isEmpty ? "root" : remoteUser)@\(host)"
        }
    }

    var endpointSummary: String {
        let method = deploymentMethod.title
        return targetKind == .local
            ? "\(method) · \(installDirectory)"
            : "\(method) · SSH \(remotePort) · \(installDirectory)"
    }

    var targetIdentity: String {
        var directory = installDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        while directory.count > 1, directory.hasSuffix("/") {
            directory.removeLast()
        }

        switch targetKind {
        case .local:
            let expanded = (directory as NSString).expandingTildeInPath
            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            return "local|\(standardized)"
        case .ssh:
            let host = remoteHost.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let user = remoteUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "root"
                : remoteUser.trimmingCharacters(in: .whitespacesAndNewlines)
            let port = Int(remotePort).map(String.init) ?? remotePort
            return "ssh|\(user)@\(host):\(port)|\(directory)"
        }
    }
}

enum DeploymentProfileStore {
    private static let defaultsKey = "oases.cpa.deployment.profile"
    private static let profilesKey = "oases.cpa.deployment.profiles"
    private static let activeProfileKey = "oases.cpa.deployment.active-profile"

#if DEBUG
    nonisolated(unsafe) private static var defaultsOverride: UserDefaults?

    /// Runs `operation` with profiles and run preferences in `suite` instead of the standard
    /// defaults (store-level tests never write the process's real profile list).
    @MainActor
    static func withDefaultsForTesting<T>(_ suite: UserDefaults, _ operation: () async throws -> T) async rethrows -> T {
        let previous = defaultsOverride
        defaultsOverride = suite
        defer { defaultsOverride = previous }
        return try await operation()
    }

    /// Where profiles and run preferences live.
    static var defaults: UserDefaults { defaultsOverride ?? .standard }
#else
    /// Where profiles and run preferences live.
    static var defaults: UserDefaults { .standard }
#endif

    static func load() -> DeploymentProfile? {
        let profiles = loadAll()
        if let activeIDString = defaults.string(forKey: activeProfileKey),
           let activeID = UUID(uuidString: activeIDString),
           let active = profiles.first(where: { $0.id == activeID }) {
            return active
        }
        return profiles.first
    }

    @discardableResult
    static func save(_ profile: DeploymentProfile) -> DeploymentProfile {
        let existingProfiles = loadAll()
        if !profile.isInstalled,
           let installed = existingProfiles.first(where: {
               $0.id != profile.id && $0.isInstalled && $0.targetIdentity == profile.targetIdentity
           }) {
            setActive(installed.id)
            return installed
        }

        var profiles = existingProfiles.filter {
            $0.id == profile.id || $0.targetIdentity != profile.targetIdentity
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        saveAll(profiles)
        setActive(profile.id)
        return profile
    }

    static func loadAll() -> [DeploymentProfile] {
        if let data = defaults.data(forKey: profilesKey),
           let profiles = try? JSONDecoder().decode([DeploymentProfile].self, from: data) {
            return profiles
        }

        guard let data = defaults.data(forKey: defaultsKey),
              let legacy = try? JSONDecoder().decode(DeploymentProfile.self, from: data) else {
            return []
        }
        let migrated = [legacy]
        saveAll(migrated)
        setActive(legacy.id)
        return migrated
    }

    static func saveAll(_ profiles: [DeploymentProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: profilesKey)
        defaults.removeObject(forKey: defaultsKey)
    }

    static func setActive(_ id: UUID) {
        defaults.set(id.uuidString, forKey: activeProfileKey)
    }

    static func remove(_ id: UUID) {
        let profiles = loadAll().filter { $0.id != id }
        if profiles.isEmpty {
            clear()
            return
        }
        saveAll(profiles)
        if let activeID = UUID(uuidString: defaults.string(forKey: activeProfileKey) ?? ""), activeID == id {
            setActive(profiles[0].id)
        }
    }

    static func clear() {
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: profilesKey)
        defaults.removeObject(forKey: activeProfileKey)
    }
}
