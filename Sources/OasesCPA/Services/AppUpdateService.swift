import Foundation
import AppKit
import Combine
import Darwin
import CryptoKit

#if !APP_STORE

/// Build-time identity of the update channel, read from Info.plist keys that the xcconfig
/// files fill in (`OasesUpdateRepository` = "owner/name", `OasesUpdateTeamIdentifier`) plus
/// the app's own `CFBundleIdentifier`. Without a complete, well-formed identity the updater
/// is disabled: the source carries no release channel of its own.
struct AppUpdateConfiguration: Equatable, Sendable {
    static let repositoryKey = "OasesUpdateRepository"
    static let teamIdentifierKey = "OasesUpdateTeamIdentifier"

    let owner: String
    let repository: String
    let teamIdentifier: String
    let bundleIdentifier: String

    static func fromInfoDictionary(_ info: [String: Any]?) -> AppUpdateConfiguration? {
        guard let info,
              let repositoryValue = trimmed(info[repositoryKey]),
              let teamIdentifier = trimmed(info[teamIdentifierKey]),
              let bundleIdentifier = trimmed(info["CFBundleIdentifier"])
        else { return nil }

        let parts = repositoryValue.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              isValidOwner(parts[0]),
              isValidRepository(parts[1]),
              isValidTeamIdentifier(teamIdentifier),
              isValidBundleIdentifier(bundleIdentifier)
        else { return nil }

        return AppUpdateConfiguration(
            owner: parts[0],
            repository: parts[1],
            teamIdentifier: teamIdentifier,
            bundleIdentifier: bundleIdentifier
        )
    }

    /// `https://api.github.com/repos/<owner>/<repository>/releases/latest`
    var latestReleaseEndpoint: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(owner)/\(repository)/releases/latest"
        return components.url!
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let result = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// GitHub account names: letters, digits and single inner hyphens, at most 39 characters.
    private static func isValidOwner(_ value: String) -> Bool {
        guard (1...39).contains(value.count),
              value.first != "-", value.last != "-",
              !value.contains("--")
        else { return false }
        return value.unicodeScalars.allSatisfy { isASCIIAlphanumeric($0) || $0 == "-" }
    }

    private static func isValidRepository(_ value: String) -> Bool {
        guard (1...100).contains(value.count), value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy { isASCIIAlphanumeric($0) || $0 == "-" || $0 == "_" || $0 == "." }
    }

    /// Apple team identifiers are ten upper-case letters or digits.
    private static func isValidTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        value.count <= 255 && !value.hasPrefix(".") && !value.hasSuffix(".") && !value.contains("..") &&
        value.unicodeScalars.allSatisfy { isASCIIAlphanumeric($0) || $0 == "-" || $0 == "." }
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}

