import Foundation
import Observation

/// The language choices exposed by the app. The system option keeps the app
/// aligned with the user's macOS language preference.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public static let defaultsKey = "oasesCPA.appLanguage"

    public var id: String { rawValue }

    public var locale: Locale {
        switch self {
        case .system:
            // The macOS region, in the language the app resolves "Follow System" to, so
            // `Text` literals (looked up through this locale) and `OasesLocalization`
            // (looked up through `resolved`) always pick the same table.
            let language = resolved.rawValue
            guard let region = Locale.current.region?.identifier else { return Locale(identifier: language) }
            return Locale(identifier: "\(language)_\(region)")
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        case .english:
            return Locale(identifier: "en")
        }
    }

    /// The language the UI is shown in: `.simplifiedChinese` or `.english`, never `.system`.
    public var resolved: AppLanguage {
        switch self {
        case .system:
            return Self.systemLanguage(preferredLanguages: Locale.preferredLanguages)
        case .simplifiedChinese, .english:
            return self
        }
    }

    /// "Follow System": the first macOS preferred language the app has a table for
    /// (any Chinese → Simplified Chinese, any English → English); English otherwise.
    public static func systemLanguage(preferredLanguages: [String]) -> AppLanguage {
        for identifier in preferredLanguages {
            let lowercased = identifier.lowercased()
            if lowercased.hasPrefix("zh") { return .simplifiedChinese }
            if lowercased.hasPrefix("en") { return .english }
        }
        return .english
    }

    /// A language picker label rendered in the currently selected UI language.
    public func displayTitle(in interfaceLanguage: AppLanguage) -> String {
        let useEnglish = interfaceLanguage.resolved == .english

        switch self {
        case .system:
            return useEnglish ? "Follow System" : "跟随系统"
        case .simplifiedChinese:
            return useEnglish ? "Simplified Chinese" : "简体中文"
        case .english:
            return "English"
        }
    }

    fileprivate var resourceLocaleIdentifier: String {
        resolved.rawValue
    }
}

extension Notification.Name {
    /// Posted on the main queue after the in-app language changed. Stores that keep
    /// already-translated text (status lines, error messages) translate it again.
    static let oasesLanguageDidChange = Notification.Name("oasesCPA.languageDidChange")
}

/// The reactive side of the in-app language.
///
/// `OasesLocalization.localized` is evaluated when a SwiftUI body runs and returns a plain
/// `String`, so on its own a view never learns that the language changed. Every lookup
/// therefore registers an Observation-framework access on this object; any view body (or
/// `Commands`/menu body) that looked up a string is invalidated by SwiftUI when the
/// language changes, exactly like a view that reads an `@Observable` model. This makes the
/// existing call sites correct by construction without resetting view identity (drafts,
/// scroll positions and selections survive a language switch).
///
/// The persisted value stays in `UserDefaults` (`AppLanguage.defaultsKey`, written by the
/// Settings picker through `@AppStorage`); this object watches it and publishes changes.
public final class OasesLanguageObserver: Observable, @unchecked Sendable {
    public static let shared = OasesLanguageObserver()

    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var observedRawValue: String
    private var revisionStorage = 0
    private var token: NSObjectProtocol?

    private init() {
        observedRawValue = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey) ?? AppLanguage.system.rawValue
        token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.synchronize()
        }
    }

    /// Bumped on every language change. Reading it registers an observation access.
    public var revision: Int {
        registrar.access(self, keyPath: \.revision)
        return lock.withLock { revisionStorage }
    }

    /// Registers the calling view body (or any `withObservationTracking` scope) as a
    /// dependent of the language.
    public func registerAccess() {
        registrar.access(self, keyPath: \.revision)
    }

    /// Compares the persisted language with the last one seen and publishes a change.
    /// Runs on every `UserDefaults` change notification; cheap when nothing changed.
    public func synchronize() {
        let current = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey) ?? AppLanguage.system.rawValue
        let changed: Bool = lock.withLock {
            guard current != observedRawValue else { return false }
            observedRawValue = current
            return true
        }
        guard changed else { return }
        registrar.withMutation(of: self, keyPath: \.revision) {
            lock.withLock { revisionStorage += 1 }
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .oasesLanguageDidChange, object: nil)
        }
    }
}

