import Foundation

struct RuntimeLogsResponse: Decodable, Sendable {
    let lines: [String]
    let lineCount: Int
    let latestTimestamp: Int64
    let latestAfter: Int64?
    let nextCursor: String?
    let cursorReset: Bool

    private enum CodingKeys: String, CodingKey {
        case lines
        case lineCount = "line-count"
        case latestTimestamp = "latest-timestamp"
        case latestAfterDash = "latest-after"
        case latestAfter
        case nextCursor = "next-cursor"
        case nextCursorLegacy = "nextCursor"
        case cursorReset = "cursor-reset"
        case cursorResetLegacy = "cursorReset"
    }

    init(
        lines: [String],
        lineCount: Int,
        latestTimestamp: Int64,
        latestAfter: Int64?,
        nextCursor: String?,
        cursorReset: Bool
    ) {
        self.lines = lines
        self.lineCount = lineCount
        self.latestTimestamp = latestTimestamp
        self.latestAfter = latestAfter
        self.nextCursor = nextCursor
        self.cursorReset = cursorReset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lines = try container.decodeIfPresent([String].self, forKey: .lines) ?? []
        lineCount = Self.decodeInt(container, forKey: .lineCount) ?? lines.count
        latestTimestamp = Self.decodeInt64(container, forKey: .latestTimestamp) ?? 0
        latestAfter = Self.decodeInt64(container, forKey: .latestAfterDash)
            ?? Self.decodeInt64(container, forKey: .latestAfter)
        nextCursor = (try? container.decodeIfPresent(String.self, forKey: .nextCursor))
            ?? (try? container.decodeIfPresent(String.self, forKey: .nextCursorLegacy))
        cursorReset = Self.decodeBool(container, forKey: .cursorReset)
            ?? Self.decodeBool(container, forKey: .cursorResetLegacy)
            ?? false
    }

    private static func decodeInt<C: KeyedDecodingContainerProtocol>(
        _ container: C,
        forKey key: C.Key
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }

    private static func decodeInt64<C: KeyedDecodingContainerProtocol>(
        _ container: C,
        forKey key: C.Key
    ) -> Int64? {
        if let value = try? container.decodeIfPresent(Int64.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Int64(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int64(value)
        }
        return nil
    }

    private static func decodeBool<C: KeyedDecodingContainerProtocol>(
        _ container: C,
        forKey key: C.Key
    ) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        guard let value = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        switch value.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
}
