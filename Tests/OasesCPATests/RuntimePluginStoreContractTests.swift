import Foundation
import XCTest
@testable import OasesCPA

final class RuntimePluginStoreContractTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func testRuntimePluginStoreResponseDecodesSourcesErrorsAndPluginState() throws {
        let response = try decoder.decode(
            RuntimePluginStoreResponse.self,
            from: Data(
                #"""
                {
                  "plugins_enabled": true,
                  "plugins_dir": "/Library/Application Support/CLIProxyAPI/plugins",
                  "sources": [
                    {
                      "id": "official",
                      "name": "Official plugins",
                      "url": "https://plugins.example.com/official.json"
                    },
                    {
                      "id": "community",
                      "name": "Community plugins",
                      "url": "https://plugins.example.com/community.json"
                    }
                  ],
                  "source_errors": [
                    {
                      "source_id": "community",
                      "source_name": "Community plugins",
                      "source_url": "https://plugins.example.com/community.json",
                      "message": "source unavailable"
                    }
                  ],
                  "plugins": [
                    {
                      "store_id": "official/bridge",
                      "source_id": "official",
                      "source_name": "Official plugins",
                      "source_url": "https://plugins.example.com/official.json",
                      "id": "bridge",
                      "name": "Bridge plugin",
                      "description": "Connects CLIProxyAPI to a bridge service",
                      "author": "Example Team",
                      "version": "2.4.0",
                      "repository": "example/bridge",
                      "install_type": "archive",
                      "auth_required": true,
                      "auth_configured": true,
                      "platforms": [
                        {"goos": "darwin", "goarch": "arm64"},
                        {"goos": "darwin", "goarch": "amd64"}
                      ],
                      "logo": "https://plugins.example.com/bridge.png",
                      "homepage": "https://plugins.example.com/bridge",
                      "license": "MIT",
                      "tags": ["bridge", "official"],
                      "installed": true,
                      "installed_version": "2.3.0",
                      "installed_source_id": "official",
                      "install_source_status": "matched",
                      "path": "/Library/Application Support/CLIProxyAPI/plugins/bridge",
                      "configured": true,
                      "registered": true,
                      "enabled": true,
                      "effective_enabled": true,
                      "update_available": true
                    },
                    {
                      "store_id": "community/formatter",
                      "source_id": "community",
                      "source_name": "Community plugins",
                      "source_url": "https://plugins.example.com/community.json",
                      "id": "formatter",
                      "name": "Formatter plugin",
                      "description": "Formats responses",
                      "author": "Community Author",
                      "version": "1.0.0",
                      "repository": "community/formatter",
                      "install_type": "binary",
                      "auth_required": false,
                      "auth_configured": false,
                      "platforms": [{"goos": "linux", "goarch": "amd64"}],
                      "logo": "formatter-logo",
                      "homepage": "https://plugins.example.com/formatter",
                      "license": "Apache-2.0",
                      "tags": ["formatting"],
                      "installed": false,
                      "installed_version": "",
                      "installed_source_id": "",
                      "install_source_status": "unmatched",
                      "path": "",
                      "configured": false,
                      "registered": false,
                      "enabled": false,
                      "effective_enabled": false,
                      "update_available": false
                    }
                  ]
                }
                """#.utf8
            )
        )

        XCTAssertTrue(response.pluginsEnabled)
        XCTAssertEqual(response.pluginsDir, "/Library/Application Support/CLIProxyAPI/plugins")
        XCTAssertEqual(response.sources.count, 2)
        XCTAssertEqual(response.sources[0].id, "official")
        XCTAssertEqual(response.sources[0].name, "Official plugins")
        XCTAssertEqual(response.sources[1].url, "https://plugins.example.com/community.json")
        XCTAssertEqual(response.sourceErrors.count, 1)
        XCTAssertEqual(response.sourceErrors[0].sourceID, "community")
        XCTAssertEqual(response.sourceErrors[0].sourceName, "Community plugins")
        XCTAssertEqual(response.sourceErrors[0].sourceURL, "https://plugins.example.com/community.json")
        XCTAssertEqual(response.sourceErrors[0].message, "source unavailable")
        XCTAssertEqual(response.plugins.count, 2)

        let installed = response.plugins[0]
        XCTAssertEqual(installed.storeID, "official/bridge")
        XCTAssertEqual(installed.sourceID, "official")
        XCTAssertEqual(installed.sourceName, "Official plugins")
        XCTAssertEqual(installed.sourceURL, "https://plugins.example.com/official.json")
        XCTAssertEqual(installed.id, "bridge")
        XCTAssertEqual(installed.name, "Bridge plugin")
        XCTAssertEqual(installed.description, "Connects CLIProxyAPI to a bridge service")
        XCTAssertEqual(installed.author, "Example Team")
        XCTAssertEqual(installed.version, "2.4.0")
        XCTAssertEqual(installed.repository, "example/bridge")
        XCTAssertEqual(installed.installType, "archive")
        XCTAssertTrue(installed.authRequired)
        XCTAssertTrue(installed.authConfigured)
        XCTAssertEqual(installed.platforms.map { "\($0.goos)/\($0.goarch)" }, ["darwin/arm64", "darwin/amd64"])
        XCTAssertEqual(installed.logo, "https://plugins.example.com/bridge.png")
        XCTAssertEqual(installed.homepage, "https://plugins.example.com/bridge")
        XCTAssertEqual(installed.license, "MIT")
        XCTAssertEqual(installed.tags, ["bridge", "official"])
        XCTAssertTrue(installed.installed)
        XCTAssertEqual(installed.installedVersion, "2.3.0")
        XCTAssertEqual(installed.installedSourceID, "official")
        XCTAssertEqual(installed.installSourceStatus, "matched")
        XCTAssertTrue(installed.configured)
        XCTAssertTrue(installed.registered)
        XCTAssertTrue(installed.enabled)
        XCTAssertTrue(installed.effectiveEnabled)
        XCTAssertTrue(installed.updateAvailable)
        XCTAssertEqual(installed.path, "/Library/Application Support/CLIProxyAPI/plugins/bridge")

        let available = response.plugins[1]
        XCTAssertEqual(available.id, "formatter")
        XCTAssertEqual(available.displayTitle, "Formatter plugin")
        XCTAssertFalse(available.installed)
        XCTAssertEqual(available.platforms.first?.goos, "linux")
        XCTAssertEqual(available.tags, ["formatting"])
        XCTAssertFalse(available.updateAvailable)
    }

    func testRuntimePluginStoreResponseAndEntryAcceptMissingOptionalFields() throws {
        let response = try decoder.decode(
            RuntimePluginStoreResponse.self,
            from: Data(#"{"plugins":[{"id":"minimal-plugin"}]}"#.utf8)
        )

        XCTAssertFalse(response.pluginsEnabled)
        XCTAssertTrue(response.pluginsDir.isEmpty || response.pluginsDir == "plugins")
        XCTAssertTrue(response.sources.isEmpty)
        XCTAssertTrue(response.sourceErrors.isEmpty)
        let plugin = try XCTUnwrap(response.plugins.first)
        XCTAssertEqual(plugin.id, "minimal-plugin")
        XCTAssertEqual(plugin.displayTitle, "minimal-plugin")
        XCTAssertTrue(plugin.platforms.isEmpty)
        XCTAssertTrue(plugin.tags.isEmpty)
        XCTAssertFalse(plugin.installed)
        XCTAssertFalse(plugin.configured)
        XCTAssertFalse(plugin.registered)
        XCTAssertFalse(plugin.enabled)
        XCTAssertFalse(plugin.effectiveEnabled)
        XCTAssertFalse(plugin.updateAvailable)
    }

    func testRuntimePluginStoreInstallRequestEncodesExactlyVersion() throws {
        let encoded = try JSONEncoder().encode(RuntimePluginStoreInstallRequest(version: "2.4.0"))

        XCTAssertEqual(encoded, Data(#"{"version":"2.4.0"}"#.utf8))
    }

    func testRuntimePluginStoreInstallResultDecodesSnakeCaseFields() throws {
        let result = try decoder.decode(
            RuntimePluginStoreInstallResult.self,
            from: Data(
                #"{"status":"installed","source_id":"official","source_name":"Official plugins","source_url":"https://plugins.example.com/official.json","id":"bridge","version":"2.4.0","install_type":"archive","path":"/tmp/plugins/bridge","plugins_enabled":true,"restart_required":true}"#.utf8
            )
        )

        XCTAssertEqual(result.status, "installed")
        XCTAssertEqual(result.sourceID, "official")
        XCTAssertEqual(result.sourceName, "Official plugins")
        XCTAssertEqual(result.sourceURL, "https://plugins.example.com/official.json")
        XCTAssertEqual(result.id, "bridge")
        XCTAssertEqual(result.version, "2.4.0")
        XCTAssertEqual(result.installType, "archive")
        XCTAssertEqual(result.path, "/tmp/plugins/bridge")
        XCTAssertTrue(result.pluginsEnabled)
        XCTAssertTrue(result.restartRequired)
    }

    func testRuntimePluginDeleteResultDecodesSnakeCaseFields() throws {
        let result = try decoder.decode(
            RuntimePluginDeleteResult.self,
            from: Data(
                #"{"status":"deleted","id":"bridge","path":"/tmp/plugins/bridge","file_deleted":true,"configured_removed":true,"restart_required":false}"#.utf8
            )
        )

        XCTAssertEqual(result.status, "deleted")
        XCTAssertEqual(result.id, "bridge")
        XCTAssertEqual(result.path, "/tmp/plugins/bridge")
        XCTAssertTrue(result.fileDeleted)
        XCTAssertTrue(result.configuredRemoved)
        XCTAssertFalse(result.restartRequired)
    }
}
