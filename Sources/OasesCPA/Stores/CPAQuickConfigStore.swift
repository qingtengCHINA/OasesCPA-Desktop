import Combine
import Foundation

@MainActor
final class CPAQuickConfigStore: ObservableObject {
    typealias LoadOperation = @Sendable (URL, String) async -> RuntimeCPAQuickConfigLoadResult
    typealias SaveOperation = @Sendable (
        RuntimeCPAQuickConfigField,
        RuntimeCPAQuickConfigValue,
        URL,
        String
    ) async throws -> Void

    @Published private(set) var baseline = RuntimeCPAQuickConfiguration.default
    @Published var draft = RuntimeCPAQuickConfiguration.default
    @Published private(set) var fieldErrors: [RuntimeCPAQuickConfigField: String] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var isLoaded = false
    @Published private(set) var lastErrorMessage: String?

    private let loadOperation: LoadOperation
    private let saveOperation: SaveOperation

    init() {
        loadOperation = { baseURL, managementKey in
            await ManagementAPIClient().loadQuickConfiguration(
                baseURL: baseURL,
                managementKey: managementKey
            )
        }
        saveOperation = { field, value, baseURL, managementKey in
            try await ManagementAPIClient().updateQuickConfigurationValue(
                value,
                for: field,
                baseURL: baseURL,
                managementKey: managementKey
            )
        }
    }

    init(
        loadOperation: @escaping LoadOperation,
        saveOperation: @escaping SaveOperation
    ) {
        self.loadOperation = loadOperation
        self.saveOperation = saveOperation
    }

    var isDirty: Bool {
        !changedFields.isEmpty
    }

    var changedFields: [RuntimeCPAQuickConfigField] {
        RuntimeCPAQuickConfigField.allCases.filter { draft[$0] != baseline[$0] }
    }

    var changedRiskyFields: [RuntimeCPAQuickConfigField] {
        changedFields.filter(\.isRisky)
    }

    func setValue(_ value: RuntimeCPAQuickConfigValue, for field: RuntimeCPAQuickConfigField) {
        draft[field] = value
    }

    func discardChanges() {
        draft = baseline
        lastErrorMessage = nil
        fieldErrors = [:]
    }

    func load(baseURL: URL, managementKey: String) async {
        guard !isLoading else { return }
        isLoading = true
        lastErrorMessage = nil

        let result = await loadOperation(baseURL, managementKey)
        baseline = result.configuration
        draft = result.configuration
        fieldErrors = result.errors
        isLoaded = true
        isLoading = false

        if !result.errors.isEmpty {
            lastErrorMessage = "部分设置暂时无法读取，可继续使用并稍后重试。"
        }
    }

    /// Saves each changed endpoint independently. Successful fields are
    /// committed to the baseline, while failed fields remain dirty so the
    /// same draft can be retried without re-entering it.
    func save(baseURL: URL, managementKey: String) async {
        guard !isSaving else { return }
        let fields = changedFields
        guard !fields.isEmpty else { return }

        let submittedValues = Dictionary(uniqueKeysWithValues: fields.map { ($0, draft[$0]) })
        isSaving = true
        lastErrorMessage = nil
        fieldErrors = fieldErrors.filter { !fields.contains($0.key) }
        var saveFailed = false

        await withTaskGroup(of: (RuntimeCPAQuickConfigField, String?).self) { group in
            for field in fields {
                let value = submittedValues[field]!
                group.addTask {
                    do {
                        try await self.saveOperation(field, value, baseURL, managementKey)
                        return (field, nil)
                    } catch {
                        return (field, error.localizedDescription)
                    }
                }
            }

            for await (field, errorMessage) in group {
                if let errorMessage {
                    saveFailed = true
                    fieldErrors[field] = errorMessage
                } else {
                    baseline[field] = submittedValues[field]!
                    fieldErrors[field] = nil
                }
            }
        }

        isSaving = false
        if saveFailed {
            lastErrorMessage = "部分设置保存失败；失败项目仍保留为未保存状态。"
        } else if !fieldErrors.isEmpty {
            lastErrorMessage = "部分设置暂时无法使用；可重新读取或继续使用其他设置。"
        }
    }
}
