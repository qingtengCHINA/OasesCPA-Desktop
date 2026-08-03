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

    public static func localizedFormat(
        _ source: String,
        language: AppLanguage? = nil,
        _ arguments: CVarArg...
    ) -> String {
        let language = language ?? preferredLanguage
        return String(
            format: localized(source, language: language),
            locale: language.locale,
            arguments: arguments
        )
    }
}
