import SwiftUI

enum OasesAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let defaultsKey = "oases.cpa.appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: OasesLocalization.localized("跟随系统")
        case .light: OasesLocalization.localized("浅色")
        case .dark: OasesLocalization.localized("深色")
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
