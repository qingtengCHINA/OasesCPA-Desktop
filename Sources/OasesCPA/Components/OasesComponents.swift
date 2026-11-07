import AppKit
import SwiftUI

// Panel primitives for macOS: ink primary button, status dot and badge, section header,
// grouped rows, label/value rows, monospaced copyable values and empty states.

/// Ink primary action (black in light, white in dark). One per view; honours `controlSize`.
struct OasesPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let height: CGFloat = switch controlSize {
        case .mini: 20
        case .small: 24
        case .large, .extraLarge: 34
        default: 28
        }
        configuration.label
            .font(controlSize == .small || controlSize == .mini ? .caption.weight(.medium) : .callout.weight(.medium))
            .foregroundStyle(Oases.Color.inkContrast)
            .padding(.horizontal, controlSize == .large || controlSize == .extraLarge ? 16 : 11)
            .frame(minHeight: height)
            .background(
                configuration.isPressed ? Oases.Color.inkPressed : Oases.Color.ink,
                in: RoundedRectangle(cornerRadius: Oases.Radius.button, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .animation(Oases.Motion.press(reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == OasesPrimaryButtonStyle {
    static var oasesPrimary: OasesPrimaryButtonStyle { OasesPrimaryButtonStyle() }
}

struct StatusDot: View {
    var tone: Oases.Tone
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(tone.fill)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct ToneBadge: View {
    var text: String
    var tone: Oases.Tone

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.caption.weight(.medium))
            .foregroundStyle(tone.text)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tone.background, in: RoundedRectangle(cornerRadius: Oases.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Oases.Radius.small, style: .continuous)
                    .strokeBorder(tone.border, lineWidth: 1)
            )
    }
}

/// Title above a card, optionally a "›" link to the full view.
struct OasesSectionHeader: View {
    var title: String
    var trailing: String?
    var onOpen: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Oases.Space.sm) {
            if let onOpen {
                Button(action: onOpen) {
                    HStack(spacing: Oases.Space.xs) {
                        Text(LocalizedStringKey(title))
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(OasesLocalization.localizedFormat("打开%@", OasesLocalization.localized(title)))
            } else {
                Text(LocalizedStringKey(title))
            }
            Spacer(minLength: Oases.Space.sm)
            if let trailing {
                Text(LocalizedStringKey(trailing))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Oases.Color.textTertiary)
            }
        }
        .font(.headline)
        .foregroundStyle(Oases.Color.textPrimary)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Rows inside one bordered card with 1 pt dividers.
struct OasesRowGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    private var divider: some View {
        Rectangle()
            .fill(Oases.Color.border)
            .frame(height: 1)
            .padding(.leading, Oases.Space.md)
    }

    var body: some View {
        Group {
            if #available(macOS 15.0, *) {
                VStack(spacing: 0) {
                    Group(subviews: content()) { subviews in
                        ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                            if index > 0 { divider }
                            subview
                        }
                    }
                }
            } else {
                // macOS 14: rows separate themselves with spacing instead of hairlines.
                VStack(spacing: 0) { content() }
            }
        }
        .oasesCard()
    }
}

/// Clickable row: icon, title, subtitle, trailing content, chevron; wash on hover.
struct OasesLinkRow<Trailing: View>: View {
    var systemImage: String?
    var title: String
    var subtitle: String?
    var monoTitle = false
    var statusDot: Oases.Tone?
    var action: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    @State private var isHovered = false

    var body: some View {
        if let action {
            Button(action: action) { row(showChevron: true) }
                .buttonStyle(.plain)
                .background(isHovered ? Oases.Color.wash : Color.clear)
                .onHover { isHovered = $0 }
        } else {
            row(showChevron: false)
        }
    }

    private func row(showChevron: Bool) -> some View {
        HStack(spacing: Oases.Space.m) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(Oases.Color.textSecondary)
                    .frame(width: 18)
                    .overlay(alignment: .topTrailing) {
                        if let statusDot { StatusDot(tone: statusDot, size: 6).offset(x: 3, y: -2) }
                    }
                    .accessibilityHidden(true)
            } else if let statusDot {
                StatusDot(tone: statusDot)
            }
            VStack(alignment: .leading, spacing: Oases.Space.xxs) {
                Text(LocalizedStringKey(title))
                    .font(monoTitle ? .system(.body, design: .monospaced).weight(.medium) : .body.weight(.medium))
                    .foregroundStyle(Oases.Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle, !subtitle.isEmpty {
                    Text(LocalizedStringKey(subtitle))
                        .font(.caption)
                        .foregroundStyle(Oases.Color.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Oases.Space.sm)
            trailing()
                .font(.callout.monospacedDigit())
                .foregroundStyle(Oases.Color.textSecondary)
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Oases.Color.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, Oases.Space.sm + 2)
        .padding(.horizontal, Oases.Space.md)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension OasesLinkRow where Trailing == EmptyView {
    init(systemImage: String? = nil, title: String, subtitle: String? = nil, monoTitle: Bool = false,
         statusDot: Oases.Tone? = nil, action: (() -> Void)? = nil) {
        self.init(systemImage: systemImage, title: title, subtitle: subtitle, monoTitle: monoTitle,
                  statusDot: statusDot, action: action, trailing: { EmptyView() })
    }
}

/// Label/value row for detail panes.
struct OasesValueRow: View {
    var label: String
    var value: String
    var mono = false
    var tone: Oases.Tone?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Oases.Space.m) {
            Text(LocalizedStringKey(label))
                .foregroundStyle(Oases.Color.textSecondary)
            Spacer(minLength: Oases.Space.sm)
            Text(value)
                .font(mono ? .system(.callout, design: .monospaced) : .callout.monospacedDigit())
                .foregroundStyle(tone?.text ?? Oases.Color.textPrimary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.callout)
        .padding(.vertical, Oases.Space.sm + 1)
        .padding(.horizontal, Oases.Space.md)
        .accessibilityElement(children: .combine)
    }
}

/// Key / URL / model ID in SF Mono with a copy button.
struct OasesMonoValue: View {
    var text: String
    var copyValue: String?
    var isSecret = false

    @State private var copied = false

    var body: some View {
        HStack(spacing: Oases.Space.sm) {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Oases.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .privacySensitive(isSecret)
            if let copyValue {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyValue, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? Oases.Color.successText : Oases.Color.textSecondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help("复制")
            }
        }
        .padding(.horizontal, Oases.Space.sm)
        .padding(.vertical, Oases.Space.xs)
        .background(Oases.Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: Oases.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Oases.Radius.small, style: .continuous)
                .strokeBorder(Oases.Color.border, lineWidth: 1)
        )
    }
}

/// Empty or not-yet-connected state inside a card.
struct OasesEmptyState: View {
    var systemImage: String
    var title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Oases.Space.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Oases.Color.textTertiary)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(title))
                .font(.headline)
                .foregroundStyle(Oases.Color.textPrimary)
            if let message {
                Text(LocalizedStringKey(message))
                    .font(.callout)
                    .foregroundStyle(Oases.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            if let actionTitle, let action {
                Button(LocalizedStringKey(actionTitle), action: action)
                    .buttonStyle(.oasesPrimary)
                    .padding(.top, Oases.Space.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Oases.Space.xl)
        .padding(.horizontal, Oases.Space.md)
        .oasesCard()
    }
}

extension View {
    /// Neutral square behind a row icon: subtle fill and hairline border, no brand tint.
    func oasesIconTile(cornerRadius: CGFloat = Oases.Radius.control) -> some View {
        self
            .background(Oases.Color.surfaceSubtle, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Oases.Color.border, lineWidth: 1)
            )
    }
}