struct SemanticVersion: Codable, Comparable, Hashable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]
    let buildMetadata: [String]

    init?(_ value: String) {
        var value = value
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }

        let build: String?
        let coreAndPrerelease: String
        if let plusIndex = value.firstIndex(of: "+") {
            guard value[value.index(after: plusIndex)...].firstIndex(of: "+") == nil else { return nil }
            coreAndPrerelease = String(value[..<plusIndex])
            build = String(value[value.index(after: plusIndex)...])
        } else {
            coreAndPrerelease = value
            build = nil
        }

        let prerelease: String?
        if let hyphenIndex = coreAndPrerelease.firstIndex(of: "-") {
            prerelease = String(coreAndPrerelease[coreAndPrerelease.index(after: hyphenIndex)...])
            let core = coreAndPrerelease[..<hyphenIndex].split(separator: ".", omittingEmptySubsequences: false)
            guard core.count == 3,
                  let major = Self.parseNumericIdentifier(String(core[0]), allowLeadingZero: false),
                  let minor = Self.parseNumericIdentifier(String(core[1]), allowLeadingZero: false),
                  let patch = Self.parseNumericIdentifier(String(core[2]), allowLeadingZero: false)
            else { return nil }
            self.major = major
            self.minor = minor
            self.patch = patch
        } else {
            prerelease = nil
            let core = coreAndPrerelease.split(separator: ".", omittingEmptySubsequences: false)
            guard core.count == 3,
                  let major = Self.parseNumericIdentifier(String(core[0]), allowLeadingZero: false),
                  let minor = Self.parseNumericIdentifier(String(core[1]), allowLeadingZero: false),
                  let patch = Self.parseNumericIdentifier(String(core[2]), allowLeadingZero: false)
            else { return nil }
            self.major = major
            self.minor = minor
            self.patch = patch
        }

        let parsedPrerelease: [String]
        if let prerelease {
            guard let identifiers = Self.parseIdentifiers(prerelease, rejectLeadingZeroNumeric: true) else { return nil }
            parsedPrerelease = identifiers
        } else {
            parsedPrerelease = []
        }
        self.prerelease = parsedPrerelease

        let parsedBuild: [String]
        if let build {
            guard let identifiers = Self.parseIdentifiers(build, rejectLeadingZeroNumeric: false) else { return nil }
            parsedBuild = identifiers
        } else {
            parsedBuild = []
        }
        self.buildMetadata = parsedBuild
    }

    init?(string: String) {
        self.init(string)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let parsed = SemanticVersion(value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid semantic version"
            )
        }
        self = parsed
    }

    var description: String {
        var value = "\(major).\(minor).\(patch)"
        if !prerelease.isEmpty { value += "-" + prerelease.joined(separator: ".") }
        if !buildMetadata.isEmpty { value += "+" + buildMetadata.joined(separator: ".") }
        return value
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        lhs.major == rhs.major &&
        lhs.minor == rhs.minor &&
        lhs.patch == rhs.patch &&
        lhs.prerelease == rhs.prerelease
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
        hasher.combine(prerelease)
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let coreComparison = [lhs.major, lhs.minor, lhs.patch].lexicographicallyPrecedes(
            [rhs.major, rhs.minor, rhs.patch]
        )
        if lhs.major != rhs.major || lhs.minor != rhs.minor || lhs.patch != rhs.patch {
            return coreComparison
        }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            if left == right { continue }
            let leftIsNumeric = Self.isNumericIdentifier(left)
            let rightIsNumeric = Self.isNumericIdentifier(right)
            switch (leftIsNumeric, rightIsNumeric) {
            case (true, true):
                let leftNormalized = Self.normalizedNumericIdentifier(left)
                let rightNormalized = Self.normalizedNumericIdentifier(right)
                if leftNormalized.count != rightNormalized.count {
                    return leftNormalized.count < rightNormalized.count
                }
                return leftNormalized < rightNormalized
            case (true, false):
                return true
            case (false, true):
                return false
            case (false, false):
                return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func isNumericIdentifier(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    private static func normalizedNumericIdentifier(_ value: String) -> String {
        let normalized = value.drop(while: { $0 == "0" })
        return normalized.isEmpty ? "0" : String(normalized)
    }

    private static func parseIdentifiers(_ value: String, rejectLeadingZeroNumeric: Bool) -> [String]? {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !identifiers.isEmpty else { return nil }
        for identifier in identifiers {
            guard !identifier.isEmpty,
                  identifier.unicodeScalars.allSatisfy({ scalar in
                      scalar.value == 45 || scalar.value == 46 ||
                      (scalar.value >= 48 && scalar.value <= 57) ||
                      (scalar.value >= 65 && scalar.value <= 90) ||
                      (scalar.value >= 97 && scalar.value <= 122)
                  })
            else { return nil }
            if rejectLeadingZeroNumeric,
               identifier.count > 1,
               identifier.allSatisfy(\.isNumber),
               identifier.first == "0" {
                return nil
            }
        }
        return identifiers
    }

    private static func parseNumericIdentifier(_ value: String, allowLeadingZero: Bool) -> Int? {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
              allowLeadingZero || value.count == 1 || value.first != "0"
        else { return nil }
        return Int(value)
    }
}

struct GitHubReleaseAsset: Codable, Equatable {
    let name: String
    let browserDownloadURL: URL
    let digest: String
    let size: Int64

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case digest
        case size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let digest = try container.decode(String.self, forKey: .digest)
        let size = try container.decode(Int64.self, forKey: .size)
        guard digest.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              size >= 0
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .digest,
                in: container,
                debugDescription: "GitHub release asset integrity metadata is invalid"
            )
        }
        self.name = try container.decode(String.self, forKey: .name)
        self.browserDownloadURL = try container.decode(URL.self, forKey: .browserDownloadURL)
        self.digest = digest
        self.size = size
    }

    var sha256Hex: String {
        String(digest.dropFirst("sha256:".count))
    }

    var hasValidIntegrityMetadata: Bool {
        digest.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil && size >= 0
    }
}

