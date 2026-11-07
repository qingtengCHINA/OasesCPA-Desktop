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
            return Self.response(for: request, json: Self.releaseJSON(tag: "v0.1.0", assets: [Self.asset("OasesCPA.dmg")]))
        }
        let service = AppUpdateService(
            configuration: Self.testConfiguration,
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

    static let testConfiguration = AppUpdateConfiguration(
        owner: "ExampleOwner",
        repository: "ExampleRepo",
        teamIdentifier: "ABCDE12345",
        bundleIdentifier: "com.example.cpa"
    )

    func testConfigurationReadsBuildTimeIdentityFromInfoDictionary() throws {
        let configuration = try XCTUnwrap(AppUpdateConfiguration.fromInfoDictionary([
            "OasesUpdateRepository": " ExampleOwner/ExampleRepo ",
            "OasesUpdateTeamIdentifier": "ABCDE12345",
            "CFBundleIdentifier": "com.example.cpa"
        ]))

        XCTAssertEqual(configuration, Self.testConfiguration)
        XCTAssertEqual(
            configuration.latestReleaseEndpoint.absoluteString,
            "https://api.github.com/repos/ExampleOwner/ExampleRepo/releases/latest"
        )
    }

    func testMissingRepositoryDisablesUpdater() {
        XCTAssertNil(AppUpdateConfiguration.fromInfoDictionary(["OasesUpdateRepository": "", "OasesUpdateTeamIdentifier": "ABCDE12345", "CFBundleIdentifier": "com.example.cpa"]))
        XCTAssertNil(AppUpdateConfiguration.fromInfoDictionary(["OasesUpdateTeamIdentifier": "ABCDE12345", "CFBundleIdentifier": "com.example.cpa"]))
        XCTAssertNil(AppUpdateConfiguration.fromInfoDictionary(nil))
    }

    func testRejectsMalformedTeamIdentifierAndRepository() {
        XCTAssertNil(AppUpdateConfiguration.fromInfoDictionary(["OasesUpdateRepository": "ExampleOwner/ExampleRepo", "OasesUpdateTeamIdentifier": "abc", "CFBundleIdentifier": "com.example.cpa"]))
        XCTAssertNil(AppUpdateConfiguration.fromInfoDictionary(["OasesUpdateRepository": "no-slash", "OasesUpdateTeamIdentifier": "ABCDE12345", "CFBundleIdentifier": "com.example.cpa"]))
        let rejectedRepositories = [
            "$(OASES_UPDATE_REPOSITORY)",
            "ExampleOwner/ExampleRepo/extra",
            "ExampleOwner/..",
            "/ExampleRepo",
            "ExampleOwner/",
            "-owner/ExampleRepo",
            "Example Owner/ExampleRepo"
        ]
        for repository in rejectedRepositories {
            XCTAssertNil(
                AppUpdateConfiguration.fromInfoDictionary(["OasesUpdateRepository": repository, "OasesUpdateTeamIdentifier": "ABCDE12345", "CFBundleIdentifier": "com.example.cpa"]),
                repository
            )
        }
        for team in ["", "$(OASES_UPDATE_TEAM_ID)", "abcde12345", "ABCDE1234", "ABCDE123456"] {
            XCTAssertNil(
                AppUpdateConfiguration.fromInfoDictionary(["OasesUpdateRepository": "ExampleOwner/ExampleRepo", "OasesUpdateTeamIdentifier": team, "CFBundleIdentifier": "com.example.cpa"]),
                team
            )
        }
        XCTAssertNil(AppUpdateConfiguration.fromInfoDictionary(["OasesUpdateRepository": "ExampleOwner/ExampleRepo", "OasesUpdateTeamIdentifier": "ABCDE12345"]))
        XCTAssertNil(AppUpdateConfiguration.fromInfoDictionary(["OasesUpdateRepository": "ExampleOwner/ExampleRepo", "OasesUpdateTeamIdentifier": "ABCDE12345", "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)"]))
    }

    func testAuthorLineComesFromBuildSettingsAndIsHiddenWhenEmpty() {
        let configured = AppAuthorInfo(infoDictionary: ["OasesAuthorName": "Example Author", "OasesAuthorURL": "https://example.com/"])
        XCTAssertEqual(configured.name, "Example Author")
        XCTAssertEqual(configured.url?.absoluteString, "https://example.com/")

        for info: [String: Any] in [[:], ["OasesAuthorName": "", "OasesAuthorURL": ""], ["OasesAuthorName": "$(OASES_AUTHOR_NAME)"]] {
            XCTAssertNil(AppAuthorInfo(infoDictionary: info).name)
        }
        XCTAssertNil(AppAuthorInfo(infoDictionary: ["OasesAuthorName": "Example Author", "OasesAuthorURL": "http://example.com/"]).url)
        XCTAssertNil(AppAuthorInfo(infoDictionary: ["OasesAuthorName": "Example Author", "OasesAuthorURL": "https:"]).url)
    }

    func testServiceWithoutConfigurationIsDisabledAndNeverRequests() async {
        let session = makeSession { request in
            XCTFail("a disabled updater must not send \(request.url?.absoluteString ?? "a request")")
            return Self.response(for: request, json: Self.releaseJSON(tag: "v9.0.0", assets: [Self.asset("OasesCPA.dmg")]))
        }
        let service = AppUpdateService(
            configuration: nil,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: temporaryDirectory(),
            verifier: AcceptingDMGVerifier()
        )

        XCTAssertFalse(service.isEnabled)
        await service.checkForUpdates()

        XCTAssertEqual(service.status, .idle)
        XCTAssertNil(service.latestRelease)
        XCTAssertFalse(service.isUpdateAvailable)
    }

    func testDownloadURLWhitelistUsesConfiguredOwnerAndRepository() async {
        let accepted = "https://github.com/ExampleOwner/ExampleRepo/releases/download/v0.2.0/OasesCPA.dmg"
        let rejected = [
            "https://github.com/OtherOwner/ExampleRepo/releases/download/v0.2.0/OasesCPA.dmg",
            "https://github.com/ExampleOwner/OtherRepo/releases/download/v0.2.0/OasesCPA.dmg"
        ]
        for (url, expected) in [(accepted, AppUpdateStatus.updateAvailable)] + rejected.map({ ($0, AppUpdateStatus.releaseWithoutDMG) }) {
            let session = makeSession { request in
                Self.response(for: request, json: Self.releaseJSON(tag: "v0.2.0", assets: [Self.asset("OasesCPA.dmg", url: url)]))
            }
            let service = makeService(session: session)

            await service.checkForUpdates()

            XCTAssertEqual(service.status, expected, url)
        }

        let otherOwner = AppUpdateConfiguration(
            owner: "OtherOwner",
            repository: "ExampleRepo",
            teamIdentifier: "ABCDE12345",
            bundleIdentifier: "com.example.cpa"
        )
        let session = makeSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/OtherOwner/ExampleRepo/releases/latest")
            return Self.response(for: request, json: Self.releaseJSON(tag: "v0.2.0", assets: [Self.asset("OasesCPA.dmg", url: accepted)]))
        }
        let service = AppUpdateService(
            configuration: otherOwner,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: temporaryDirectory(),
            verifier: AcceptingDMGVerifier()
        )

        await service.checkForUpdates()

        XCTAssertEqual(service.status, .releaseWithoutDMG)
        XCTAssertNil(service.selectedDMGAsset)
    }

    func testDMGIdentityCheckUsesConfiguredBundleAndTeam() throws {
        let matching = try makeMountedAppFixture()
        let matchingRunner = FakeDMGToolRunner(mountPoint: matching.mountPoint.path)
        XCTAssertNoThrow(
            try SystemDMGVerifier(configuration: Self.testConfiguration, toolRunner: matchingRunner).verify(dmgURL: matching.dmgURL)
        )

        let otherIdentities: [(String, AppUpdateConfiguration)] = [
            ("other-team", AppUpdateConfiguration(owner: "ExampleOwner", repository: "ExampleRepo", teamIdentifier: "ZYXWV98765", bundleIdentifier: "com.example.cpa")),
            ("other-bundle", AppUpdateConfiguration(owner: "ExampleOwner", repository: "ExampleRepo", teamIdentifier: "ABCDE12345", bundleIdentifier: "com.example.other"))
        ]
        for (name, configuration) in otherIdentities {
            let fixture = try makeMountedAppFixture()
            let runner = FakeDMGToolRunner(mountPoint: fixture.mountPoint.path)
            XCTAssertThrowsError(
                try SystemDMGVerifier(configuration: configuration, toolRunner: runner).verify(dmgURL: fixture.dmgURL),
                name
            ) { error in
                guard case DMGVerificationError.wrongIdentity = error else {
                    return XCTFail("\(name): expected wrongIdentity, got \(error)")
                }
            }
            XCTAssertTrue(runner.commands.contains(where: { $0.arguments.first == "detach" }), name)
        }
    }

    func testOlderCurrentVersionReportsUpdateAvailable() async {
        let session = makeSession { request in
            Self.response(for: request, json: Self.releaseJSON(tag: "v0.2.0", assets: [Self.asset("OasesCPA.dmg")]))
        }
        let service = AppUpdateService(
            configuration: Self.testConfiguration,
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
            Self.response(for: request, json: Self.releaseJSON(tag: "release-latest", assets: [Self.asset("OasesCPA.dmg")]))
        }
        let service = AppUpdateService(
            configuration: Self.testConfiguration,
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
                Self.response(
                    for: request,
                    json: Self.releaseJSON(
                        tag: "v9.0.0",
                        assets: [Self.asset("OasesCPA.dmg")],
                        draft: draft,
                        prerelease: prerelease
                    )
                )
            }
            let service = AppUpdateService(
                configuration: Self.testConfiguration,
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
            Self.response(for: request, json: Self.releaseJSON(tag: "v0.2.0", assets: [Self.asset("OasesCPA.zip")]))
        }
        let service = AppUpdateService(
            configuration: Self.testConfiguration,
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
            Self.response(
                for: request,
                json: Self.releaseJSON(
                    tag: "v0.2.0",
                    assets: [Self.asset("OasesCPA.dmg", url: "https://github.com/another-owner/other-repo/releases/download/v0.2.0/OasesCPA.dmg")]
                )
            )
        }
        let service = AppUpdateService(
            configuration: Self.testConfiguration,
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
        let validURL = "https://github.com/ExampleOwner/ExampleRepo/releases/download/v0.2.0/OasesCPA.DMG?download=1"
        let session = makeSession { request in
            Self.response(
                for: request,
                json: Self.releaseJSON(tag: "v0.2.0", assets: [Self.asset("OasesCPA.DMG", url: validURL)])
            )
        }
        let service = makeService(session: session)

        await service.checkForUpdates()

        XCTAssertEqual(service.status, .updateAvailable)
        XCTAssertTrue(service.isUpdateAvailable)
    }

    func testDMGAssetURLRejectsIllegalSchemeHostAndPath() async {
        let invalidURLs = [
            "http://github.com/ExampleOwner/ExampleRepo/releases/download/v0.2.0/OasesCPA.dmg",
            "https://evil.example/ExampleOwner/ExampleRepo/releases/download/v0.2.0/OasesCPA.dmg",
            "https://github.com/another-owner/OasesCPA-Desktop/releases/download/v0.2.0/OasesCPA.dmg",
            "https://github.com/ExampleOwner/ExampleRepo/releases/downloads/v0.2.0/OasesCPA.dmg",
            "https://github.com/ExampleOwner/ExampleRepo/releases/download/v0.2.0/OasesCPA.zip",
            "https://github.com/ExampleOwner/ExampleRepo/releases/download/v0.2.0/../OasesCPA.dmg",
            "https://github.com/ExampleOwner/ExampleRepo/releases/download/v0.2.0/%2E%2EOasesCPA.dmg",
            "https://github.com/ExampleOwner/ExampleRepo/releases/download/v0.2.0/%2FOasesCPA.dmg"
        ]

        for invalidURL in invalidURLs {
            let session = makeSession { request in
                Self.response(
                    for: request,
                    json: Self.releaseJSON(tag: "v0.2.0", assets: [Self.asset("OasesCPA.dmg", url: invalidURL)])
                )
            }
            let service = makeService(session: session)

            await service.checkForUpdates()

            XCTAssertEqual(service.status, .releaseWithoutDMG, invalidURL)
            XCTAssertFalse(service.isUpdateAvailable, invalidURL)
        }
    }

    func testReleaseWithoutStrictDigestOrSizeIsNotDownloadable() async {
        var missingDigest = Self.asset("OasesCPA.dmg")
        missingDigest.removeValue(forKey: "digest")
        var missingSize = Self.asset("OasesCPA.dmg")
        missingSize.removeValue(forKey: "size")
        var invalidDigest = Self.asset("OasesCPA.dmg")
        invalidDigest["digest"] = "sha256:not-a-sha256"
        var invalidSize = Self.asset("OasesCPA.dmg")
        invalidSize["size"] = "-1"

        for candidate in [missingDigest, missingSize, invalidDigest, invalidSize] {
            let session = makeSession { request in
                Self.response(for: request, json: Self.releaseJSON(tag: "v0.2.0", assets: [candidate]))
            }
            let service = makeService(session: session)

            await service.checkForUpdates()

            XCTAssertEqual(service.status, .failed)
            XCTAssertFalse(service.isUpdateAvailable)
            XCTAssertNil(service.selectedDMGAsset)
        }
    }

    func testMutableReleaseMetadataDoesNotBlockVerifiedUpdate() async {
        let session = makeSession { request in
            Self.response(
                for: request,
                json: Self.releaseJSON(tag: "v0.2.0", assets: [Self.asset("OasesCPA.dmg")], immutable: false)
            )
        }
        let service = makeService(session: session)

        await service.checkForUpdates()

        XCTAssertEqual(service.status, .updateAvailable)
        XCTAssertTrue(service.isUpdateAvailable)
        XCTAssertNotNil(service.selectedDMGAsset)
    }

    func testMissingImmutableMarkerDoesNotBlockVerifiedUpdate() async {
        let session = makeSession { request in
            Self.response(
                for: request,
                json: Self.releaseJSONWithoutImmutable(tag: "v0.2.0", assets: [Self.asset("OasesCPA.dmg")])
            )
        }
        let service = makeService(session: session)

        await service.checkForUpdates()

        XCTAssertEqual(service.status, .updateAvailable)
        XCTAssertTrue(service.isUpdateAvailable)
        XCTAssertNotNil(service.selectedDMGAsset)
    }

    func testDownloadDoesNotOverwriteExistingFileAndCallsOpenCallback() async throws {
        let directory = temporaryDirectory()
        let existingURL = directory.appendingPathComponent("OasesCPA.dmg")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: existingURL)
        var openedURL: URL?
        let verifier = CountingDMGVerifier()
        let session = makeSession { request in
            if request.url?.path == "/releases/latest" {
                return Self.response(for: request, json: Self.releaseJSON(tag: "v0.2.0", assets: [Self.asset("OasesCPA.dmg")]))
            }
            return Self.response(
                for: request,
                data: Data("new".utf8),
                url: URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/12345")!,
                headerFields: ["Content-Disposition": "attachment; filename=OasesCPA.dmg"]
            )
        }
        let service = AppUpdateService(
            configuration: Self.testConfiguration,
            endpoint: URL(string: "https://api.github.test/releases/latest")!,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: directory,
            verifier: verifier,
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
        XCTAssertEqual(verifier.callCount, 2, "automatic open must repeat the complete verification")
    }

    func testDownloadAcceptsReleaseAssetsRedirectWithoutDMGPathExtensionWhenFilenameIsDMG() async throws {
        let session = makeSession { request in
            if request.url?.path == "/releases/latest" {
                return Self.response(for: request, json: Self.releaseJSON(tag: "v0.2.0", assets: [Self.asset("OasesCPA.dmg")]))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "OasesCPA/0.1.0 (macOS)")
            return Self.response(
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
                return Self.response(for: request, json: Self.releaseJSON(tag: "v0.2.0", assets: [Self.asset("OasesCPA.dmg")]))
            }
            if request.url?.host == "github.com" {
                return Self.response(
                    for: request,
                    statusCode: 302,
                    data: Data(),
                    url: request.url,
                    headerFields: ["Location": finalURL.absoluteString],
                    redirectURL: finalURL
                )
            }
            return Self.response(
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
                return Self.response(for: request, json: Self.releaseJSON(tag: "v0.2.0", assets: [Self.asset("OasesCPA.dmg")]))
            }
            return Self.response(
                for: request,
                data: Data("not a dmg".utf8),
                url: URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/12345")!,
                headerFields: ["Content-Disposition": "attachment; filename=OasesCPA.zip"]
            )
        }
        let service = AppUpdateService(
            configuration: Self.testConfiguration,
            endpoint: URL(string: "https://api.github.test/releases/latest")!,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: temporaryDirectory(),
            verifier: AcceptingDMGVerifier(),
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
                return Self.response(for: request, json: Self.releaseJSON(tag: "v0.2.0", assets: [Self.asset("OasesCPA.dmg")]))
            }
            return Self.response(
                for: request,
                data: Data("not a dmg".utf8),
                url: URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/12345")!
            )
        }
        let service = AppUpdateService(
            configuration: Self.testConfiguration,
            endpoint: URL(string: "https://api.github.test/releases/latest")!,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: temporaryDirectory(),
            verifier: AcceptingDMGVerifier(),
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
                    return Self.response(for: request, json: Self.releaseJSON(tag: "v0.2.0", assets: [Self.asset("OasesCPA.dmg")]))
                }
                return Self.response(
                    for: request,
                    data: Data("not a dmg".utf8),
                    url: URL(string: finalURL)!,
                    headerFields: ["Content-Disposition": "attachment; filename=OasesCPA.dmg"]
                )
            }
            let service = AppUpdateService(
                configuration: Self.testConfiguration,
                endpoint: URL(string: "https://api.github.test/releases/latest")!,
                currentVersion: SemanticVersion("0.1.0"),
                session: session,
                downloadsDirectory: temporaryDirectory(),
                verifier: AcceptingDMGVerifier(),
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
            Self.response(for: request, statusCode: 500, data: Data("server error".utf8))
        }
        let service = AppUpdateService(
            configuration: Self.testConfiguration,
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
                return Self.response(for: request, json: Self.releaseJSON(tag: "v0.2.0", assets: [Self.asset("OasesCPA.dmg")]))
            }
            return Self.response(
                for: request,
                statusCode: 503,
                data: Data("unavailable".utf8),
                url: URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/12345")!,
                headerFields: ["Content-Disposition": "attachment; filename=OasesCPA.dmg"]
            )
        }
        let directory = temporaryDirectory()
        let service = AppUpdateService(
            configuration: Self.testConfiguration,
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
                return Self.response(for: request, json: Self.releaseJSON(tag: "v0.2.0", assets: [Self.asset("OasesCPA.dmg")]))
            }
            return Self.response(
                for: request,
                data: Data("not a dmg".utf8),
                url: URL(string: "https://evil.example.invalid/OasesCPA.dmg")!
            )
        }
        let service = AppUpdateService(
            configuration: Self.testConfiguration,
            endpoint: URL(string: "https://api.github.test/releases/latest")!,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: temporaryDirectory(),
            verifier: AcceptingDMGVerifier(),
            openFile: { _ in openCount += 1 }
        )

        await service.checkForUpdates()
        await service.downloadAvailableUpdate()

        XCTAssertEqual(service.status, .failed)
        XCTAssertNil(service.downloadedFileURL)
        XCTAssertFalse(service.errorMessage?.isEmpty ?? true)
        XCTAssertEqual(openCount, 0)
    }

    func testDownloadRejectsDeclaredSizeOrDigestMismatchAndCleansDestination() async {
        for mutation in [
            { (candidate: inout [String: String]) in candidate["size"] = "4" },
            { (candidate: inout [String: String]) in candidate["digest"] = "sha256:0000000000000000000000000000000000000000000000000000000000000000" }
        ] {
            var candidate = Self.asset("OasesCPA.dmg")
            mutation(&candidate)
            let candidateForRequest = candidate
            let directory = temporaryDirectory()
            var openCount = 0
            let session = makeSession { request in
                if request.url?.path == "/releases/latest" {
                    return Self.response(for: request, json: Self.releaseJSON(tag: "v0.2.0", assets: [candidateForRequest]))
                }
                return Self.response(
                    for: request,
                    data: Data("new".utf8),
                    url: URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/12345")!,
                    headerFields: ["Content-Disposition": "attachment; filename=OasesCPA.dmg"]
                )
            }
            let service = makeService(session: session, downloadsDirectory: directory, openFile: { _ in openCount += 1 })

            await service.checkForUpdates()
            await service.downloadAvailableUpdate()

            XCTAssertEqual(service.status, .failed)
            XCTAssertNil(service.downloadedFileURL)
            XCTAssertEqual(openCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }

    func testDownloadRejectsAssetAboveStreamSizeCapBeforeOpening() async {
        var candidate = Self.asset("OasesCPA.dmg")
        candidate["size"] = String(AppUpdateService.maximumDMGSize + 1)
        let candidateForRequest = candidate
        let session = makeSession { request in
            Self.response(for: request, json: Self.releaseJSON(tag: "v0.2.0", assets: [candidateForRequest]))
        }
        let service = makeService(session: session, openFile: { _ in XCTFail("oversized update must not open") })

        await service.checkForUpdates()
        await service.downloadAvailableUpdate()

        XCTAssertEqual(service.status, .failed)
        XCTAssertNil(service.downloadedFileURL)
    }

    func testDefaultVerifierRejectsFixtureBytesBeforeOpening() async {
        let directory = temporaryDirectory()
        var openCount = 0
        let session = makeSession { request in
            if request.url?.path == "/releases/latest" {
                return Self.response(for: request, json: Self.releaseJSON(tag: "v0.2.0", assets: [Self.asset("OasesCPA.dmg")]))
            }
            return Self.response(
                for: request,
                data: Data("new".utf8),
                url: URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/12345")!,
                headerFields: ["Content-Disposition": "attachment; filename=OasesCPA.dmg"]
            )
        }
        let service = AppUpdateService(
            configuration: Self.testConfiguration,
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
        XCTAssertEqual(openCount, 0)
    }

    func testOpenRevalidatesAfterDownloadedFileIsReplaced() async throws {
        let directory = temporaryDirectory()
        var openCount = 0
        let session = makeSession { request in
            if request.url?.path == "/releases/latest" {
                return Self.response(for: request, json: Self.releaseJSON(tag: "v0.2.0", assets: [Self.asset("OasesCPA.dmg")]))
            }
            return Self.response(
                for: request,
                data: Data("new".utf8),
                url: URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/12345")!,
                headerFields: ["Content-Disposition": "attachment; filename=OasesCPA.dmg"]
            )
        }
        let service = makeService(session: session, downloadsDirectory: directory, openFile: { _ in openCount += 1 })

        await service.checkForUpdates()
        await service.downloadAvailableUpdate()
        let downloadedURL = try XCTUnwrap(service.downloadedFileURL)
        XCTAssertEqual(openCount, 1)

        try Data("replaced".utf8).write(to: downloadedURL)
        openCount = 0
        service.openDownloadedUpdate()

        XCTAssertEqual(openCount, 0)
        XCTAssertEqual(service.status, .failed)
    }

    func testSystemVerifierRequiresEveryGateAndDetachesMountedImage() throws {
        let output = try ProcessDMGToolRunner(timeout: 1).run(
            executable: "/usr/bin/printf",
            arguments: ["tool-output"]
        )
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(String(data: output.stdout, encoding: .utf8), "tool-output")
        let largeOutput = try ProcessDMGToolRunner(timeout: 1).run(
            executable: "/usr/bin/head",
            arguments: ["-c", "131072", "/dev/zero"]
        )
        XCTAssertEqual(largeOutput.status, 0)
        XCTAssertEqual(largeOutput.stdout.count, 131072)
        XCTAssertThrowsError(
            try ProcessDMGToolRunner(timeout: 3).run(
                executable: "/usr/bin/head",
                arguments: ["-c", "8388609", "/dev/zero"]
            )
        ) { error in
            guard case ProcessDMGToolError.outputLimitExceeded = error else {
                return XCTFail("expected output cap failure, got \(error)")
            }
        }
        XCTAssertThrowsError(try ProcessDMGToolRunner(timeout: 0.05).run(executable: "/bin/sleep", arguments: ["2"])) { error in
            guard case ProcessDMGToolError.timedOut = error else {
                return XCTFail("expected bounded process timeout, got \(error)")
            }
        }

        let scenarios: [(String, (FakeDMGToolRunner) -> Void)] = [
            ("unsigned", { runner in runner.codesignVerifyStatus = 1 }),
            ("wrong-team", { runner in runner.codesignMetadata = "Identifier=com.example.cpa\nTeamIdentifier=WRONG\n" }),
            ("wrong-bundle", { runner in runner.codesignMetadata = "Identifier=dev.other.app\nTeamIdentifier=ABCDE12345\n" }),
            ("unnotarized", { runner in runner.spctlOutput = "accepted\nsource=Developer ID\n" }),
            ("stapler-fails", { runner in runner.staplerStatus = 1 }),
            ("attach-fails-with-mount", { runner in runner.attachStatus = 1 }),
            ("signature-and-detach-fails", { runner in
                runner.codesignVerifyStatus = 1
                runner.detachStatus = 1
            }),
            ("detach-fails", { runner in runner.detachStatus = 1 })
        ]
        for (name, mutate) in scenarios {
            let fixture = try makeMountedAppFixture()
            let runner = FakeDMGToolRunner(mountPoint: fixture.mountPoint.path)
            mutate(runner)
            let verifier = SystemDMGVerifier(configuration: Self.testConfiguration, toolRunner: runner)

            var verificationError: Error?
            XCTAssertThrowsError(try verifier.verify(dmgURL: fixture.dmgURL), name) { verificationError = $0 }
            if name == "signature-and-detach-fails" {
                guard let verificationError,
                      case DMGVerificationError.verificationAndDetachFailed = verificationError
                else {
                    return XCTFail("verification failure must not be hidden by detach failure")
                }
            }
            XCTAssertTrue(runner.commands.contains(where: { $0.executable == "/usr/bin/hdiutil" && $0.arguments.starts(with: ["attach", "-readonly", "-nobrowse", "-noautoopen", "-plist"]) }))
            XCTAssertTrue(runner.commands.contains(where: { $0.arguments.first == "detach" }), name)
            if name == "stapler-fails" || name == "detach-fails" {
                XCTAssertTrue(runner.commands.contains(where: { $0.executable == "/usr/bin/stapler" && $0.arguments.first == "validate" }), name)
            }
        }
    }

    func testSystemVerifierRejectsMultipleApps() throws {
        let fixture = try makeMountedAppFixture(additionalApp: true)
        let runner = FakeDMGToolRunner(mountPoint: fixture.mountPoint.path)

        XCTAssertThrowsError(try SystemDMGVerifier(configuration: Self.testConfiguration, toolRunner: runner).verify(dmgURL: fixture.dmgURL))
        XCTAssertTrue(runner.commands.contains(where: { $0.arguments.first == "detach" }))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeService(
        session: URLSession,
        downloadsDirectory: URL? = nil,
        openFile: @escaping (URL) -> Void = { _ in }
    ) -> AppUpdateService {
        AppUpdateService(
            configuration: Self.testConfiguration,
            endpoint: URL(string: "https://api.github.test/releases/latest")!,
            currentVersion: SemanticVersion("0.1.0"),
            session: session,
            downloadsDirectory: downloadsDirectory ?? temporaryDirectory(),
            verifier: AcceptingDMGVerifier(),
            openFile: openFile
        )
    }

    private func makeSession(handler: @escaping @Sendable (URLRequest) -> URLProtocolStub.Result) -> URLSession {
        URLProtocolStub.installHandler(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private nonisolated static func asset(_ name: String, url: String? = nil) -> [String: String] {
        [
            "name": name,
            "browser_download_url": url ?? "https://github.com/ExampleOwner/ExampleRepo/releases/download/v0.2.0/\(name)",
            "size": "3",
            "digest": "sha256:11507a0e2f5e69d5dfa40a62a1bd7b6ee57e6bcd85c67c9b8431b36fff21c437"
        ]
    }

    private nonisolated static func releaseJSON(tag: String, assets: [[String: String]], draft: Bool = false, prerelease: Bool = false, immutable: Bool = true) -> Data {
        let normalizedAssets: [[String: Any]] = assets.map { asset in
            var normalized = asset.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = pair.value
            }
            if let size = asset["size"].flatMap(Int.init) {
                normalized["size"] = size
            }
            return normalized
        }
        let object: [String: Any] = [
            "tag_name": tag,
            "draft": draft,
            "prerelease": prerelease,
            "immutable": immutable,
            "assets": normalizedAssets
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private nonisolated static func releaseJSONWithoutImmutable(tag: String, assets: [[String: String]]) -> Data {
        let normalizedAssets: [[String: Any]] = assets.map { asset in
            var normalized = asset.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = pair.value
            }
            if let size = asset["size"].flatMap(Int.init) {
                normalized["size"] = size
            }
            return normalized
        }
        let object: [String: Any] = [
            "tag_name": tag,
            "draft": false,
            "prerelease": false,
            "assets": normalizedAssets
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private nonisolated static func response(for request: URLRequest, json: Data) -> URLProtocolStub.Result {
        response(for: request, data: json)
    }

    private nonisolated static func response(
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

    private func makeMountedAppFixture(additionalApp: Bool = false) throws -> (dmgURL: URL, mountPoint: URL) {
        let root = temporaryDirectory()
        let mountPoint = root.appendingPathComponent("Mounted", isDirectory: true)
        let app = mountPoint.appendingPathComponent("OasesCPA.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.cpa",
            "CFBundlePackageType": "APPL"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        if additionalApp {
            try FileManager.default.createDirectory(
                at: mountPoint.appendingPathComponent("Other.app", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        let dmgURL = root.appendingPathComponent("OasesCPA.dmg")
        try Data("dmg".utf8).write(to: dmgURL)
        return (dmgURL, mountPoint)
    }
}

private struct AcceptingDMGVerifier: DMGVerifier {
    func verify(dmgURL: URL) throws {}
}

private final class CountingDMGVerifier: DMGVerifier {
    private(set) var callCount = 0

    func verify(dmgURL: URL) throws {
        callCount += 1
    }
}

private struct FakeDMGToolCommand {
    let executable: String
    let arguments: [String]
}

private final class FakeDMGToolRunner: DMGToolRunner {
    let mountPoint: String
    var commands: [FakeDMGToolCommand] = []
    var attachStatus: Int32 = 0
    var codesignVerifyStatus: Int32 = 0
    var codesignMetadata = "Identifier=com.example.cpa\nTeamIdentifier=ABCDE12345\n"
    var spctlOutput = "accepted\nsource=Notarized Developer ID\n"
    var staplerStatus: Int32 = 0
    var detachStatus: Int32 = 0

    init(mountPoint: String) {
        self.mountPoint = mountPoint
    }

    func run(executable: String, arguments: [String]) throws -> DMGToolResult {
        commands.append(FakeDMGToolCommand(executable: executable, arguments: arguments))
        if executable == "/usr/bin/hdiutil", arguments.first == "attach" {
            let plist: [String: Any] = ["system-entities": [["mount-point": mountPoint]]]
            return DMGToolResult(
                status: attachStatus,
                stdout: try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
                stderr: Data()
            )
        }
        if executable == "/usr/bin/hdiutil", arguments.first == "detach" {
            return DMGToolResult(status: detachStatus, stdout: Data(), stderr: Data())
        }
        if executable == "/usr/bin/codesign", arguments.first == "--verify" {
            return DMGToolResult(status: codesignVerifyStatus, stdout: Data(), stderr: Data())
        }
        if executable == "/usr/bin/codesign" {
            return DMGToolResult(status: 0, stdout: Data(), stderr: Data(codesignMetadata.utf8))
        }
        if executable == "/usr/sbin/spctl" {
            return DMGToolResult(status: 0, stdout: Data(), stderr: Data(spctlOutput.utf8))
        }
        if executable == "/usr/bin/stapler" {
            return DMGToolResult(status: staplerStatus, stdout: Data(), stderr: Data())
        }
        return DMGToolResult(status: 1, stdout: Data(), stderr: Data())
    }
}

private final class URLProtocolStub: URLProtocol {
    struct Result: @unchecked Sendable {
        let response: HTTPURLResponse
        let data: Data
        let redirectURL: URL?
    }

    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Result)?
    private static let handlerLock = NSLock()

    static func installHandler(_ handler: @escaping @Sendable (URLRequest) -> Result) {
        handlerLock.lock()
        Self.handler = handler
        handlerLock.unlock()
    }

    private static func result(for request: URLRequest) -> Result? {
        handlerLock.lock()
        let currentHandler = handler
        handlerLock.unlock()
        return currentHandler?(request)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let result = Self.result(for: request) else {
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
