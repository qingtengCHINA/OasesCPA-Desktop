import SwiftUI

/// Compatibility shim for the former tinted capsule: a status dot (or the given SF Symbol) in
/// the status colour, followed by the word in the label colour. No fill, no border.
struct StatusPill: View {
    let title: String
    let tint: Color
    var systemImage: String = "circle.fill"

    var body: some View {
        HStack(spacing: Oases.Space.xs + 2) {
            if systemImage == "circle.fill" {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
            } else {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .imageScale(.small)
            }
            Text(LocalizedStringKey(title))
                .foregroundStyle(Oases.Color.textPrimary)
                .lineLimit(1)
        }
        .font(.callout)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}