struct GitHubRelease: Codable, Equatable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let immutable: Bool?
    let assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case immutable
        case assets
    }
}

struct DMGToolResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
}

protocol DMGToolRunner {
    func run(executable: String, arguments: [String]) throws -> DMGToolResult
}

protocol DMGVerifier {
    func verify(dmgURL: URL) throws
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()
    private var didExceed = false
    private let maximumBytes = 8 * 1024 * 1024

    @discardableResult
    func append(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didExceed else { return true }
        let remaining = maximumBytes - value.count
        if chunk.count > remaining {
            if remaining > 0 {
                value.append(chunk.prefix(remaining))
            }
            didExceed = true
        } else {
            value.append(chunk)
        }
        return didExceed
    }

    func data() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    var exceeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didExceed
    }
}

enum ProcessDMGToolError: LocalizedError {
    case timedOut
    case outputLimitExceeded

    var errorDescription: String? {
        "DMG 验证失败。"
    }
}

struct ProcessDMGToolRunner: DMGToolRunner {
    let timeout: TimeInterval

    init(timeout: TimeInterval = 30) {
        self.timeout = timeout
    }

    func run(executable: String, arguments: [String]) throws -> DMGToolResult {
        guard timeout > 0 else { throw ProcessDMGToolError.timedOut }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let stdoutBuffer = ProcessOutputBuffer()
        let stderrBuffer = ProcessOutputBuffer()
        let drainGroup = DispatchGroup()

        func drain(_ descriptor: Int32, into buffer: ProcessOutputBuffer) {
            drainGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { drainGroup.leave() }
                var bytes = [UInt8](repeating: 0, count: 16 * 1024)
                while true {
                    let count = bytes.withUnsafeMutableBytes { rawBuffer -> Int in
                        guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                        return Darwin.read(descriptor, baseAddress, rawBuffer.count)
                    }
                    if count > 0 {
                        if buffer.append(Data(bytes: bytes, count: count)) {
                            process.terminate()
                            return
                        }
                        continue
                    }
                    if count < 0, errno == EINTR { continue }
                    break
                }
            }
        }

        drain(stdout.fileHandleForReading.fileDescriptor, into: stdoutBuffer)
        drain(stderr.fileHandleForReading.fileDescriptor, into: stderrBuffer)

        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var timedOut = false
        while process.isRunning {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                timedOut = true
                process.terminate()
                let graceDeadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
                while process.isRunning, DispatchTime.now().uptimeNanoseconds < graceDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        if drainGroup.wait(timeout: .now() + .seconds(1)) == .timedOut {
            stdout.fileHandleForReading.closeFile()
            stderr.fileHandleForReading.closeFile()
            _ = drainGroup.wait(timeout: .now() + .seconds(1))
        }
        if stdoutBuffer.exceeded || stderrBuffer.exceeded {
            throw ProcessDMGToolError.outputLimitExceeded
        }
        if timedOut { throw ProcessDMGToolError.timedOut }
        return DMGToolResult(
            status: process.terminationStatus,
            stdout: stdoutBuffer.data(),
            stderr: stderrBuffer.data()
        )
    }
}

