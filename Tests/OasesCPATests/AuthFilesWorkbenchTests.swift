import XCTest
@testable import OasesCPA

@MainActor
final class AuthFilesWorkbenchTests: XCTestCase {
    func testDecodesDynamicAuthFileFieldsAndAliases() throws {
        let data = Data(
            """
            {
              "files": [
                {
                  "id": "runtime-1",
                  "name": "codex-one.json",
                  "type": "codex",
                  "provider": "OpenAI",
                  "auth_index": 7,
                  "status": "Ready",
                  "disabled": "false",
                  "unavailable": false,
                  "runtime_only": true,
                  "email": "user@example.com",
                  "projectId": "project-a",
                  "priority": "12",
                  "note": "primary",
                  "id_token": { "plan_type": "plus" },
                  "size": 2048,
                  "modified": 1735689600000
                }
              ],
              "total": 1
            }
            """.utf8
        )

        let response = try JSONDecoder().decode(AuthFilesWorkbenchResponse.self, from: data)
        let file = try XCTUnwrap(response.files.first)

        XCTAssertEqual(file.id, "runtime-1")
        XCTAssertEqual(file.providerTitle, "OpenAI")
        XCTAssertEqual(file.authIndex, "7")
        XCTAssertEqual(file.email, "user@example.com")
        XCTAssertEqual(file.projectID, "project-a")
        XCTAssertEqual(file.priority, 12)
        XCTAssertEqual(file.plan, "plus")
        XCTAssertEqual(file.size, 2048)
        XCTAssertEqual(file.modified, Date(timeIntervalSince1970: 1735689600))
        XCTAssertFalse(file.needsAttention)
    }

    func testFiltersBySearchProviderAndAttention() throws {
        let files = try fixtureFiles()
        let store = AuthFilesWorkbenchStore(files: files)

        store.providerFilter = .provider("claude")
        store.attentionFilter = .attention
        store.searchText = "expired"

        XCTAssertEqual(store.filteredFiles.map(\.name), ["claude-expired.json"])
    }

    func testSortsByPriorityAndPlanWithStableNameTieBreak() throws {
        let files = try fixtureFiles()
        let store = AuthFilesWorkbenchStore(files: files)

        store.sort = .priority
        XCTAssertEqual(store.filteredFiles.map(\.name), ["codex-high.json", "codex-low.json", "claude-expired.json"])

        store.sort = .plan
        XCTAssertEqual(store.filteredFiles.map(\.name), ["claude-expired.json", "codex-high.json", "codex-low.json"])
    }

    func testDecodesModelListResponse() throws {
        let data = Data("""
        { "models": [
          { "id": "gpt-4.1", "display_name": "GPT-4.1", "type": "text", "owned_by": "openai" },
          { "id": "claude-3-7-sonnet" }
        ] }
        """.utf8)

        let response = try JSONDecoder().decode(AuthFilesWorkbenchModelsResponse.self, from: data)
        XCTAssertEqual(response.models.count, 2)
        XCTAssertEqual(response.models[0].displayName, "GPT-4.1")
        XCTAssertNil(response.models[1].displayName)
    }

    func testSameNameRuntimeCredentialsKeepIndependentIdentityAndSafeMutationSelector() throws {
        let data = Data(
            """
            { "files": [
              { "id": "runtime-xai-1", "name": "shared-plugin.json", "provider": "xai", "auth_index": 1 },
              { "id": "runtime-xai-2", "name": "shared-plugin.json", "provider": "xai", "auth_index": 2 }
            ] }
            """.utf8
        )

        let files = try JSONDecoder().decode(AuthFilesWorkbenchResponse.self, from: data).files
        let store = AuthFilesWorkbenchStore(files: files)

        XCTAssertEqual(Set(files.map(\.id)), ["runtime-xai-1", "runtime-xai-2"])
        XCTAssertEqual(files.map(\.mutationSelector), ["runtime-xai-1", "runtime-xai-2"])

        files.forEach(store.toggleSelection)
        XCTAssertEqual(store.selectedIDs, ["runtime-xai-1", "runtime-xai-2"])
    }

    private func fixtureFiles() throws -> [AuthFilesWorkbenchFile] {
        let data = Data("""
        { "files": [
          { "name": "codex-low.json", "provider": "codex", "priority": 2, "plan": "plus", "status": "Ready" },
          { "name": "codex-high.json", "provider": "codex", "priority": 10, "plan": "plus", "status": "Ready" },
          { "name": "claude-expired.json", "provider": "claude", "priority": 1, "plan": "free", "status": "expired", "status_message": "expired" }
        ] }
        """.utf8)
        return try JSONDecoder().decode(AuthFilesWorkbenchResponse.self, from: data).files
    }
}
