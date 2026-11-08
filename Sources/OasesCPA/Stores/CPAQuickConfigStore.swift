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
        RuntimeCPAQuickConfigField.allCases.filter { !$0.isReadOnly && draft[$0] != baseline[$0] }
    }

    var changedRiskyFields: [RuntimeCPAQuickConfigField] {
        changedFields.filter(\.isRisky)
    }

    /// Read-only fields are shown, never changed.
    func setValue(_ value: RuntimeCPAQuickConfigValue, for field: RuntimeCPAQuickConfigField) {
        guard !field.isReadOnly else { return }
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
            lastErrorMessage = OasesLocalization.localized("部分设置暂时无法读取，可继续使用并稍后重试。")
        }
    }

    /// Saves each changed endpoint independently. Successful fields are
    /// committed to the baseline, while failed fields remain dirty so the
    /// same draft can be retried without re-entering it.
    ///
    /// Endpoint fields are written concurrently; the config-file fields after them, one at a
    /// time: an endpoint write rewrites config.yaml too, so a read-modify-write of the file
    /// running beside it could undo it.
    func save(baseURL: URL, managementKey: String) async {
        guard !isSaving else { return }
        let fields = changedFields
        guard !fields.isEmpty else { return }

        let submittedValues = Dictionary(uniqueKeysWithValues: fields.map { ($0, draft[$0]) })
        isSaving = true
        lastErrorMessage = nil
        fieldErrors = fieldErrors.filter { !fields.contains($0.key) }
        var saveFailed = false

        let endpointFields = fields.filter { $0.transport == .endpoint }
        let fileFields = fields.filter { $0.transport != .endpoint }
        await withTaskGroup(of: (RuntimeCPAQuickConfigField, String?).self) { group in
            for field in endpointFields {
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

        for field in fileFields {
            let value = submittedValues[field]!
            do {
                try await saveOperation(field, value, baseURL, managementKey)
                baseline[field] = value
                fieldErrors[field] = nil
            } catch {
                saveFailed = true
                fieldErrors[field] = error.localizedDescription
            }
        }

        isSaving = false
        if saveFailed {
            lastErrorMessage = OasesLocalization.localized("部分设置保存失败；失败项目仍保留为未保存状态。")
        } else if !fieldErrors.isEmpty {
            lastErrorMessage = OasesLocalization.localized("部分设置暂时无法使用；可重新读取或继续使用其他设置。")
        }
    }
}
