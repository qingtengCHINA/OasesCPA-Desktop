import XCTest
@testable import OasesCPA

final class SystemModelDirectoryTests: XCTestCase {
    func testClassificationUsesOwnedByAndModelFamily() {
        let openAI = RuntimeGatewayModel(id: "gpt-4o-mini", displayName: nil, ownedBy: "OpenAI")
        let namespaced = RuntimeGatewayModel(id: "moonshotai/kimi-k2", displayName: nil, ownedBy: nil)

        XCTAssertEqual(
            SystemModelDirectory.classification(for: openAI),
            SystemModelDirectoryClassification(provider: "OpenAI", family: "gpt-4o")
        )
        XCTAssertEqual(
            SystemModelDirectory.classification(for: namespaced),
            SystemModelDirectoryClassification(provider: "moonshotai", family: "kimi-k2")
        )
    }

    func testGroupsAreStableAndSortedByProviderAndFamily() {
        let models = [
            RuntimeGatewayModel(id: "gpt-4o-mini", displayName: nil, ownedBy: "openai"),
            RuntimeGatewayModel(id: "claude-3-7-sonnet", displayName: nil, ownedBy: "anthropic"),
            RuntimeGatewayModel(id: "gpt-4.1", displayName: nil, ownedBy: "openai"),
            RuntimeGatewayModel(id: "gpt-4o", displayName: nil, ownedBy: "openai")
        ]

        let groups = SystemModelDirectory.groups(for: models)

        XCTAssertEqual(groups.map(\.id), ["anthropic/claude-3", "openai/gpt-4", "openai/gpt-4o"])
        XCTAssertEqual(groups[1].models.map(\.id), ["gpt-4.1"])
        XCTAssertEqual(groups[2].models.map(\.id), ["gpt-4o", "gpt-4o-mini"])
    }

    func testSearchMatchesIDDisplayNameAndProviderAndPreservesStableOrder() {
        let models = [
            RuntimeGatewayModel(id: "gpt-4o", displayName: "GPT 4 Omni", ownedBy: "openai"),
            RuntimeGatewayModel(id: "claude-3-7-sonnet", displayName: "Claude Sonnet", ownedBy: "anthropic"),
            RuntimeGatewayModel(id: "custom-vision", displayName: "Vision Gateway", ownedBy: "Acme")
        ]

        XCTAssertEqual(
            SystemModelDirectory.filteredModels(models, query: "omni").map(\.id),
            ["gpt-4o"]
        )
        XCTAssertEqual(
            SystemModelDirectory.filteredModels(models, query: "ANTHROPIC").map(\.id),
            ["claude-3-7-sonnet"]
        )
        XCTAssertEqual(
            SystemModelDirectory.groups(for: models, query: "vision").flatMap { $0.models }.map(\.id),
            ["custom-vision"]
        )
    }

    func testEmptyDirectoryDoesNotInventGroups() {
        XCTAssertTrue(SystemModelDirectory.groups(for: []).isEmpty)
        XCTAssertTrue(SystemModelDirectory.groups(for: [
            RuntimeGatewayModel(id: "gpt-4o", displayName: nil, ownedBy: "openai")
        ], query: "missing").isEmpty)
    }

    func testGatewayModelsResponseDropsInternalIDs() throws {
        let response = try JSONDecoder().decode(RuntimeGatewayModelsResponse.self, from: Data("""
        {"object":"list","data":[{"id":"a","owned_by":"x"},{"id":"pin-x/a","owned_by":"x"},{"id":"cc-pin-x/a"},{"id":"team-a/b"}]}
        """.utf8))
        XCTAssertEqual(response.data.map(\.id), ["a", "team-a/b"])
    }

    func testGroupedModelsBecomeADirectoryWithoutInternalIDs() {
        let models = RuntimeGatewayModel.directory(fromGroupedModels: [
            "compat-a": ["glm-5", "pin-a/glm-5"],
            "compat-b": ["glm-5"],
            "认证文件 / 引擎模型": ["gpt-5.5"]
        ])
        XCTAssertEqual(models.map(\.id), ["glm-5", "gpt-5.5"])
        XCTAssertEqual(models.map(\.ownedBy), ["compat-a", "认证文件 / 引擎模型"])
    }
}
