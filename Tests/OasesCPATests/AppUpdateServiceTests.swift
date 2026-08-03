import XCTest
import Foundation
@testable import OasesCPA

@MainActor
final class AppUpdateServiceTests: XCTestCase {
    func testSemanticVersionComparesSemVerPreReleaseAndBuildMetadata() throws {
        let alpha = try XCTUnwrap(SemanticVersion("1.0.0-alpha"))
        let beta = try XCTUnwrap(SemanticVersion("v1.0.0-beta.1"))
        let release = try XCTUnwrap(SemanticVersion("1.0.0"))
        let releaseWithBuild = try XCTUnwrap(SemanticVersion("1.0.0+build.7"))

        XCTAssertLessThan(alpha, beta)
        XCTAssertLessThan(beta, release)
        XCTAssertEqual(release, releaseWithBuild)
        XCTAssertEqual(SemanticVersion("0.1.0"), SemanticVersion("v0.1.0"))
        XCTAssertNil(SemanticVersion("not-a-version"))
    }

    func testSemanticVersionPreReleasePriorityMatchesSemVerAndSupportsArbitraryLengthNumbers() throws {
        let versions = try [
            "1.0.0-alpha",
            "1.0.0-alpha.1",
            "1.0.0-alpha.beta",
            "1.0.0-beta",
            "1.0.0-beta.2",
            "1.0.0-beta.11",
            "1.0.0-rc.1",
            "1.0.0"
        ].map { try XCTUnwrap(SemanticVersion($0)) }

        for pair in zip(versions, versions.dropFirst()) {
            XCTAssertLessThan(pair.0, pair.1)
        }

        let veryLargeNumericIdentifier = try XCTUnwrap(SemanticVersion("1.0.0-999999999999999999999"))
        let smallNumericIdentifier = try XCTUnwrap(SemanticVersion("1.0.0-2"))
        XCTAssertGreaterThan(veryLargeNumericIdentifier, smallNumericIdentifier)
    }

    func testSemanticVersionHashIgnoresBuildMetadataLikeEquality() throws {
        let plain = try XCTUnwrap(SemanticVersion("1.0.0"))
        let withBuild = try XCTUnwrap(SemanticVersion("v1.0.0+build.7"))

        XCTAssertEqual(plain, withBuild)
        XCTAssertEqual(Set([plain, withBuild]).count, 1)
    }

    func testCurrentVersionEqualToTagIsUpToDate() async throws {
        let session = makeSession { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "OasesCPA/0.1.0 (macOS)")
            return self.response(for: request, json: self.releaseJSON(tag: "v0.1.0", assets: [self.asset("OasesCPA.dmg")]))
        }
        let service = AppUpdateService(
            endpoint: URL(string: "https://api.github.test/releases/latest")!,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: temporaryDirectory()
        )

        await service.checkForUpdates()

