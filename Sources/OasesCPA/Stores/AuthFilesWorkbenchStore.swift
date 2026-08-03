import Foundation
import Combine

@MainActor
final class AuthFilesWorkbenchStore: ObservableObject {
    @Published private(set) var files: [AuthFilesWorkbenchFile] = []
    @Published private(set) var total: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var isMutating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedIDs: Set<String> = []

    @Published var searchText = ""
    @Published var providerFilter: AuthFilesWorkbenchProviderFilter = .all
    @Published var attentionFilter: AuthFilesWorkbenchAttentionFilter = .all
    @Published var sort: AuthFilesWorkbenchSort = .default
    @Published var displayMode: AuthFilesWorkbenchDisplayMode = .regular

    init(files: [AuthFilesWorkbenchFile] = []) {
        self.files = files
        self.total = files.count
    }

    var providers: [String] {
        Array(Set(files.map(\.providerTitle))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    var filteredFiles: [AuthFilesWorkbenchFile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = files.filter { file in
            let matchesQuery = query.isEmpty || file.searchableText.contains(query)
            let matchesProvider: Bool
            switch providerFilter {
            case .all:
                matchesProvider = true
            case .provider(let provider):
                matchesProvider = file.providerTitle == provider
            }
            let matchesAttention: Bool
            switch attentionFilter {
            case .all:
                matchesAttention = true
            case .attention:
                matchesAttention = file.needsAttention
            case .enabled:
                matchesAttention = !file.isDisabled
            case .disabled:
                matchesAttention = file.isDisabled
            }
            return matchesQuery && matchesProvider && matchesAttention
        }

        switch sort {
        case .default:
            return filtered
        case .name:
            return filtered.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .priority:
            return filtered.sorted {
                if $0.priority != $1.priority { return ($0.priority ?? 0) > ($1.priority ?? 0) }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .plan:
            return filtered.sorted {
                let lhs = $0.plan ?? ""
                let rhs = $1.plan ?? ""
                if lhs.caseInsensitiveCompare(rhs) != .orderedSame {
                    return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    var selectedVisibleCount: Int {
        Set(filteredFiles.map(\.id)).intersection(selectedIDs).count
    }

    func refresh(baseURL: URL, managementKey: String) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let response = try await ManagementAPIClient().authFilesWorkbench(
                baseURL: baseURL,
                managementKey: managementKey
            )
            files = response.files.filter { !$0.name.isEmpty }
            total = response.total
            selectedIDs = selectedIDs.intersection(Set(files.map(\.id)))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadModels(
        for file: AuthFilesWorkbenchFile,
        baseURL: URL,
        managementKey: String
    ) async throws -> [AuthFilesWorkbenchModel] {
        try await ManagementAPIClient().authFileWorkbenchModels(
            name: file.name,
            baseURL: baseURL,
            managementKey: managementKey
        ).models
    }

    func toggleSelection(for file: AuthFilesWorkbenchFile) {
        if selectedIDs.contains(file.id) {
            selectedIDs.remove(file.id)
        } else {
            selectedIDs.insert(file.id)
        }
    }

    func setVisibleSelection(_ selected: Bool) {
        let visible = Set(filteredFiles.map(\.id))
        if selected {
            selectedIDs.formUnion(visible)
        } else {
            selectedIDs.subtract(visible)
        }
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    func selectOnly(_ file: AuthFilesWorkbenchFile) {
        selectedIDs = [file.id]
    }

    func setDisabled(
        _ file: AuthFilesWorkbenchFile,
        disabled: Bool,
        baseURL: URL,
        managementKey: String
    ) async {
        _ = await mutate(baseURL: baseURL, managementKey: managementKey) {
            try await ManagementAPIClient().patchAuthFileWorkbenchStatus(
                AuthFilesWorkbenchStatusPatch(
                    name: file.mutationSelector,
                    authIndex: file.authIndex,
                    disabled: disabled
                ),
                baseURL: baseURL,
                managementKey: managementKey
            )
        }
    }

    func patchFields(
        _ patch: AuthFilesWorkbenchFieldsPatch,
        baseURL: URL,
        managementKey: String
    ) async {
        _ = await mutate(baseURL: baseURL, managementKey: managementKey) {
            try await ManagementAPIClient().patchAuthFileWorkbenchFields(
                patch,
                baseURL: baseURL,
                managementKey: managementKey
            )
        }
    }

    func deleteSelected(baseURL: URL, managementKey: String) async {
        let selected = selectedIDs
        guard !selected.isEmpty else { return }
        let selectors = files
            .filter { selected.contains($0.id) }
            .map(\.mutationSelector)
        let succeeded = await mutate(baseURL: baseURL, managementKey: managementKey) {
            try await ManagementAPIClient().deleteAuthFilesWorkbench(
                names: selectors,
                baseURL: baseURL,
                managementKey: managementKey
            )
        }
        if succeeded {
            selectedIDs.subtract(selected)
        }
    }

    func deleteAll(baseURL: URL, managementKey: String) async {
        let succeeded = await mutate(baseURL: baseURL, managementKey: managementKey) {
            try await ManagementAPIClient().deleteAllAuthFilesWorkbench(
                baseURL: baseURL,
                managementKey: managementKey
            )
        }
        if succeeded {
            selectedIDs.removeAll()
        }
    }

    private func mutate(
        baseURL: URL,
        managementKey: String,
        operation: () async throws -> Void
    ) async -> Bool {
        guard !isMutating else { return false }
        isMutating = true
        errorMessage = nil
        defer { isMutating = false }
        do {
            try await operation()
            await refresh(baseURL: baseURL, managementKey: managementKey)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
