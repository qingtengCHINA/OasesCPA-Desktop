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

    /// The saved list, element by element. A profile this version cannot read (for example a
    /// `topology` written by a newer version, or a damaged entry) is left out of the result but
    /// never lost: `saveAll` writes it back unchanged, in its place at the end of the list.
    /// Guessing a topology for it instead (`.legacy`) could make the app attach, patrol or
    /// upgrade the deployment with the wrong ports and processes, so it is not shown at all.
    static func loadAll() -> [DeploymentProfile] {
        if let data = defaults.data(forKey: profilesKey) {
            return decodeLeniently(data).profiles
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

    /// The readable profiles of a stored list and the raw JSON of every element that is not
    /// one (`unreadable`); `isList` is false when the data is not a JSON array at all.
    static func decodeLeniently(_ data: Data) -> (profiles: [DeploymentProfile], unreadable: [Any], isList: Bool) {
        guard let elements = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return ([], [], false)
        }
        var profiles: [DeploymentProfile] = []
        var unreadable: [Any] = []
        for element in elements {
            if JSONSerialization.isValidJSONObject(element),
               let elementData = try? JSONSerialization.data(withJSONObject: element),
               let profile = try? JSONDecoder().decode(DeploymentProfile.self, from: elementData) {
                profiles.append(profile)
            } else {
                unreadable.append(element)
            }
        }
        return (profiles, unreadable, true)
    }

    /// The key that keeps a stored list that is not a JSON array at all, before it is replaced.
    static let unreadableProfilesKey = "oases.cpa.deployment.profiles.unreadable"

    /// Saves `profiles` and keeps whatever of the stored list this version could not read:
    /// unreadable elements are appended unchanged; a stored value that is not a list at all is
    /// copied to `unreadableProfilesKey` (once; an existing copy is never overwritten) first.
    static func saveAll(_ profiles: [DeploymentProfile]) {
        guard let encoded = try? JSONEncoder().encode(profiles) else { return }
        var data = encoded
        if let stored = defaults.data(forKey: profilesKey) {
            let previous = decodeLeniently(stored)
            if !previous.isList {
                if defaults.data(forKey: unreadableProfilesKey) == nil {
                    defaults.set(stored, forKey: unreadableProfilesKey)
                }
            } else if !previous.unreadable.isEmpty {
                guard let current = try? JSONSerialization.jsonObject(with: encoded) as? [Any] else { return }
                let merged = current + previous.unreadable
                guard JSONSerialization.isValidJSONObject(merged),
                      let mergedData = try? JSONSerialization.data(withJSONObject: merged) else { return }
                data = mergedData
            }
        }
        defaults.set(data, forKey: profilesKey)
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Whether the stored list holds profiles this version cannot read (kept, not shown).
    static var hasUnreadableProfiles: Bool {
        guard let stored = defaults.data(forKey: profilesKey) else { return false }
        let result = decodeLeniently(stored)
        return !result.isList || !result.unreadable.isEmpty
    }

    static func setActive(_ id: UUID) {
        defaults.set(id.uuidString, forKey: activeProfileKey)
    }

    static func remove(_ id: UUID) {
        let profiles = loadAll().filter { $0.id != id }
        if profiles.isEmpty && !hasUnreadableProfiles {
            clear()
            return
        }
        saveAll(profiles)
        guard let first = profiles.first else {
            // Only profiles this version cannot read are left: they stay stored.
            defaults.removeObject(forKey: activeProfileKey)
            return
        }
        if let activeID = UUID(uuidString: defaults.string(forKey: activeProfileKey) ?? ""), activeID == id {
            setActive(first.id)
        }
    }

    static func clear() {
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: profilesKey)
        defaults.removeObject(forKey: activeProfileKey)
    }
}
