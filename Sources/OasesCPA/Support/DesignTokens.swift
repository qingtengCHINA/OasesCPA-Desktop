import AppKit
import SwiftUI

// Design tokens of Oases CPA (Vercel/Geist-like, near-monochrome). Cards sit on a solid
// canvas with a 1 pt border; status colour goes only on dots, icons and one key word. The
// sidebar keeps the system vibrancy.

extension Color {
    /// Dynamic colour resolved per NSAppearance (light / dark), with optional alpha.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]).map {
                $0 == .darkAqua || $0 == .vibrantDark
            } ?? false
            return NSColor(hex: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

enum Oases {
    enum Color {
        // Canvas and surfaces
        static let background = SwiftUI.Color(light: 0xFAFAFA, dark: 0x000000)
        static let surface = SwiftUI.Color(light: 0xFFFFFF, dark: 0x0A0A0A)
        static let surfaceRaised = SwiftUI.Color(light: 0xFFFFFF, dark: 0x141414)
        static let surfaceSubtle = SwiftUI.Color(light: 0xFAFAFA, dark: 0x111111)
        static let surfacePressed = SwiftUI.Color(light: 0xF2F2F2, dark: 0x1A1A1A)
        static let wash = SwiftUI.Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.035, darkAlpha: 0.05)
        static let washStrong = SwiftUI.Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.08)
        static let track = SwiftUI.Color(light: 0xEAEAEA, dark: 0xFFFFFF, darkAlpha: 0.08)

        // Borders
        static let border = SwiftUI.Color(light: 0xEAEAEA, dark: 0x1F1F1F)
        static let borderStrong = SwiftUI.Color(light: 0xE0E0E0, dark: 0x292929)
        static let borderEmphasis = SwiftUI.Color(light: 0xD4D4D4, dark: 0x3D3D3D)

        // Text (AA on surface and canvas)
        static let textPrimary = SwiftUI.Color(light: 0x0A0A0A, dark: 0xEDEDED)
        static let textSecondary = SwiftUI.Color(light: 0x666666, dark: 0xA1A1A1)
        static let textTertiary = SwiftUI.Color(light: 0x6B6B6B, dark: 0x808080)
        static let textQuaternary = SwiftUI.Color(light: 0xB5B5B5, dark: 0x525252)

        // Ink: primary buttons, selected chips
        static let ink = SwiftUI.Color(light: 0x0A0A0A, dark: 0xFFFFFF)
        static let inkContrast = SwiftUI.Color(light: 0xFFFFFF, dark: 0x0A0A0A)
        static let inkPressed = SwiftUI.Color(light: 0x000000, dark: 0xD4D4D4)

        // Accent: links, focus, live data
        static let accent = SwiftUI.Color(light: 0x1A8CD8, dark: 0x1D9BF0)
        static let accentText = SwiftUI.Color(light: 0x0B6FB3, dark: 0x1D9BF0)
        static let accentSoft = SwiftUI.Color(light: 0x1D9BF0, dark: 0x1D9BF0, lightAlpha: 0.10, darkAlpha: 0.16)

        // Status fills (dots, icons, bars)
        static let success = SwiftUI.Color(light: 0x00976A, dark: 0x00BA7C)
        static let warning = SwiftUI.Color(light: 0xD97706, dark: 0xFBBF24)
        static let danger = SwiftUI.Color(light: 0xF4212E, dark: 0xF4212E)
        static let info = accent
        static let neutral = SwiftUI.Color(light: 0x737373, dark: 0xA1A1A1)
        /// Second categorical hue for charts only.
        static let violet = SwiftUI.Color(light: 0x7C5CE0, dark: 0x9B87F5)

        // Status text (AA)
        static let successText = SwiftUI.Color(light: 0x007A55, dark: 0x00BA7C)
        static let warningText = SwiftUI.Color(light: 0xA35200, dark: 0xFBBF24)
        static let dangerText = SwiftUI.Color(light: 0xD01A25, dark: 0xFF7A82)

        // Status tints (badges, banners)
        static let successBg = SwiftUI.Color(light: 0x00BA7C, dark: 0x00BA7C, lightAlpha: 0.10, darkAlpha: 0.12)
        static let successBorder = SwiftUI.Color(light: 0x00BA7C, dark: 0x00BA7C, lightAlpha: 0.35, darkAlpha: 0.35)
        static let warningBg = SwiftUI.Color(light: 0xF59E0B, dark: 0xFBBF24, lightAlpha: 0.10, darkAlpha: 0.10)
        static let warningBorder = SwiftUI.Color(light: 0xF59E0B, dark: 0xFBBF24, lightAlpha: 0.35, darkAlpha: 0.35)
        static let dangerBg = SwiftUI.Color(light: 0xF4212E, dark: 0xF4212E, lightAlpha: 0.08, darkAlpha: 0.12)
        static let dangerBorder = SwiftUI.Color(light: 0xF4212E, dark: 0xF4212E, lightAlpha: 0.35, darkAlpha: 0.35)
        static let infoBg = SwiftUI.Color(light: 0x1A8CD8, dark: 0x1D9BF0, lightAlpha: 0.08, darkAlpha: 0.12)
        static let infoBorder = SwiftUI.Color(light: 0x1A8CD8, dark: 0x1D9BF0, lightAlpha: 0.35, darkAlpha: 0.35)

        static let dangerFill = SwiftUI.Color(light: 0xD81B27, dark: 0xD81B27)
        static let dangerFillPressed = SwiftUI.Color(light: 0xB8141F, dark: 0xB8141F)
    }

    /// 4 pt grid at macOS sizes (13 pt body).
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let sm: CGFloat = 8
        static let m: CGFloat = 12
        static let md: CGFloat = 16
        static let l: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Detail-pane content inset.
        static let page: CGFloat = 28
        static let section: CGFloat = 24
    }

    enum Radius {
        static let panel: CGFloat = 12
        static let control: CGFloat = 8
        static let button: CGFloat = 6
        static let small: CGFloat = 5
        static let tight: CGFloat = 4
    }

    enum Motion {
        static let settle = Animation.spring(duration: 0.24, bounce: 0)
        static let stateChange = Animation.easeOut(duration: 0.16)

        static func press(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .easeOut(duration: 0.12)
        }
    }

    /// Semantic status: one tone drives the dot, text, badge background and border.
    enum Tone: Hashable, Sendable {
        case success, warning, danger, info, neutral

        var fill: SwiftUI.Color {
            switch self {
            case .success: Color.success
            case .warning: Color.warning
            case .danger: Color.danger
            case .info: Color.accent
            case .neutral: Color.neutral
            }
        }

        var text: SwiftUI.Color {
            switch self {
            case .success: Color.successText
            case .warning: Color.warningText
            case .danger: Color.dangerText
            case .info: Color.accentText
            case .neutral: Color.textSecondary
            }
        }

        var background: SwiftUI.Color {
            switch self {
            case .success: Color.successBg
            case .warning: Color.warningBg
            case .danger: Color.dangerBg
            case .info: Color.infoBg
            case .neutral: Color.washStrong
            }
        }

        var border: SwiftUI.Color {
            switch self {
            case .success: Color.successBorder
            case .warning: Color.warningBorder
            case .danger: Color.dangerBorder
            case .info: Color.infoBorder
            case .neutral: Color.borderStrong
            }
        }
    }
}

// MARK: - Legacy names

// Pages written before the redesign use these names; they now resolve to panel tokens so
// every screen shares one palette. Prefer `Oases.Color` / `Oases.Tone` in new code.
extension Color {
    static let oasesBlue = Oases.Color.accent
    static let oasesMint = Oases.Color.success
    static let oasesPurple = Oases.Color.violet
    static let oasesOrange = Oases.Color.warning
    static let oasesGreen = Oases.Color.success
    static let oasesRed = Oases.Color.danger
    static let oasesInk = Oases.Color.ink
}

extension View {
    /// Panel card chrome: surface fill, 1 pt border, 12 pt continuous corners.
    func oasesCard(cornerRadius: CGFloat = Oases.Radius.panel, fill: Color = Oases.Color.surface) -> some View {
        self
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Oases.Color.border, lineWidth: 1)
            }
    }

    /// Solid panel canvas behind detail panes (the sidebar stays vibrant).
    func oasesCanvas() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Oases.Color.background)
    }
}