enum DMGVerificationError: LocalizedError {
    case invalidImage
    case mountFailed
    case multipleApps
    case unsignedApp
    case wrongIdentity
    case notNotarized
    case detachFailed
    case verificationAndDetachFailed(primary: Error, cleanup: Error)

    var errorDescription: String? {
        "DMG 验证失败。"
    }
}

final class SystemDMGVerifier: DMGVerifier {
    private let configuration: AppUpdateConfiguration
    private let toolRunner: any DMGToolRunner
    private let fileManager = FileManager.default

    /// The mounted app must be signed with the configured bundle and team identifiers.
    init(configuration: AppUpdateConfiguration, toolRunner: any DMGToolRunner = ProcessDMGToolRunner()) {
        self.configuration = configuration
        self.toolRunner = toolRunner
    }

    func verify(dmgURL: URL) throws {
        let attach = try toolRunner.run(
            executable: "/usr/bin/hdiutil",
            arguments: ["attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", dmgURL.path]
        )
        let mountPoints = mountPoints(from: attach.stdout)
        var operationError: Error?
        var detachError: Error?
        do {
            defer { detachError = detach(mountPoints) }
            do {
                guard attach.status == 0, !mountPoints.isEmpty else {
                    throw DMGVerificationError.mountFailed
                }
                try verifyMountedApps(at: mountPoints)
            } catch {
                operationError = error
            }
        }
        if let detachError, let operationError {
            throw DMGVerificationError.verificationAndDetachFailed(primary: operationError, cleanup: detachError)
        }
        if let detachError {
            throw detachError
        }
        if let operationError {
            throw operationError
        }
    }

    private func mountPoints(from data: Data) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return [] }
        return Array(Set(entities.compactMap { $0["mount-point"] as? String })).sorted()
    }

    private func verifyMountedApps(at mountPoints: [String]) throws {
        var apps: [URL] = []
        for mountPoint in mountPoints {
            let root = URL(fileURLWithPath: mountPoint, isDirectory: true)
            let entries = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            for entry in entries where entry.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isDirectory == true && values.isSymbolicLink != true {
                    apps.append(entry)
                }
            }
        }
        guard apps.count == 1 else { throw DMGVerificationError.multipleApps }
        let app = apps[0]

        let codesign = try toolRunner.run(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", app.path]
        )
        guard codesign.status == 0 else { throw DMGVerificationError.unsignedApp }

        let details = try toolRunner.run(
            executable: "/usr/bin/codesign",
            arguments: ["-dv", "--verbose=4", app.path]
        )
        guard details.status == 0 else { throw DMGVerificationError.wrongIdentity }
        let metadata = String(data: details.stdout + details.stderr, encoding: .utf8) ?? ""
        var fields: [String: String] = [:]
        for line in metadata.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            fields[parts[0]] = parts[1]
        }
        guard fields["Identifier"] == configuration.bundleIdentifier,
              fields["TeamIdentifier"] == configuration.teamIdentifier
        else { throw DMGVerificationError.wrongIdentity }

        let spctl = try toolRunner.run(
            executable: "/usr/sbin/spctl",
            arguments: ["--assess", "--type", "execute", "--verbose=4", app.path]
        )
        let assessment = String(data: spctl.stdout + spctl.stderr, encoding: .utf8)?.lowercased() ?? ""
        guard spctl.status == 0, assessment.contains("accepted"), assessment.contains("notarized") else {
            throw DMGVerificationError.notNotarized
        }

        let stapler: DMGToolResult
        if fileManager.isExecutableFile(atPath: "/usr/bin/stapler") {
            stapler = try toolRunner.run(
                executable: "/usr/bin/stapler",
                arguments: ["validate", app.path]
            )
        } else if fileManager.isExecutableFile(atPath: "/usr/bin/xcrun") {
            stapler = try toolRunner.run(
                executable: "/usr/bin/xcrun",
                arguments: ["stapler", "validate", app.path]
            )
        } else {
            throw DMGVerificationError.notNotarized
        }
        guard stapler.status == 0 else { throw DMGVerificationError.notNotarized }
    }

    private func detach(_ mountPoints: [String]) -> Error? {
        var failed = false
        for mountPoint in mountPoints.reversed() {
            do {
                let result = try toolRunner.run(executable: "/usr/bin/hdiutil", arguments: ["detach", mountPoint])
                if result.status == 0 { continue }
                let forced = try toolRunner.run(executable: "/usr/bin/hdiutil", arguments: ["detach", mountPoint, "-force"])
                if forced.status == 0 { continue }
            } catch {
                failed = true
                continue
            }
            failed = true
        }
        return failed ? DMGVerificationError.detachFailed : nil
    }
}

