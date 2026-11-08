import Foundation

/// One request-error file of the engine (`GET /v0/management/request-error-logs`).
///
/// Measured on CLIProxyAPI v8.0.51: `{"files":[{"name","size","modified"}]}`, `modified` in
/// Unix seconds, newest first, only `error-*.log` files; the list is empty while
/// `request-log` is on (the engine then keeps full request logs instead). Unknown fields are
/// ignored.
struct RuntimeRequestErrorLog: Identifiable, Equatable, Sendable {
    let name: String
    let size: Int64
    let modifiedAt: Date?

    var id: String { name }
}

struct RuntimeRequestErrorLogsResponse: Decodable, Sendable {
    let files: [RuntimeRequestErrorLog]

    init(from decoder: Decoder) throws {
        let root = try [String: RuntimeJSONValue](from: decoder)
        guard case .array(let items) = root["files"] else {
            files = []
            return
        }
        files = items.compactMap { item in
            guard case .object(let values) = item,
                  case .string(let name) = values["name"],
                  !name.isEmpty else { return nil }
            var size: Int64 = 0
            if case .number(let value) = values["size"], value.isFinite, value >= 0, value < 9.0e18 {
                size = Int64(value)
            }
            var modified: Date?
            if case .number(let value) = values["modified"], value.isFinite, value > 0 {
                modified = Date(timeIntervalSince1970: value)
            }
            return RuntimeRequestErrorLog(name: name, size: size, modifiedAt: modified)
        }
    }
}

/// Paths and saved contents of request-error files.
enum RuntimeRequestErrorLogFiles {
    static let listPath = "/v0/management/request-error-logs"

    /// The engine serves only `error-*.log` names without path separators
    /// (`DownloadRequestErrorLog`); anything else is refused before a request is made.
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty
            && name.hasPrefix("error-")
            && name.hasSuffix(".log")
            && !name.contains("/")
            && !name.contains("\\")
            && !name.contains("..")
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// The percent-encoded download path for `name`, or nil when the name is not one the engine
    /// serves.
    static func downloadPath(for name: String) -> String? {
        guard isValidName(name) else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%;")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return "\(listPath)/\(encoded)"
    }

    /// What is written to disk: the file as text with every secret masked (the target's own
    /// keys and every key shape the stack issues) and internal `pin-…/` model heads removed.
    /// Bytes that are not UTF-8 are replaced, never written raw.
    static func redactedContents(_ data: Data, secrets: [String]) -> Data {
        let text = String(decoding: data, as: UTF8.self)
        let redacted = InternalModelID.publicText(SecretRedactor.redact(text, secrets: secrets))
        return Data(redacted.utf8)
    }
}