/// Small Foundation-only localization bridge shared by the Xcode app target
/// and the SwiftPM target. SwiftPM exposes resources through Bundle.module;
/// the Xcode app uses its main bundle.
public enum OasesLocalization {
    public static let defaultsKey = AppLanguage.defaultsKey

    private static var resourceBundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    /// The language chosen in Settings. Reading it makes the caller (a SwiftUI body, a
    /// `Commands` body) depend on the language, see `OasesLanguageObserver`.
    public static var preferredLanguage: AppLanguage {
        OasesLanguageObserver.shared.registerAccess()
        let rawValue = UserDefaults.standard.string(forKey: defaultsKey) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    /// Persists the in-app language (what the Settings picker does through `@AppStorage`)
    /// and publishes the change immediately.
    public static func setPreferredLanguage(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: defaultsKey)
        OasesLanguageObserver.shared.synchronize()
    }

    public static func bundle(for language: AppLanguage = .system) -> Bundle {
        guard let path = resourceBundle.path(forResource: language.resourceLocaleIdentifier, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            return resourceBundle
        }
        return localizedBundle
    }

    public static func localized(
        _ source: String,
        language: AppLanguage? = nil,
        comment: String = ""
    ) -> String {
        let language = language ?? preferredLanguage
        return NSLocalizedString(
            source,
            tableName: "Localizable",
            bundle: bundle(for: language),
            value: source,
            comment: comment
        )
    }

    /// Looks up `source` (a format key such as `"已发现 %lld 个可用模型。"`) and fills in
    /// `arguments`. A translation whose specifiers do not fit the arguments (a wrong type or
    /// count) never reaches `String(format:)`: it is rendered with every argument as text
    /// instead (see `OasesFormat`), so a localization mistake cannot crash the app.
    public static func localizedFormat(
        _ source: String,
        language: AppLanguage? = nil,
        _ arguments: CVarArg...
    ) -> String {
        let language = language ?? preferredLanguage
        return OasesFormat.format(
            localized(source, language: language),
            locale: language.locale,
            arguments: arguments
        )
    }
}

extension OasesLocalization {
    /// Translates `text` that an earlier `localized`/`localizedFormat` call produced in either
    /// of the app's languages into `language` (default: the current one). Text that is not
    /// one of the app's strings (a raw server message, user data) is returned unchanged.
    ///
    /// Stores keep some already-translated text (a status line, an error message); after a
    /// language switch they pass it through here instead of re-running the operation.
    public static func relocalized(_ text: String, to language: AppLanguage? = nil) -> String {
        guard !text.isEmpty else { return text }
        let target = (language ?? preferredLanguage).resolved
        return OasesRelocalizationTables.shared.translate(text, to: target) ?? text
    }

    public static func relocalized(_ text: String?, to language: AppLanguage? = nil) -> String? {
        text.map { relocalized($0, to: language) }
    }
}

/// Reverse lookup over both `Localizable.strings` tables, built once on first use.
final class OasesRelocalizationTables: @unchecked Sendable {
    static let shared = OasesRelocalizationTables()

    private struct FormatEntry {
        let key: String
        let regex: NSRegularExpression
        /// Argument index of each capture group, in order of appearance.
        let captureArguments: [Int]
        let argumentCount: Int
        let literalLength: Int
    }

    private let tables: [AppLanguage: [String: String]]
    /// value → key, for values without format specifiers.
    private let exact: [AppLanguage: [String: String]]
    private let formats: [AppLanguage: [FormatEntry]]

