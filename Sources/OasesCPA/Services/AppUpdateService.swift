import Foundation
import AppKit
import Combine
import Darwin

#if !APP_STORE

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

    private enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

struct GitHubRelease: Codable, Equatable {
    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let assets: [GitHubReleaseAsset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case assets
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
    static let officialEndpoint = URL(string: "https://api.github.com/repos/qingtengCHINA/OasesCPA-Desktop/releases/latest")!
    static let defaultEndpoint = officialEndpoint

    @Published private(set) var status: AppUpdateStatus = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var latestRelease: GitHubRelease?
    @Published private(set) var availableUpdateVersion: SemanticVersion?
    @Published private(set) var selectedDMGAsset: GitHubReleaseAsset?
    @Published private(set) var downloadedFileURL: URL?

    private let endpoint: URL
    private let currentVersion: SemanticVersion?
    private let session: URLSession
    private let downloadsDirectory: URL
    private let openFile: (URL) -> Void
    private let fileManager = FileManager.default
    private var monitoringTask: Task<Void, Never>?

    var latestTag: String? {
        latestRelease?.tagName
    }

    var isUpdateAvailable: Bool {
        availableUpdateVersion != nil && selectedDMGAsset != nil
    }

    var canDownloadUpdate: Bool {
        isUpdateAvailable && status != .downloading
    }

    init(
        endpoint: URL = AppUpdateService.officialEndpoint,
        currentVersion: SemanticVersion? = nil,
        session: URLSession = .shared,
        downloadsDirectory: URL? = nil,
        openFile: @escaping (URL) -> Void = { _ = NSWorkspace.shared.open($0) }
    ) {
        self.endpoint = endpoint
        self.currentVersion = currentVersion ?? Self.bundleCurrentVersion()
        self.session = session
        self.downloadsDirectory = downloadsDirectory ?? fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        self.openFile = openFile
    }

    /// Starts one app-lifetime update loop. The task is owned by this service,
    /// so closing the main window does not stop background release checks.
    func startMonitoring(interval: Duration = .seconds(15 * 60)) {
        guard monitoringTask == nil else { return }
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
        guard status != .checking, status != .downloading else { return }
        status = .checking
        errorMessage = nil
        availableUpdateVersion = nil
        selectedDMGAsset = nil

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
            var request = URLRequest(url: asset.browserDownloadURL)
            request.httpMethod = "GET"
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let (temporaryURL, response) = try await session.download(for: request)
            try validateHTTPResponse(response)
            guard let finalURL = response.url, isAllowedRedirectURL(finalURL) else {
                throw AppUpdateError.invalidRedirectURL
            }
            try validateDownloadedFilename(response)

            let destination = try reserveDestination(named: asset.name)
            do {
                try copyDownloadedFile(from: temporaryURL, to: destination)
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
            downloadedFileURL = destination
            status = .downloaded
            openFile(destination)
        } catch {
            status = .failed
            errorMessage = userFacingError(for: error)
        }
    }

    private func copyDownloadedFile(from source: URL, to destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }

        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
    }

    func openDownloadedUpdate() {
        guard let downloadedFileURL,
              fileManager.fileExists(atPath: downloadedFileURL.path)
        else { return }
        openFile(downloadedFileURL)
    }

    private func isAllowedDMGAsset(_ asset: GitHubReleaseAsset) -> Bool {
        URL(fileURLWithPath: asset.name).pathExtension.caseInsensitiveCompare("dmg") == .orderedSame &&
        asset.browserDownloadURL.pathExtension.caseInsensitiveCompare("dmg") == .orderedSame &&
        isOfficialAssetURL(asset.browserDownloadURL)
    }

    private func isOfficialAssetURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
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
              components[1] == "qingtengCHINA",
              components[2] == "OasesCPA-Desktop",
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

    private func reserveDestination(named assetName: String) throws -> URL {
        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        let filename = URL(fileURLWithPath: assetName).lastPathComponent
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: filename).pathExtension
        guard !base.isEmpty, ext.caseInsensitiveCompare("dmg") == .orderedSame else {
            throw AppUpdateError.invalidDownloadURL
        }

        var index = 0
        while true {
            let suffix = index == 0 ? "" : " (\(index))"
            let candidate = downloadsDirectory.appendingPathComponent("\(base)\(suffix).\(ext)")
            let descriptor = Darwin.open(candidate.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if descriptor >= 0 {
                Darwin.close(descriptor)
                return candidate
            }
            guard errno == EEXIST else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
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

    var errorDescription: String? {
        switch self {
        case let .httpStatus(statusCode):
            return OasesLocalization.localizedFormat("更新服务器返回了 HTTP %lld。", statusCode)
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
