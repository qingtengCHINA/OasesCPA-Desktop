import SwiftUI

/// Detail-pane heading: section title and one line of context, Geist-sized for macOS.
struct PageHeader: View {
    let section: AppSection

    var body: some View {
        VStack(alignment: .leading, spacing: Oases.Space.xs) {
            Text(LocalizedStringKey(section.title))
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Oases.Color.textPrimary)

            Text(LocalizedStringKey(section.subtitle))
                .font(.callout)
                .foregroundStyle(Oases.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
