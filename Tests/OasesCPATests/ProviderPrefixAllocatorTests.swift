import Foundation
import XCTest
@testable import OasesCPA

/// Vectors copied from the panel's `utils/internalPrefix.test.ts` (and the gateway's
/// `internalPrefixFor` in `gateway/provider-routing.mjs`, which must produce the same strings).
final class ProviderPrefixAllocatorTests: XCTestCase {
    private func p(_ name: String) -> String { ProviderPrefixAllocator.internalPrefix(for: name) }
    private func r(_ prefix: String?, _ name: String?, _ taken: [String]) -> String? {
        ProviderPrefixAllocator.resolve(prefix: prefix, name: name, taken: taken)
    }

    func testInternalPrefixMatchesGatewayAndPanel() {
        let cases = ["mistral Student": "pin-mistral-student", "derouter(image 2)": "pin-derouter-image-2", "  --Open Router--  ": "pin-open-router",
                     "小红书": "pin-e2866d08", " 小红书 ": "pin-835f3dce", "": "pin-da39a3ee"]
        for (name, expected) in cases { XCTAssertEqual(p(name), expected, name) }
        // Every result is something the internal-id filter recognises.
        for name in ["mistral Student", "derouter(image 2)", "小红书", ""] {
            XCTAssertTrue(InternalModelID.isInternal("\(p(name))/some-model"), name)
        }
    }

    func testResolveNumbersCollisions() {
        XCTAssertEqual(r("", "DeepSeek 国内", []), "pin-deepseek");  XCTAssertEqual(r("", "DeepSeek 海外", ["pin-deepseek"]), "pin-deepseek-2")
        XCTAssertEqual(r("", "DeepSeek 海外", ["pin-deepseek-3", "pin-deepseek-2", "pin-deepseek"]), "pin-deepseek-4")
        XCTAssertEqual(r("", "DeepSeek 海外", ["  PIN-DeepSeek  "]), "pin-deepseek-2");  XCTAssertEqual(r("", "Team A", ["team-a"]), "pin-team-a")
        XCTAssertEqual(r(" team-a ", "Anything", []), "team-a");  XCTAssertNil(r(nil, "   ", []))
        XCTAssertEqual(r("", "小红书", ["pin-e2866d08", "pin-e2866d08-2"]), "pin-e2866d08-3")

        // The rest of the panel's resolveProviderPrefix vectors.
        XCTAssertEqual(r("", " Open Router ", []), "pin-open-router")
        XCTAssertEqual(r("   ", "mistral Student", []), "pin-mistral-student")
        XCTAssertEqual(r(nil, "小红书", []), "pin-e2866d08")
        XCTAssertNil(r("  ", nil, []))
        XCTAssertEqual(r("", "DeepSeek 国内", ["team-a", "pin-other"]), "pin-deepseek")
        XCTAssertEqual(r("", "DeepSeek 海外", ["pin-deepseek", "pin-deepseek-2"]), "pin-deepseek-3")
        XCTAssertEqual(r("", "DeepSeek 海外", ["Pin-Deepseek", " pin-DEEPSEEK-2 "]), "pin-deepseek-3")
        XCTAssertEqual(r("", "DeepSeek", ["pin-deepseek"]), "pin-deepseek-2")
        XCTAssertEqual(r("", "小红书", ["pin-e2866d08"]), "pin-e2866d08-2")
        XCTAssertEqual(r("", "DeepSeek 海外", ["", "   ", "pin-x"]), "pin-deepseek")
        XCTAssertEqual(r(" pin-deepseek ", "DeepSeek 海外", ["pin-deepseek"]), "pin-deepseek", "an existing prefix is never changed")
        XCTAssertEqual(r("Team-A", "Anything", ["team-a"]), "Team-A")
        XCTAssertNil(r("", "   ", ["pin-deepseek"]))
        // The engine and the gateway ignore leading/trailing "/": such a prefix is taken too.
        XCTAssertEqual(r("", "DeepSeek", ["/pin-deepseek/"]), "pin-deepseek-2")
    }

