import Foundation

/// A coding key for any string (dynamic JSON objects).
struct AnyCodingKey: CodingKey, Hashable, Sendable {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension AnyCodingKey {
    /// `snake_case` as `JSONDecoder.KeyDecodingStrategy.convertFromSnakeCase` spells it
    /// (`display_name` → `displayName`).
    static func camelCase(_ snake: String) -> String {
        let parts = snake.split(separator: "_", omittingEmptySubsequences: true)
        guard let first = parts.first else { return snake }
        return String(first) + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    /// The value of the snake_case field `snake`, also when the decoder converted it to camelCase
    /// (`.convertFromSnakeCase`): a model with snake_case keys then decodes the same with either
    /// decoder. A JSON null is nil.
    func decodeIfPresent<T: Decodable>(_ type: T.Type, snakeOrCamel snake: String) throws -> T? {
        for name in [snake, AnyCodingKey.camelCase(snake)] {
            let key = AnyCodingKey(name)
            guard contains(key) else { continue }
            if try decodeNil(forKey: key) { return nil }
            return try decode(T.self, forKey: key)
        }
        return nil
    }
}

/// Keeps the fields of a gateway object that a model does not know, so that a write-back
/// (read, edit, save) never drops what a newer gateway added.
enum UnknownFields {
    /// Every field of the object being decoded whose name is not in `known`.
    static func capture(from decoder: Decoder, known: Set<String>) throws -> [String: RuntimeJSONValue] {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var fields: [String: RuntimeJSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            fields[key.stringValue] = try container.decode(RuntimeJSONValue.self, forKey: key)
        }
        return fields
    }

    /// Writes `fields` into the object being encoded, except names in `known` (the model's own
    /// fields always win).
    static func encode(_ fields: [String: RuntimeJSONValue], to encoder: Encoder, skipping known: Set<String>) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        for (name, value) in fields where !known.contains(name) {
            try container.encode(value, forKey: AnyCodingKey(name))
        }
    }
}

/// Dates as the gateway writes them: JavaScript's `Date#toISOString()` (UTC with
/// milliseconds, "2026-11-08T01:02:03.456Z") and epoch milliseconds (`*_ms` fields).
enum GatewayDates {
    private static let withMilliseconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutMilliseconds = Date.ISO8601FormatStyle()

    /// Accepts the timestamp with or without fractional seconds.
    static func date(from string: String) -> Date? {
        if let date = try? withMilliseconds.parse(string) { return date }
        return try? withoutMilliseconds.parse(string)
    }

    /// Rounds to the millisecond (the format style alone would truncate).
    static func string(from date: Date) -> String {
        let milliseconds = epochMilliseconds(from: date)
        var seconds = milliseconds / 1_000
        var fraction = milliseconds % 1_000
        if fraction < 0 {
            seconds -= 1
            fraction += 1_000
        }
        let whole = withoutMilliseconds.format(Date(timeIntervalSince1970: TimeInterval(seconds)))
        return String(whole.dropLast()) + String(format: ".%03lldZ", fraction)
    }

    static func date(fromEpochMilliseconds milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    static func epochMilliseconds(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