    private init() {
        var tables: [AppLanguage: [String: String]] = [:]
        var exact: [AppLanguage: [String: String]] = [:]
        var formats: [AppLanguage: [FormatEntry]] = [:]
        for language in [AppLanguage.simplifiedChinese, .english] {
            let bundle = OasesLocalization.bundle(for: language)
            let table = bundle.path(forResource: "Localizable", ofType: "strings")
                .flatMap { NSDictionary(contentsOfFile: $0) as? [String: String] } ?? [:]
            tables[language] = table
            var reverse: [String: String] = [:]
            var entries: [FormatEntry] = []
            for (key, value) in table.sorted(by: { $0.key < $1.key }) {
                let specifiers = OasesFormat.specifiers(in: value)
                if specifiers.isEmpty {
                    let literal = value.replacingOccurrences(of: "%%", with: "%")
                    if reverse[literal] == nil { reverse[literal] = key }
                } else if let entry = Self.formatEntry(key: key, value: value, specifiers: specifiers) {
                    entries.append(entry)
                }
            }
            exact[language] = reverse
            formats[language] = entries
        }
        self.tables = tables
        self.exact = exact
        self.formats = formats
    }

    private static func formatEntry(key: String, value: String, specifiers: [OasesFormat.Specifier]) -> FormatEntry? {
        var pattern = "^"
        var cursor = value.startIndex
        var literalLength = 0
        var captures: [Int] = []
        for specifier in specifiers {
            let literal = value[cursor..<specifier.range.lowerBound].replacingOccurrences(of: "%%", with: "%")
            literalLength += literal.trimmingCharacters(in: .whitespacesAndNewlines).count
            pattern += NSRegularExpression.escapedPattern(for: literal)
            pattern += "(.*?)"
            captures.append(specifier.argument)
            cursor = specifier.range.upperBound
        }
        let tail = value[cursor...].replacingOccurrences(of: "%%", with: "%")
        literalLength += tail.trimmingCharacters(in: .whitespacesAndNewlines).count
        pattern += NSRegularExpression.escapedPattern(for: tail) + "$"
        // A format that is (almost) only specifiers would match any text.
        guard literalLength >= 2,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return nil }
        return FormatEntry(
            key: key,
            regex: regex,
            captureArguments: captures,
            argumentCount: (captures.max() ?? -1) + 1,
            literalLength: literalLength
        )
    }

    func translate(_ text: String, to target: AppLanguage) -> String? {
        guard let targetTable = tables[target] else { return nil }
        // The text is already in the target language.
        if exact[target]?[text] != nil { return text }
        for source in [AppLanguage.simplifiedChinese, .english] where source != target {
            if let key = exact[source]?[text] {
                return targetTable[key]?.replacingOccurrences(of: "%%", with: "%") ?? text
            }
        }
        // The format with the most literal text wins; a tie goes to the other language.
        var best: (language: AppLanguage, entry: FormatEntry, arguments: [CVarArg])?
        for language in [target] + [AppLanguage.simplifiedChinese, .english].filter({ $0 != target }) {
            guard let (entry, arguments) = bestFormatMatch(text, in: language) else { continue }
            if let current = best, current.entry.literalLength > entry.literalLength { continue }
            best = (language, entry, arguments)
        }
        guard let best, best.language != target, let format = targetTable[best.entry.key] else { return nil }
        // An argument that is itself one of the app's strings (a nested detail such as
        // "无法准备 SSH 主机指纹文件：known_hosts 文件打开失败") follows the switch too; anything
        // else (a host, a path, raw tool output) stays as it is.
        let arguments: [CVarArg] = best.arguments.map { argument in
            guard let text = argument as? String, !text.isEmpty else { return argument }
            return translate(text, to: target) ?? text
        }
        return OasesFormat.format(format, locale: target.locale, arguments: arguments)
    }

    private func bestFormatMatch(_ text: String, in language: AppLanguage) -> (FormatEntry, [CVarArg])? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var best: (FormatEntry, [CVarArg])?
        for entry in formats[language] ?? [] {
            if let current = best, current.0.literalLength >= entry.literalLength { continue }
            guard let match = entry.regex.firstMatch(in: text, range: range) else { continue }
            var arguments = [String](repeating: "", count: entry.argumentCount)
            for (group, argument) in entry.captureArguments.enumerated() {
                guard let captured = Range(match.range(at: group + 1), in: text) else { continue }
                arguments[argument] = String(text[captured])
            }
            best = (entry, arguments as [CVarArg])
        }
        return best
    }
}

