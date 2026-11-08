import AppKit
import SwiftUI

// Design tokens of Oases CPA: a native macOS tool. Colours are system semantics (one grey
// family, the user's accent colour, system green/orange/red for status as a dot, symbol or one
// short word); three corner radii; a 4 pt spacing scale; type only through system text styles.
// Grouping comes from sections, `Form`, `Table` and hairlines, never from filled boxes.

enum Oases {
    enum Color {
        /// Window ground. Detail panes normally leave it to the system.
        static let background = SwiftUI.Color(nsColor: .windowBackgroundColor)
        /// Former card fill. Sections are not boxes any more, so this is transparent.
        static let surface = SwiftUI.Color.clear
        /// Inline value chips (monospaced values), radius `Radius.small`.
        static let surfaceSubtle = SwiftUI.Color(nsColor: .quaternarySystemFill)
        /// Hover and selection wash on custom rows.
        static let wash = SwiftUI.Color(nsColor: .quaternarySystemFill)
        static let washStrong = SwiftUI.Color(nsColor: .tertiarySystemFill)
        /// Progress and bar tracks.
        static let track = SwiftUI.Color(nsColor: .tertiarySystemFill)

        /// Hairlines.
        static let border = SwiftUI.Color(nsColor: .separatorColor)
        static let borderStrong = SwiftUI.Color(nsColor: .separatorColor)

        // Text: hierarchical label colours.
        static let textPrimary = SwiftUI.Color.primary
        static let textSecondary = SwiftUI.Color.secondary
        static let textTertiary = SwiftUI.Color(nsColor: .tertiaryLabelColor)
        static let textQuaternary = SwiftUI.Color(nsColor: .quaternaryLabelColor)

        /// Selected custom chips and similar emphasis: the system accent.
        static let ink = SwiftUI.Color.accentColor
        static let inkContrast = SwiftUI.Color.white

        /// The one accent: the user's macOS accent colour.
        static let accent = SwiftUI.Color.accentColor
        static let accentText = SwiftUI.Color.accentColor

        // Status (dots, symbols, one short word). System colours adapt to dark mode and
        // increased contrast.
        static let success = SwiftUI.Color.green
        static let warning = SwiftUI.Color.orange
        static let danger = SwiftUI.Color.red
        static let neutral = SwiftUI.Color.secondary
        static let successText = SwiftUI.Color.green
        static let warningText = SwiftUI.Color.orange
        static let dangerText = SwiftUI.Color.red
    }

    /// 4 pt scale: 4, 8, 12, 16, 20, 24, 32. `xxs` is only the gap between two text lines of
    /// one item; `s` is the vertical padding of a custom row.
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
        static let page: CGFloat = 20
        /// Between sections.
        static let section: CGFloat = 24
    }

    /// The only three corner radii. Everything else is drawn by the system.
    enum Radius {
        /// Inline monospaced value chips, badges in tables, progress tracks.
        static let small: CGFloat = 4
        /// Custom selection or hover highlight on a non-List row; text-editor frames.
        static let row: CGFloat = 6
        /// A custom popover or the welcome window's single frame.
        static let surface: CGFloat = 10
    }

    enum Motion {
        static let settle = Animation.spring(duration: 0.24, bounce: 0)
        static let stateChange = Animation.easeOut(duration: 0.16)

        static func press(reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : .easeOut(duration: 0.12)
        }
    }

    /// Semantic status: drives a dot or symbol colour and, for one short word, the text colour.
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
    }
}

// MARK: - Legacy names

// Pages written before the native redesign use these names; they resolve to the system accent
// and the system status colours so every screen shares one palette. No violet: the former
// purple is the accent.
extension Color {
    static let oasesBlue = Color.accentColor
    static let oasesMint = Color.green
    static let oasesPurple = Color.accentColor
    static let oasesOrange = Color.orange
    static let oasesGreen = Color.green
    static let oasesRed = Color.red
    static let oasesInk = Color.primary
}

// MARK: - Sections (former cards)

private struct OasesSectionNestingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True inside an `oasesCard` section: a nested section draws nothing of its own.
    var oasesInsideSection: Bool {
        get { self[OasesSectionNestingKey.self] }
        set { self[OasesSectionNestingKey.self] = newValue }
    }
}

/// A former card, now a section: no fill, no border, no corner radius. A top-level section is
/// separated from what follows by a hairline; a section nested in another draws nothing, so a
/// page never shows a box in a box.
private struct OasesSectionModifier: ViewModifier {
    @Environment(\.oasesInsideSection) private var isNested

    func body(content: Content) -> some View {
        content
            .environment(\.oasesInsideSection, true)
            .overlay(alignment: .bottom) {
                if !isNested {
                    Rectangle()
                        .fill(Oases.Color.border)
                        .frame(height: 1)
                        .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    /// Compatibility shim for the former card chrome: renders as a flat section (see
    /// `OasesSectionModifier`). The parameters are ignored and kept only so existing call sites
    /// compile; pages drop this modifier as they move to `Form` / `Table` / section headers.
    func oasesCard(cornerRadius: CGFloat? = nil, fill: Color? = nil) -> some View {
        modifier(OasesSectionModifier())
    }
}