        XCTAssertEqual(service.status, .upToDate)
        XCTAssertFalse(service.isUpdateAvailable)
        XCTAssertEqual(service.latestTag, "v0.1.0")
    }

    func testOfficialEndpointConstantIsStable() {
        XCTAssertEqual(
            AppUpdateService.officialEndpoint.absoluteString,
            "https://api.github.com/repos/qingtengCHINA/OasesCPA-Desktop/releases/latest"
        )
        XCTAssertEqual(AppUpdateService.defaultEndpoint, AppUpdateService.officialEndpoint)
    }

    func testOlderCurrentVersionReportsUpdateAvailable() async {
        let session = makeSession { request in
            self.response(for: request, json: self.releaseJSON(tag: "v0.2.0", assets: [self.asset("OasesCPA.dmg")]))
        }
        let service = AppUpdateService(
            endpoint: URL(string: "https://api.github.test/releases/latest")!,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: temporaryDirectory()
        )

        await service.checkForUpdates()

        XCTAssertEqual(service.status, .updateAvailable)
        XCTAssertTrue(service.isUpdateAvailable)
        XCTAssertEqual(service.availableUpdateVersion, SemanticVersion("0.2.0"))
    }

    func testInvalidTagDoesNotReportAnUpdate() async {
        let session = makeSession { request in
            self.response(for: request, json: self.releaseJSON(tag: "release-latest", assets: [self.asset("OasesCPA.dmg")]))
        }
        let service = AppUpdateService(
            endpoint: URL(string: "https://api.github.test/releases/latest")!,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: temporaryDirectory()
        )

        await service.checkForUpdates()

        XCTAssertEqual(service.status, .upToDate)
        XCTAssertFalse(service.isUpdateAvailable)
        XCTAssertNil(service.availableUpdateVersion)
    }

    func testDraftAndPrereleaseAreIgnored() async {
        for (draft, prerelease) in [(true, false), (false, true)] {
            let session = makeSession { request in
                self.response(
                    for: request,
                    json: self.releaseJSON(
                        tag: "v9.0.0",
                        assets: [self.asset("OasesCPA.dmg")],
                        draft: draft,
                        prerelease: prerelease
                    )
                )
            }
            let service = AppUpdateService(
                endpoint: URL(string: "https://api.github.test/releases/latest")!,
                currentVersion: SemanticVersion("0.1.0"),
                session: session,
                downloadsDirectory: temporaryDirectory()
            )

            await service.checkForUpdates()

            XCTAssertEqual(service.status, .upToDate)
            XCTAssertFalse(service.isUpdateAvailable)
        }
    }

    func testNewReleaseWithoutDMGIsNotDownloadable() async {
        let session = makeSession { request in
            self.response(for: request, json: self.releaseJSON(tag: "v0.2.0", assets: [self.asset("OasesCPA.zip")]))
        }
        let service = AppUpdateService(
            endpoint: URL(string: "https://api.github.test/releases/latest")!,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: temporaryDirectory()
        )

        await service.checkForUpdates()

        XCTAssertEqual(service.status, .releaseWithoutDMG)
        XCTAssertFalse(service.isUpdateAvailable)
    }

    func testAssetFromAnotherRepositoryIsRejected() async {
        let session = makeSession { request in
            self.response(
                for: request,
                json: self.releaseJSON(
                    tag: "v0.2.0",
                    assets: [self.asset("OasesCPA.dmg", url: "https://github.com/another-owner/other-repo/releases/download/v0.2.0/OasesCPA.dmg")]
                )
            )
        }
        let service = AppUpdateService(
            endpoint: URL(string: "https://api.github.test/releases/latest")!,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: temporaryDirectory()
        )

        await service.checkForUpdates()

        XCTAssertEqual(service.status, .releaseWithoutDMG)
        XCTAssertNil(service.selectedDMGAsset)
    }

    func testDMGAssetURLRequiresHTTPSExactHostRepositoryPathAndSupportsQueryAndCase() async {
        let validURL = "https://github.com/qingtengCHINA/OasesCPA-Desktop/releases/download/v0.2.0/OasesCPA.DMG?download=1"
        let session = makeSession { request in
            self.response(
                for: request,
                json: self.releaseJSON(tag: "v0.2.0", assets: [self.asset("OasesCPA.DMG", url: validURL)])
            )
        }
        let service = makeService(session: session)

        await service.checkForUpdates()

        XCTAssertEqual(service.status, .updateAvailable)
        XCTAssertTrue(service.isUpdateAvailable)
    }

    func testDMGAssetURLRejectsIllegalSchemeHostAndPath() async {
        let invalidURLs = [
            "http://github.com/qingtengCHINA/OasesCPA-Desktop/releases/download/v0.2.0/OasesCPA.dmg",
            "https://evil.example/qingtengCHINA/OasesCPA-Desktop/releases/download/v0.2.0/OasesCPA.dmg",
            "https://github.com/another-owner/OasesCPA-Desktop/releases/download/v0.2.0/OasesCPA.dmg",
            "https://github.com/qingtengCHINA/OasesCPA-Desktop/releases/downloads/v0.2.0/OasesCPA.dmg",
            "https://github.com/qingtengCHINA/OasesCPA-Desktop/releases/download/v0.2.0/OasesCPA.zip",
            "https://github.com/qingtengCHINA/OasesCPA-Desktop/releases/download/v0.2.0/../OasesCPA.dmg",
            "https://github.com/qingtengCHINA/OasesCPA-Desktop/releases/download/v0.2.0/%2E%2EOasesCPA.dmg",
            "https://github.com/qingtengCHINA/OasesCPA-Desktop/releases/download/v0.2.0/%2FOasesCPA.dmg"
        ]

        for invalidURL in invalidURLs {
            let session = makeSession { request in
                self.response(
                    for: request,
                    json: self.releaseJSON(tag: "v0.2.0", assets: [self.asset("OasesCPA.dmg", url: invalidURL)])
                )
            }
            let service = makeService(session: session)

            await service.checkForUpdates()

            XCTAssertEqual(service.status, .releaseWithoutDMG, invalidURL)
            XCTAssertFalse(service.isUpdateAvailable, invalidURL)
        }
    }

    func testDownloadDoesNotOverwriteExistingFileAndCallsOpenCallback() async throws {
        let directory = temporaryDirectory()
        let existingURL = directory.appendingPathComponent("OasesCPA.dmg")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: existingURL)
        var openedURL: URL?
        let session = makeSession { request in
            if request.url?.path == "/releases/latest" {
                return self.response(for: request, json: self.releaseJSON(tag: "v0.2.0", assets: [self.asset("OasesCPA.dmg")]))
            }
            return self.response(
                for: request,
                data: Data("new".utf8),
                url: URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/12345")!,
                headerFields: ["Content-Disposition": "attachment; filename=OasesCPA.dmg"]
            )
        }
        let service = AppUpdateService(
            endpoint: URL(string: "https://api.github.test/releases/latest")!,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: directory,
            openFile: { openedURL = $0 }
        )

        await service.checkForUpdates()
        await service.downloadAvailableUpdate()

        let downloadedURL = try XCTUnwrap(service.downloadedFileURL)
        XCTAssertEqual(service.status, .downloaded)
        XCTAssertNotEqual(downloadedURL, existingURL)
        XCTAssertEqual(try Data(contentsOf: existingURL), Data("old".utf8))
        XCTAssertEqual(try Data(contentsOf: downloadedURL), Data("new".utf8))
        XCTAssertEqual(openedURL, downloadedURL)
    }

    func testDownloadAcceptsReleaseAssetsRedirectWithoutDMGPathExtensionWhenFilenameIsDMG() async throws {
        let session = makeSession { request in
            if request.url?.path == "/releases/latest" {
                return self.response(for: request, json: self.releaseJSON(tag: "v0.2.0", assets: [self.asset("OasesCPA.dmg")]))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "OasesCPA/0.1.0 (macOS)")
            return self.response(
                for: request,
                data: Data("new".utf8),
                url: URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/12345")!,
                headerFields: ["Content-Disposition": "attachment; filename=OasesCPA.dmg"]
            )
        }
        let service = makeService(session: session)

        await service.checkForUpdates()
        await service.downloadAvailableUpdate()

        XCTAssertEqual(service.status, .downloaded)
    }

    func testDownloadFollows302ToTrustedReleaseAssetsURL() async {
        let finalURL = URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/302")!
        let session = makeSession { request in
            if request.url?.path == "/releases/latest" {
                return self.response(for: request, json: self.releaseJSON(tag: "v0.2.0", assets: [self.asset("OasesCPA.dmg")]))
            }
            if request.url?.host == "github.com" {
                return self.response(
                    for: request,
                    statusCode: 302,
                    data: Data(),
                    url: request.url,
                    headerFields: ["Location": finalURL.absoluteString],
                    redirectURL: finalURL
                )
            }
            return self.response(
                for: request,
                data: Data("new".utf8),
                url: finalURL,
                headerFields: ["Content-Disposition": "attachment; filename=OasesCPA.dmg"]
            )
        }
        let service = makeService(session: session)

        await service.checkForUpdates()
        await service.downloadAvailableUpdate()

        XCTAssertEqual(service.status, .downloaded)
    }

    func testDownloadRejectsReleaseAssetsRedirectWithNonDMGFilename() async {
        var openCount = 0
        let session = makeSession { request in
            if request.url?.path == "/releases/latest" {
                return self.response(for: request, json: self.releaseJSON(tag: "v0.2.0", assets: [self.asset("OasesCPA.dmg")]))
            }
            return self.response(
                for: request,
                data: Data("not a dmg".utf8),
                url: URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/12345")!,
                headerFields: ["Content-Disposition": "attachment; filename=OasesCPA.zip"]
            )
        }
        let service = AppUpdateService(
            endpoint: URL(string: "https://api.github.test/releases/latest")!,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: temporaryDirectory(),
            openFile: { _ in openCount += 1 }
        )

        await service.checkForUpdates()
        await service.downloadAvailableUpdate()

        XCTAssertEqual(service.status, .failed)
        XCTAssertNil(service.downloadedFileURL)
        XCTAssertFalse(service.errorMessage?.isEmpty ?? true)
        XCTAssertEqual(openCount, 0)
    }

    func testDownloadRejectsTrustedReleaseAssetsWithoutContentDisposition() async {
        var openCount = 0
        let session = makeSession { request in
            if request.url?.path == "/releases/latest" {
                return self.response(for: request, json: self.releaseJSON(tag: "v0.2.0", assets: [self.asset("OasesCPA.dmg")]))
            }
            return self.response(
                for: request,
                data: Data("not a dmg".utf8),
                url: URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/12345")!
            )
        }
        let service = AppUpdateService(
            endpoint: URL(string: "https://api.github.test/releases/latest")!,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: temporaryDirectory(),
            openFile: { _ in openCount += 1 }
        )

        await service.checkForUpdates()
        await service.downloadAvailableUpdate()

        XCTAssertEqual(service.status, .failed)
        XCTAssertFalse(service.errorMessage?.isEmpty ?? true)
        XCTAssertEqual(openCount, 0)
    }

    func testDownloadRejectsNonHTTPSOrNonReleaseAssetsFinalURL() async {
        let finalURLs = [
            "https://evil.example/OasesCPA.dmg",
            "http://release-assets.githubusercontent.com/github-production-release-asset/12345"
        ]

        for finalURL in finalURLs {
            var openCount = 0
            let session = makeSession { request in
                if request.url?.path == "/releases/latest" {
                    return self.response(for: request, json: self.releaseJSON(tag: "v0.2.0", assets: [self.asset("OasesCPA.dmg")]))
                }
                return self.response(
                    for: request,
                    data: Data("not a dmg".utf8),
                    url: URL(string: finalURL)!,
                    headerFields: ["Content-Disposition": "attachment; filename=OasesCPA.dmg"]
                )
            }
            let service = AppUpdateService(
                endpoint: URL(string: "https://api.github.test/releases/latest")!,
                currentVersion: SemanticVersion("0.1.0"),
                session: session,
                downloadsDirectory: temporaryDirectory(),
                openFile: { _ in openCount += 1 }
            )

            await service.checkForUpdates()
            await service.downloadAvailableUpdate()

            XCTAssertEqual(service.status, .failed, finalURL)
            XCTAssertEqual(openCount, 0, finalURL)
        }
    }

    func testHTTPErrorProducesFailedStatusAndErrorMessage() async {
        let session = makeSession { request in
            self.response(for: request, statusCode: 500, data: Data("server error".utf8))
        }
        let service = AppUpdateService(
            endpoint: URL(string: "https://api.github.test/releases/latest")!,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: temporaryDirectory()
        )

        await service.checkForUpdates()

        XCTAssertEqual(service.status, .failed)
        XCTAssertFalse(service.errorMessage?.isEmpty ?? true)
    }

    func testDownloadHTTPErrorProducesFailedStatusAndDoesNotCreateFile() async {
        var openCount = 0
        let session = makeSession { request in
            if request.url?.path == "/releases/latest" {
                return self.response(for: request, json: self.releaseJSON(tag: "v0.2.0", assets: [self.asset("OasesCPA.dmg")]))
            }
            return self.response(
                for: request,
                statusCode: 503,
                data: Data("unavailable".utf8),
                url: URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/12345")!,
                headerFields: ["Content-Disposition": "attachment; filename=OasesCPA.dmg"]
            )
        }
        let directory = temporaryDirectory()
        let service = AppUpdateService(
            endpoint: URL(string: "https://api.github.test/releases/latest")!,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: directory,
            openFile: { _ in openCount += 1 }
        )

        await service.checkForUpdates()
        await service.downloadAvailableUpdate()

        XCTAssertEqual(service.status, .failed)
        XCTAssertNil(service.downloadedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(openCount, 0)
    }

    func testDownloadRejectsRedirectedNonGitHubURL() async {
        var openCount = 0
        let session = makeSession { request in
            if request.url?.path == "/releases/latest" {
                return self.response(for: request, json: self.releaseJSON(tag: "v0.2.0", assets: [self.asset("OasesCPA.dmg")]))
            }
            return self.response(
                for: request,
                data: Data("not a dmg".utf8),
                url: URL(string: "https://evil.example.invalid/OasesCPA.dmg")!
            )
        }
        let service = AppUpdateService(
            endpoint: URL(string: "https://api.github.test/releases/latest")!,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: temporaryDirectory(),
            openFile: { _ in openCount += 1 }
        )

        await service.checkForUpdates()
        await service.downloadAvailableUpdate()

        XCTAssertEqual(service.status, .failed)
        XCTAssertNil(service.downloadedFileURL)
        XCTAssertFalse(service.errorMessage?.isEmpty ?? true)
        XCTAssertEqual(openCount, 0)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeService(
        session: URLSession,
        downloadsDirectory: URL? = nil
    ) -> AppUpdateService {
        AppUpdateService(
            endpoint: URL(string: "https://api.github.test/releases/latest")!,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: downloadsDirectory ?? temporaryDirectory()
        )
    }

    private func makeSession(handler: @escaping (URLRequest) -> URLProtocolStub.Result) -> URLSession {
        URLProtocolStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private func asset(_ name: String, url: String? = nil) -> [String: String] {
        [
            "name": name,
            "browser_download_url": url ?? "https://github.com/qingtengCHINA/OasesCPA-Desktop/releases/download/v0.2.0/\(name)"
        ]
    }

    private func releaseJSON(tag: String, assets: [[String: String]], draft: Bool = false, prerelease: Bool = false) -> Data {
        let object: [String: Any] = [
            "tag_name": tag,
            "draft": draft,
            "prerelease": prerelease,
            "assets": assets
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func response(for request: URLRequest, json: Data) -> URLProtocolStub.Result {
        response(for: request, data: json)
    }

    private func response(
        for request: URLRequest,
        statusCode: Int = 200,
        data: Data,
        url: URL? = nil,
        headerFields: [String: String] = [:],
        redirectURL: URL? = nil
    ) -> URLProtocolStub.Result {
        var headers = ["Content-Type": "application/json"]
        headers.merge(headerFields) { _, newValue in newValue }
        return URLProtocolStub.Result(
            response: HTTPURLResponse(
                url: url ?? request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!,
            data: data,
            redirectURL: redirectURL
        )
    }
}

private final class URLProtocolStub: URLProtocol {
    struct Result {
        let response: HTTPURLResponse
        let data: Data
        let redirectURL: URL?
    }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Result)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let result = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let redirectURL = result.redirectURL {
            var redirectedRequest = request
            redirectedRequest.url = redirectURL
            client?.urlProtocol(self, wasRedirectedTo: redirectedRequest, redirectResponse: result.response)
            return
        }
        client?.urlProtocol(self, didReceive: result.response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
