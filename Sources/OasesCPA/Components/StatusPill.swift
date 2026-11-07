import SwiftUI

/// Panel badge: tinted label on a faint tint with a hairline border. The default
/// `circle.fill` symbol renders as a 6 pt status dot.
struct StatusPill: View {
    let title: String
    let tint: Color
    var systemImage: String = "circle.fill"

    var body: some View {
        HStack(spacing: 5) {
            if systemImage == "circle.fill" {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(LocalizedStringKey(title))
                .lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.28), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}
