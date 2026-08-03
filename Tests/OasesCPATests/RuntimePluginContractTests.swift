import Foundation
import XCTest
@testable import OasesCPA

final class RuntimePluginContractTests: XCTestCase {
    func testRuntimePluginsResponseDecodesFullAndMinimalPlugins() throws {
        let data = Data(
            #"""
            {
              "plugins_enabled": true,
              "plugins_dir": "/tmp/plugins",
              "plugins": [
                {
                  "id": "sample-plugin",
                  "path": "/tmp/plugins/sample-plugin",
                  "configured": true,
                  "registered": true,
                  "enabled": true,
                  "effective_enabled": true,
                  "supports_oauth": true,
                  "oauth_provider": "example-oauth",
                  "logo": "sample-logo",
                  "config_fields": [
                    {
                      "name": "mode",
                      "type": "select",
                      "enum_values": ["safe", "fast"],
                      "description": "运行模式"
                    }
                  ],
                  "menus": [
                    {
                      "path": "settings.mode",
                      "menu": "模式",
                      "description": "选择运行模式"
                    }
                  ],
                  "metadata": {
                    "name": "示例插件",
                    "version": "1.2.3",
                    "author": "Example Author",
                    "github_repository": "example/plugin",
                    "logo": "metadata-logo",
                    "config_fields": [
                      {
                        "name": "mode",
                        "type": "select",
                        "enum_values": ["safe", "fast"],
                        "description": "运行模式"
                      }
                    ]
                  }
                },
                {
                  "id": "minimal-plugin"
                }
              ]
            }
            """#.utf8
        )

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(RuntimePluginsResponse.self, from: data)

        XCTAssertTrue(response.pluginsEnabled)
        XCTAssertEqual(response.pluginsDir, "/tmp/plugins")
        XCTAssertEqual(response.plugins.count, 2)

        let full = try XCTUnwrap(response.plugins.first)
        XCTAssertEqual(full.id, "sample-plugin")
        XCTAssertEqual(full.path, "/tmp/plugins/sample-plugin")
        XCTAssertTrue(full.configured)
        XCTAssertTrue(full.registered)
        XCTAssertTrue(full.enabled)
        XCTAssertTrue(full.effectiveEnabled)
        XCTAssertTrue(full.supportsOAuth)
        XCTAssertEqual(full.oauthProvider, "example-oauth")
        XCTAssertEqual(full.logo, "sample-logo")
        XCTAssertEqual(full.configFields.first?.name, "mode")
        XCTAssertEqual(full.configFields.first?.type, "select")
        XCTAssertEqual(full.configFields.first?.enumValues, ["safe", "fast"])
        XCTAssertEqual(full.configFields.first?.description, "运行模式")
        XCTAssertEqual(full.menus.first?.path, "settings.mode")
        XCTAssertEqual(full.menus.first?.menu, "模式")
        XCTAssertEqual(full.menus.first?.description, "选择运行模式")
        XCTAssertEqual(full.metadata?.name, "示例插件")
        XCTAssertEqual(full.metadata?.version, "1.2.3")
        XCTAssertEqual(full.metadata?.author, "Example Author")
        XCTAssertEqual(full.metadata?.githubRepository, "example/plugin")
        XCTAssertEqual(full.metadata?.logo, "metadata-logo")
        XCTAssertEqual(full.metadata?.configFields.first?.name, "mode")

        let minimal = try XCTUnwrap(response.plugins.last)
        XCTAssertEqual(minimal.id, "minimal-plugin")
        XCTAssertEqual(minimal.displayTitle, "minimal-plugin")
        XCTAssertTrue(minimal.configFields.isEmpty)
        XCTAssertTrue(minimal.menus.isEmpty)
    }

    func testRuntimePluginEnabledPatchEncodesOnlyEnabled() throws {
        let encoded = try JSONEncoder().encode(RuntimePluginEnabledPatch(enabled: true))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), ["enabled"])
        XCTAssertEqual(object["enabled"] as? Bool, true)
    }

    func testCanonicalDataPrettyPrintsSortedObjectAndRejectsNonObjects() throws {
        let canonical = try XCTUnwrap(
            RuntimePluginConfigValidator.canonicalData(
                from: #"{"z":3,"nested":{"z":2,"a":true},"a":1}"#
            )
        )
        let expected = try JSONSerialization.data(
            withJSONObject: ["z": 3, "nested": ["z": 2, "a": true], "a": 1],
            options: [.prettyPrinted, .sortedKeys]
        )
        XCTAssertEqual(canonical, expected)

        XCTAssertNil(RuntimePluginConfigValidator.canonicalData(from: #"[1,2,3]"#))
        XCTAssertNil(RuntimePluginConfigValidator.canonicalData(from: #""text""#))
        XCTAssertNil(RuntimePluginConfigValidator.canonicalData(from: #"{"broken":}"#))
    }

    func testRuntimePluginTitlesReflectMetadataAndEffectiveState() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(
            RuntimePluginsResponse.self,
            from: Data(#"{"plugins":[{"id":"active","registered":true,"configured":true,"path":"/tmp/active","effective_enabled":true},{"id":"inactive","registered":false,"configured":false}]}"#.utf8)
        )

        let active = try XCTUnwrap(response.plugins.first)
        XCTAssertEqual(active.displayTitle, "active")
        XCTAssertEqual(active.effectiveStateTitle, "已生效")

        let inactive = try XCTUnwrap(response.plugins.last)
        XCTAssertNotEqual(inactive.effectiveStateTitle, "已生效")
    }
}