/// Used only when no update channel is configured: nothing can pass verification.
private struct UnconfiguredDMGVerifier: DMGVerifier {
    func verify(dmgURL: URL) throws {
        throw DMGVerificationError.wrongIdentity
    }
}

enum AppUpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable
    case releaseWithoutDMG
    case downloading
    case downloaded
    case failed
}

@MainActor
final class AppUpdateService: ObservableObject {
    static let maximumDMGSize: Int64 = 2 * 1024 * 1024 * 1024

    @Published private(set) var status: AppUpdateStatus = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var latestRelease: GitHubRelease?
    @Published private(set) var availableUpdateVersion: SemanticVersion?
    @Published private(set) var selectedDMGAsset: GitHubReleaseAsset?
    @Published private(set) var downloadedFileURL: URL?

    let configuration: AppUpdateConfiguration?
    private let endpoint: URL?
    private let currentVersion: SemanticVersion?
    private let session: URLSession
    private let downloadsDirectory: URL
    private let verifier: any DMGVerifier
    private let openFile: (URL) -> Void
    private let fileManager = FileManager.default
    private var monitoringTask: Task<Void, Never>?
    private var downloadedAsset: GitHubReleaseAsset?

    /// False when the build carries no update channel; the updater then never touches the network.
    var isEnabled: Bool {
        configuration != nil
    }

    var latestTag: String? {
        latestRelease?.tagName
    }

    var isUpdateAvailable: Bool {
        availableUpdateVersion != nil && selectedDMGAsset != nil
    }

    var canDownloadUpdate: Bool {
        isUpdateAvailable && status != .downloading
    }

    /// - Parameters:
    ///   - configuration: the update channel; `nil` disables the updater.
    ///   - endpoint: overrides `configuration.latestReleaseEndpoint` (tests).
    ///   - verifier: defaults to `SystemDMGVerifier` for the configured identity.
    init(
        configuration: AppUpdateConfiguration? = .fromInfoDictionary(Bundle.main.infoDictionary),
        endpoint: URL? = nil,
        currentVersion: SemanticVersion? = nil,
        session: URLSession = .shared,
        downloadsDirectory: URL? = nil,
        verifier: (any DMGVerifier)? = nil,
        openFile: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) {
        self.configuration = configuration
        self.endpoint = configuration.map { endpoint ?? $0.latestReleaseEndpoint }
        self.currentVersion = currentVersion ?? Self.bundleCurrentVersion()
        self.session = session
        self.downloadsDirectory = downloadsDirectory ?? fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        if let verifier {
            self.verifier = verifier
        } else if let configuration {
            self.verifier = SystemDMGVerifier(configuration: configuration)
        } else {
            self.verifier = UnconfiguredDMGVerifier()
        }
        self.openFile = openFile
    }