    func testPatchEncodesPriority() throws {
        let body = try JSONEncoder().encode(RuntimeOpenAICompatibilityPatch(priority: 5))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["priority"] as? Int, 5)
        XCTAssertEqual(Set(json.keys), ["priority"], "nil fields are not encoded")
        let unchanged = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(RuntimeOpenAICompatibilityPatch(name: "a"))) as? [String: Any])
        XCTAssertNil(unchanged["priority"], "no priority, no key: the engine keeps the stored one")
    }

    @MainActor
    func testUnloadedProviderListsBlockAutoAllocation() {
        // A store that has read nothing yet knows no prefixes.
        XCTAssertNil(ProviderPrefixAllocator.takenPrefixes(from: RuntimeDataStore(), excludingProviderNamed: nil))
        XCTAssertNil(ProviderPrefixAllocator.takenPrefixes(openAICompatibility: nil, directCredentials: [:], excludingProviderNamed: nil))
        XCTAssertNil(ProviderPrefixAllocator.takenPrefixes(openAICompatibility: [], directCredentials: nil, excludingProviderNamed: nil))

        let blocked = ProviderPrefixAllocator.prefixForNewProvider(typed: "  ", name: "DeepSeek", taken: nil)
        XCTAssertEqual(blocked, .failure(.providerListsNotLoaded))
        XCTAssertTrue((ProviderPrefixError.providerListsNotLoaded.errorDescription ?? "").contains("请先刷新供应商列表"))
        XCTAssertEqual(
            OasesLocalization.localized("请先刷新供应商列表，再保存新的 AI 服务（需要知道已在使用的前缀）。", language: .english),
            "Refresh the provider list first, then save the new AI service (the prefixes already in use must be known)."
        )
        // A typed prefix needs no inventory; a known inventory allocates.
        XCTAssertEqual(ProviderPrefixAllocator.prefixForNewProvider(typed: " relay ", name: "DeepSeek", taken: nil), .success("relay"))
        XCTAssertEqual(ProviderPrefixAllocator.prefixForNewProvider(typed: "", name: "DeepSeek", taken: ["pin-deepseek"]), .success("pin-deepseek-2"))
    }

    func testTakenPrefixesCoverCompatibleAndDirectProviders() throws {
        let compat = [
            RuntimeOpenAICompatibility(name: "DeepSeek 国内", prefix: "pin-deepseek", baseURL: "https://a.example.test/v1"),
            RuntimeOpenAICompatibility(name: "Editing", prefix: "pin-editing", baseURL: "https://b.example.test/v1"),
            RuntimeOpenAICompatibility(name: "No prefix", baseURL: "https://c.example.test/v1"),
        ]
        let credential = try RuntimeDirectProviderCredentialDecoder.decode(
            Data(#"{"claude-api-key":[{"api-key":"k-1","prefix":"team-a"},{"api-key":"k-2"}]}"#.utf8),
            kind: .claude,
            using: JSONDecoder()
        )
        let taken = try XCTUnwrap(ProviderPrefixAllocator.takenPrefixes(
            openAICompatibility: compat,
            directCredentials: [.claude: credential],
            excludingProviderNamed: " Editing "
        ))
        XCTAssertEqual(taken, ["pin-deepseek", "team-a"])
    }

    /// "Use automatic prefix" for a provider that exists: fills only an empty prefix, never
    /// replaces one, and needs the provider lists.
    func testAutomaticPrefixForAnExistingProviderOnlyFillsAnEmptyOne() {
        XCTAssertEqual(ProviderPrefixAllocator.automaticPrefixForExistingProvider(currentPrefix: "", name: "Relay", taken: ["pin-relay"]),
                       .success("pin-relay-2"))
        XCTAssertEqual(ProviderPrefixAllocator.automaticPrefixForExistingProvider(currentPrefix: " / ", name: "Relay", taken: []),
                       .success("pin-relay"), "a prefix of only slashes is empty to the engine")
        XCTAssertEqual(ProviderPrefixAllocator.automaticPrefixForExistingProvider(currentPrefix: "team-a", name: "Relay", taken: []),
                       .success(nil), "an existing prefix is never replaced")
        XCTAssertEqual(ProviderPrefixAllocator.automaticPrefixForExistingProvider(currentPrefix: "", name: "Relay", taken: nil),
                       .failure(.providerListsNotLoaded))
        XCTAssertNotEqual(OasesLocalization.localized("使用自动前缀", language: .english), "使用自动前缀")
    }
}
