import Foundation

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
            return .current
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        case .english:
            return Locale(identifier: "en")
        }
    }

    /// A language picker label rendered in the currently selected UI language.
    public func displayTitle(in interfaceLanguage: AppLanguage) -> String {
        let useEnglish: Bool
        switch interfaceLanguage {
        case .english:
            useEnglish = true
        case .simplifiedChinese:
            useEnglish = false
        case .system:
            useEnglish = !(Locale.preferredLanguages.first?.hasPrefix("zh") ?? false)
        }

        switch self {
        case .system:
            return useEnglish ? "System Default" : "跟随系统"
        case .simplifiedChinese:
            return useEnglish ? "Simplified Chinese" : "简体中文"
        case .english:
            return "English"
        }
    }

    fileprivate var resourceLocaleIdentifier: String? {
        switch self {
        case .system:
            return nil
        case .simplifiedChinese:
            return "zh-Hans"
        case .english:
            return "en"
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

    public static var preferredLanguage: AppLanguage {
        let rawValue = UserDefaults.standard.string(forKey: defaultsKey) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    public static func bundle(for language: AppLanguage = .system) -> Bundle {
        guard let localeIdentifier = language.resourceLocaleIdentifier,
              let path = resourceBundle.path(forResource: localeIdentifier, ofType: "lproj"),
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