    /// Starts one app-lifetime update loop. The task is owned by this service,
    /// so closing the main window does not stop background release checks.
    func startMonitoring(interval: Duration = .seconds(15 * 60)) {
        guard isEnabled, monitoringTask == nil else { return }
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.checkForUpdates()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
            }
        }
    }

    func checkForUpdates() async {
        guard let endpoint, status != .checking, status != .downloading else { return }
        status = .checking
        errorMessage = nil
        availableUpdateVersion = nil
        selectedDMGAsset = nil
        downloadedAsset = nil
        downloadedFileURL = nil

        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            try validateHTTPResponse(response)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            latestRelease = release

            guard !release.draft, !release.prerelease,
                  let releaseVersion = SemanticVersion(release.tagName),
                  let currentVersion,
                  currentVersion < releaseVersion
            else {
                status = .upToDate
                return
            }

            availableUpdateVersion = releaseVersion
            selectedDMGAsset = release.assets.first(where: isAllowedDMGAsset)
            if selectedDMGAsset == nil {
                status = .releaseWithoutDMG
            } else {
                status = .updateAvailable
            }
        } catch {
            status = .failed
            errorMessage = userFacingError(for: error)
        }
    }

    func downloadAvailableUpdate() async {
        guard canDownloadUpdate, let asset = selectedDMGAsset else { return }
        status = .downloading
        errorMessage = nil

        do {
            guard isAllowedDMGAsset(asset) else {
                throw AppUpdateError.invalidDownloadURL
            }
            guard asset.size <= Self.maximumDMGSize else {
                throw AppUpdateError.downloadTooLarge
            }
            var request = URLRequest(url: asset.browserDownloadURL)
            request.httpMethod = "GET"
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            try validateHTTPResponse(response)
            guard let finalURL = response.url, isAllowedRedirectURL(finalURL) else {
                throw AppUpdateError.invalidRedirectURL
            }
            try validateDownloadedFilename(response)

            let reservation = try reserveDestination(named: asset.name)
            var output: FileHandle? = FileHandle(fileDescriptor: reservation.descriptor, closeOnDealloc: true)
            do {
                var hasher = SHA256()
                var received: Int64 = 0
                var buffer = Data()

                func writeBuffer() throws {
                    guard !buffer.isEmpty else { return }
                    received += Int64(buffer.count)
                    guard received <= Self.maximumDMGSize, received <= asset.size else {
                        throw AppUpdateError.downloadTooLarge
                    }
                    hasher.update(data: buffer)
                    try output?.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }

                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count >= 1_048_576 {
                        try writeBuffer()
                    }
                }
                try writeBuffer()
                guard received == asset.size else {
                    throw AppUpdateError.downloadSizeMismatch
                }
                let actualDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                guard actualDigest == asset.sha256Hex else {
                    throw AppUpdateError.downloadDigestMismatch
                }
                try output?.synchronize()
                try output?.close()
                output = nil

                let validatedIdentity = try verifyDownloadedFile(at: reservation.url, expected: asset)
                guard try fileIdentity(at: reservation.url) == validatedIdentity else {
                    throw AppUpdateError.downloadedFileChanged
                }
            } catch {
                try? output?.close()
                try? fileManager.removeItem(at: reservation.url)
                if !reservation.directoryExisted,
                   let contents = try? fileManager.contentsOfDirectory(at: downloadsDirectory, includingPropertiesForKeys: nil),
                   contents.isEmpty {
                    try? fileManager.removeItem(at: downloadsDirectory)
                }
                throw error
            }
            downloadedAsset = asset
            downloadedFileURL = reservation.url
            status = .downloaded
            openDownloadedUpdate()
        } catch {
            status = .failed
            errorMessage = userFacingError(for: error)
        }
    }

    func openDownloadedUpdate() {
        guard let downloadedFileURL,
              let downloadedAsset
        else { return }
        do {
            let validatedIdentity = try verifyDownloadedFile(at: downloadedFileURL, expected: downloadedAsset)
            guard try fileIdentity(at: downloadedFileURL) == validatedIdentity else {
                throw AppUpdateError.downloadedFileChanged
            }
            // NSWorkspace accepts a URL path, so keep the final identity check immediately before opening.
            openFile(downloadedFileURL)
        } catch {
            status = .failed
            errorMessage = userFacingError(for: error)
        }
    }

    private func verifyDownloadedFile(at url: URL, expected asset: GitHubReleaseAsset) throws -> DMGFileIdentity {
        let first = try hashAndIdentity(at: url, expectedSize: asset.size)
        guard first.digest == asset.sha256Hex else {
            throw AppUpdateError.downloadDigestMismatch
        }
        try verifier.verify(dmgURL: url)
        let second = try hashAndIdentity(at: url, expectedSize: asset.size)
        guard second.identity == first.identity, second.digest == asset.sha256Hex else {
            throw AppUpdateError.downloadedFileChanged
        }
        return second.identity
    }

    private struct DMGFileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }

    private struct HashedFile {
        let identity: DMGFileIdentity
        let digest: String
    }

    private func fileIdentity(at url: URL) throws -> DMGFileIdentity {
        var info = stat()
        let result = url.path.withCString { Darwin.lstat($0, &info) }
        guard result == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw AppUpdateError.downloadedFileChanged
        }
        return DMGFileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            modificationSeconds: Int64(info.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec)
        )
    }

    private func hashAndIdentity(at url: URL, expectedSize: Int64) throws -> HashedFile {
        let before = try fileIdentity(at: url)
        guard before.size == expectedSize, expectedSize <= Self.maximumDMGSize else {
            throw AppUpdateError.downloadSizeMismatch
        }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw AppUpdateError.downloadedFileChanged }
        defer { Darwin.close(descriptor) }

        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG
        else { throw AppUpdateError.downloadedFileChanged }
        let openedIdentity = DMGFileIdentity(
            device: UInt64(opened.st_dev),
            inode: UInt64(opened.st_ino),
            size: Int64(opened.st_size),
            modificationSeconds: Int64(opened.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(opened.st_mtimespec.tv_nsec)
        )
        guard openedIdentity == before else { throw AppUpdateError.downloadedFileChanged }

        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var hasher = SHA256()
        var total: Int64 = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            total += Int64(chunk.count)
            guard total <= Self.maximumDMGSize, total <= expectedSize else {
                throw AppUpdateError.downloadTooLarge
            }
            hasher.update(data: chunk)
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0 else {
            throw AppUpdateError.downloadedFileChanged
        }
        let afterIdentity = DMGFileIdentity(
            device: UInt64(after.st_dev),
            inode: UInt64(after.st_ino),
            size: Int64(after.st_size),
            modificationSeconds: Int64(after.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(after.st_mtimespec.tv_nsec)
        )
        guard total == expectedSize, afterIdentity == before else {
            throw AppUpdateError.downloadedFileChanged
        }
        return HashedFile(
            identity: afterIdentity,
            digest: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    private func isAllowedDMGAsset(_ asset: GitHubReleaseAsset) -> Bool {
        asset.hasValidIntegrityMetadata &&
        URL(fileURLWithPath: asset.name).pathExtension.caseInsensitiveCompare("dmg") == .orderedSame &&
        asset.browserDownloadURL.pathExtension.caseInsensitiveCompare("dmg") == .orderedSame &&
        isOfficialAssetURL(asset.browserDownloadURL)
    }

    private func isOfficialAssetURL(_ url: URL) -> Bool {
        guard let configuration,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com"
        else { return false }

        let encodedPath = url.path(percentEncoded: true).lowercased()
        guard !encodedPath.contains("%2e%2e"),
              !encodedPath.contains("%2f"),
              !encodedPath.contains("%5c")
        else { return false }

        let components = url.pathComponents
        guard components.count == 7,
              components[0] == "/",
              components[1] == configuration.owner,
              components[2] == configuration.repository,
              components[3] == "releases",
              components[4] == "download",
              components[5] != ".",
              components[5] != "..",
              components[6] != ".",
              components[6] != "..",
              components[5].isEmpty == false,
              components[6].isEmpty == false,
              !components[5].contains("/"),
              !components[5].contains("\\"),
              !components[6].contains("/"),
              !components[6].contains("\\")
        else { return false }

        return URL(fileURLWithPath: components[6]).pathExtension.caseInsensitiveCompare("dmg") == .orderedSame
    }

    private func isAllowedRedirectURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }
        if host == "github.com" {
            return isOfficialAssetURL(url)
        }
        return host == "release-assets.githubusercontent.com"
    }

    private func validateDownloadedFilename(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              let contentDisposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition"),
              let suggestedFilename = suggestedFilename(from: contentDisposition),
              URL(fileURLWithPath: suggestedFilename).pathExtension.caseInsensitiveCompare("dmg") == .orderedSame
        else {
            throw AppUpdateError.invalidDownloadFilename
        }
    }

    private func suggestedFilename(from contentDisposition: String) -> String? {
        for component in contentDisposition.split(separator: ";", omittingEmptySubsequences: true) {
            let part = component.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = part.lowercased()
            let value: String
            if lowercased.hasPrefix("filename*=") {
                value = String(part.dropFirst("filename*=".count))
                let encoded = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false).last.map(String.init) ?? value
                return removingQuotes(encoded).removingPercentEncoding
            }
            if lowercased.hasPrefix("filename=") {
                value = String(part.dropFirst("filename=".count))
                return removingQuotes(value)
            }
        }
        return nil
    }

    private func removingQuotes(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else { return value }
        return String(value.dropFirst().dropLast())
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw AppUpdateError.httpStatus(statusCode)
        }
    }

    private struct DestinationReservation {
        let url: URL
        let descriptor: Int32
        let directoryExisted: Bool
    }

    private func reserveDestination(named assetName: String) throws -> DestinationReservation {
        let filename = URL(fileURLWithPath: assetName).lastPathComponent
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: filename).pathExtension
        guard !base.isEmpty, ext.caseInsensitiveCompare("dmg") == .orderedSame else {
            throw AppUpdateError.invalidDownloadURL
        }
        let directoryExisted = fileManager.fileExists(atPath: downloadsDirectory.path)
        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

        var index = 0
        while true {
            let suffix = index == 0 ? "" : " (\(index))"
            let candidate = downloadsDirectory.appendingPathComponent("\(base)\(suffix).\(ext)")
            let descriptor = candidate.path.withCString {
                Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            }
            if descriptor >= 0 {
                return DestinationReservation(url: candidate, descriptor: descriptor, directoryExisted: directoryExisted)
            }
            let errorNumber = errno
            guard errorNumber == EEXIST else {
                if !directoryExisted,
                   let contents = try? fileManager.contentsOfDirectory(at: downloadsDirectory, includingPropertiesForKeys: nil),
                   contents.isEmpty {
                    try? fileManager.removeItem(at: downloadsDirectory)
                }
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errorNumber),
                    userInfo: [NSLocalizedDescriptionKey: "无法创建下载文件。"]
                )
            }
            index += 1
        }
    }

    private static func bundleCurrentVersion() -> SemanticVersion? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
            return nil
        }
        return SemanticVersion(value)
    }

    private var userAgent: String {
        "OasesCPA/\(currentVersion?.description ?? "unknown") (macOS)"
    }

    private func userFacingError(for error: Error) -> String {
        if let updateError = error as? AppUpdateError {
            return updateError.errorDescription ?? OasesLocalization.localized("更新失败。")
        }
        return error.localizedDescription
    }
}

private enum AppUpdateError: LocalizedError {
    case httpStatus(Int)
    case invalidDownloadURL
    case invalidRedirectURL
    case invalidDownloadFilename
    case downloadTooLarge
    case downloadSizeMismatch
    case downloadDigestMismatch
    case downloadedFileChanged

    var errorDescription: String? {
        switch self {
        case let .httpStatus(statusCode):
            return OasesLocalization.localizedFormat("更新服务器返回了 HTTP %lld。", statusCode)
        case .downloadTooLarge, .downloadSizeMismatch, .downloadDigestMismatch,
             .downloadedFileChanged:
            return OasesLocalization.localized("更新包完整性验证失败。")
        case .invalidDownloadURL:
            return OasesLocalization.localized("未找到受信任的 DMG 下载地址。")
        case .invalidRedirectURL:
            return OasesLocalization.localized("DMG 下载被重定向到不受信任的地址。")
        case .invalidDownloadFilename:
            return OasesLocalization.localized("下载响应未声明受信任的 DMG 文件名。")
        }
    }
}

#endif