/// `String(format:)` with a type check of the arguments against the specifiers.
public enum OasesFormat {
    /// One conversion in a format string.
    public struct Specifier: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case object, integer, floatingPoint, unsupported }
        public let range: Range<String.Index>
        /// The argument index (0-based): explicit for `%2$@`, else sequential.
        public let argument: Int
        public let kind: Kind
        public let isPositional: Bool
    }

    private static let pattern = #"%(?:([1-9][0-9]*)\$)?[-+ #0']*(?:[0-9]+|\*)?(?:\.(?:[0-9]+|\*))?(?:hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGaAcCsSpn%])"#

    /// The conversions of `format`, `%%` excluded.
    public static func specifiers(in format: String) -> [Specifier] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [Specifier] = []
        var next = 0
        let matches = regex.matches(in: format, range: NSRange(format.startIndex..<format.endIndex, in: format))
        for match in matches {
            guard let range = Range(match.range, in: format),
                  let conversionRange = Range(match.range(at: 2), in: format) else { continue }
            let conversion = format[conversionRange]
            if conversion == "%" { continue }
            let text = format[range]
            let kind: Specifier.Kind
            if text.contains("*") {
                kind = .unsupported
            } else {
                switch conversion {
                case "@": kind = .object
                case "d", "D", "i", "u", "U", "x", "X", "o", "O", "c": kind = .integer
                case "f", "F", "e", "E", "g", "G", "a", "A": kind = .floatingPoint
                default: kind = .unsupported
                }
            }
            if let positionRange = Range(match.range(at: 1), in: format), let position = Int(format[positionRange]) {
                result.append(Specifier(range: range, argument: position - 1, kind: kind, isPositional: true))
            } else {
                result.append(Specifier(range: range, argument: next, kind: kind, isPositional: false))
                next += 1
            }
        }
        return result
    }

    /// Whether `arguments` fit the conversions of `format` (types and count).
    public static func argumentsFit(_ format: String, _ arguments: [CVarArg]) -> Bool {
        let found = specifiers(in: format)
        if found.contains(where: \.isPositional) && found.contains(where: { !$0.isPositional }) { return false }
        for specifier in found {
            guard specifier.argument < arguments.count else { return false }
            let argument = arguments[specifier.argument]
            let isInteger = argument is any BinaryInteger
            let isFloatingPoint = argument is any BinaryFloatingPoint
            switch specifier.kind {
            case .object: if isInteger || isFloatingPoint { return false }
            case .integer: if !isInteger { return false }
            case .floatingPoint: if !isFloatingPoint { return false }
            case .unsupported: return false
            }
        }
        return true
    }

    public static func format(_ format: String, locale: Locale, arguments: [CVarArg]) -> String {
        if argumentsFit(format, arguments) {
            return String(format: format, locale: locale, arguments: arguments)
        }
        // Every conversion becomes its argument as text; a missing argument is empty.
        var text = ""
        var cursor = format.startIndex
        for specifier in specifiers(in: format) {
            text += format[cursor..<specifier.range.lowerBound].replacingOccurrences(of: "%%", with: "%")
            if specifier.argument < arguments.count {
                text += String(describing: arguments[specifier.argument])
            }
            cursor = specifier.range.upperBound
        }
        text += format[cursor...].replacingOccurrences(of: "%%", with: "%")
        return text
    }
}
