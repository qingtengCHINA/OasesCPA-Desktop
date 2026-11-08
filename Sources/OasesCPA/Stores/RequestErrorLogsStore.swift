import Foundation

/// The request-error files of the attached engine for the logs page: one list read per
/// explicit load (a 401 is shown, never retried), and a save that writes a redacted copy.
@MainActor
final class RequestErrorLogsStore: ObservableObject {
    @Published private(set) var files: [RuntimeRequestErrorLog] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var savingName: String?
    @Published private(set) var saveMessage: String?
    @Published private(set) var saveFailed = false

    private let client: ManagementAPIClient
    private var generation = 0

    init(session: URLSession = SecretBearingURLSession.shared) {
        client = ManagementAPIClient(session: session)
    }

    func load(baseURL: URL, managementKey: String) async {
        generation += 1
        let current = generation
        isLoading = true
        errorMessage = nil
        defer { if current == generation { isLoading = false } }
        do {
            let loaded = try await client.requestErrorLogs(baseURL: baseURL, managementKey: managementKey)
            guard current == generation else { return }
            files = loaded
            hasLoaded = true
        } catch {
            guard current == generation else { return }
            files = []
            hasLoaded = true
            errorMessage = SecretRedactor.redact(error.localizedDescription, secrets: [managementKey])
        }
    }

    func reset() {
        generation += 1
        files = []
        hasLoaded = false
        isLoading = false
        errorMessage = nil
        savingName = nil
        saveMessage = nil
        saveFailed = false
    }

    /// Downloads `file` and writes it to `destination` with secrets masked.
    func save(
        _ file: RuntimeRequestErrorLog,
        to destination: URL,
        baseURL: URL,
        managementKey: String,
        secrets: [String]
    ) async {
        savingName = file.name
        saveMessage = nil
        saveFailed = false
        defer { savingName = nil }
        do {
            let data = try await client.downloadRequestErrorLog(
                name: file.name,
                baseURL: baseURL,
                managementKey: managementKey
            )
            let redacted = RuntimeRequestErrorLogFiles.redactedContents(data, secrets: secrets + [managementKey])
            try redacted.write(to: destination, options: [.atomic])
            saveMessage = OasesLocalization.localizedFormat("已保存脱敏后的 %@。", file.name)
        } catch {
            saveFailed = true
            saveMessage = OasesLocalization.localizedFormat(
                "保存 %@ 失败：%@",
                file.name,
                SecretRedactor.redact(error.localizedDescription, secrets: secrets + [managementKey])
            )
        }
    }
}
