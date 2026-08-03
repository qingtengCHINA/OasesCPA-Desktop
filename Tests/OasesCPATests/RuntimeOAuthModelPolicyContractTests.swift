import Foundation
import XCTest
@testable import OasesCPA

final class RuntimeOAuthModelPolicyContractTests: XCTestCase {
    func testExcludedModelsDecodeDashedEnvelopeNormalizesAndDropsInvalidChannels() throws {
        let data = Data(
            #"""
            {
              "oauth-excluded-models": {
                " Codex ": [" GPT-5 ", "gpt-5", "", " Claude-3 ", "claude-3"],
                "GEMINI": ["Gemini-2.5-Pro", " gemini-2.5-pro "],
                "bad channel": ["should-be-dropped"],
                "": ["also-dropped"]
              }
            }
            """#.utf8
        )

        let response = try JSONDecoder().decode(
            RuntimeOAuthExcludedModelsResponse.self,
            from: data
        )

        XCTAssertEqual(response.rules["codex"], ["gpt-5", "claude-3"])
        XCTAssertEqual(response.rules["gemini"], ["gemini-2.5-pro"])
        XCTAssertNil(response.rules["bad channel"])
        XCTAssertNil(response.rules[""])
        XCTAssertEqual(response.rules.count, 2)
    }

    func testAliasesDecodeDashedEnvelopeAndPreserveUnknownFields() throws {
        let data = Data(
            #"""
            {
              "oauth-model-alias": {
                " Claude ": [
                  {
                    "name": " claude-3-7-sonnet ",
                    "alias": " claude-sonnet ",
                    "fork": true,
                    "display-name": " Claude Sonnet ",
                    "force-mapping": true,
                    "future-routing": {"region": "us"},
                    "priority": 3
                  }
                ],
                "bad channel": [
                  {"name": "a", "alias": "b"}
                ]
              }
            }
            """#.utf8
        )

        let response = try JSONDecoder().decode(RuntimeOAuthModelAliasResponse.self, from: data)
        let entry = try XCTUnwrap(response.aliases["claude"]?.first)

        XCTAssertEqual(entry.name, "claude-3-7-sonnet")
        XCTAssertEqual(entry.alias, "claude-sonnet")
        XCTAssertTrue(entry.fork)
        XCTAssertEqual(entry.displayName, "Claude Sonnet")
        XCTAssertTrue(entry.forceMapping)
        XCTAssertEqual(entry.extraFields["future-routing"], .object(["region": .string("us")]))
        XCTAssertEqual(entry.extraFields["priority"], .number(3))
        XCTAssertNil(response.aliases["bad channel"])
    }

    func testAliasEncodingUsesDashedOptionsPreservesExtrasAndOmitsLocalUUID() throws {
        let localID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let entry = RuntimeOAuthModelAliasEntry(
            id: localID,
            name: " claude-3-7-sonnet ",
            alias: " claude-sonnet ",
            fork: true,
            displayName: " Claude Sonnet ",
            forceMapping: true,
            extraFields: ["future-routing": .object(["region": .string("us")])]
        )

        let object = try jsonObject(entry)

        XCTAssertEqual(object["name"] as? String, "claude-3-7-sonnet")
        XCTAssertEqual(object["alias"] as? String, "claude-sonnet")
        XCTAssertEqual(object["display-name"] as? String, "Claude Sonnet")
        XCTAssertEqual(object["fork"] as? Bool, true)
        XCTAssertEqual(object["force-mapping"] as? Bool, true)
        XCTAssertNotNil(object["future-routing"] as? [String: Any])
        XCTAssertFalse(object.keys.contains("id"))
        XCTAssertFalse(object.keys.contains("displayName"))
        XCTAssertFalse(object.keys.contains("forceMapping"))
    }

    func testPatchPayloadsUseExactProviderModelsAndChannelAliasesShape() throws {
        let excluded = RuntimeOAuthExcludedModelsPatch(
            provider: "codex",
            models: ["gpt-5", "o3"]
        )
        let excludedObject = try jsonObject(excluded)
        XCTAssertEqual(Set(excludedObject.keys), ["provider", "models"])
        XCTAssertEqual(excludedObject["provider"] as? String, "codex")
        XCTAssertEqual(excludedObject["models"] as? [String], ["gpt-5", "o3"])

        let aliases = RuntimeOAuthModelAliasPatch(
            channel: "claude",
            aliases: [
                RuntimeOAuthModelAliasEntry(
                    name: "claude-3-7-sonnet",
                    alias: "claude-sonnet",
                    fork: true,
                    displayName: "Claude Sonnet",
                    forceMapping: true
                )
            ]
        )
        let aliasesObject = try jsonObject(aliases)
        XCTAssertEqual(Set(aliasesObject.keys), ["channel", "aliases"])
        XCTAssertEqual(aliasesObject["channel"] as? String, "claude")
        let encodedAliases = try XCTUnwrap(aliasesObject["aliases"] as? [[String: Any]])
        let encodedAlias = try XCTUnwrap(encodedAliases.first)
        XCTAssertEqual(encodedAlias["display-name"] as? String, "Claude Sonnet")
        XCTAssertEqual(encodedAlias["force-mapping"] as? Bool, true)
        XCTAssertEqual(encodedAlias["fork"] as? Bool, true)
        XCTAssertFalse(encodedAlias.keys.contains("id"))
    }

    func testValidatorRejectsEmptyFieldsSameNameAndDuplicateClientAliases() {
        XCTAssertNotNil(
            RuntimeOAuthModelPolicyValidator.validationMessage(for: [
                RuntimeOAuthModelAliasEntry(name: "", alias: "client-model")
            ])
        )
        XCTAssertNotNil(
            RuntimeOAuthModelPolicyValidator.validationMessage(for: [
                RuntimeOAuthModelAliasEntry(name: "upstream-model", alias: "")
            ])
        )
        XCTAssertNotNil(
            RuntimeOAuthModelPolicyValidator.validationMessage(for: [
                RuntimeOAuthModelAliasEntry(name: "Claude-3", alias: " claude-3 ")
            ])
        )
        XCTAssertNotNil(
            RuntimeOAuthModelPolicyValidator.validationMessage(for: [
                RuntimeOAuthModelAliasEntry(name: "upstream-a", alias: "client-model"),
                RuntimeOAuthModelAliasEntry(name: "upstream-b", alias: " CLIENT-MODEL ")
            ])
        )
        XCTAssertNil(
            RuntimeOAuthModelPolicyValidator.validationMessage(for: [
                RuntimeOAuthModelAliasEntry(name: "upstream-a", alias: "client-a"),
                RuntimeOAuthModelAliasEntry(name: "upstream-b", alias: "client-b")
            ])
        )
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
