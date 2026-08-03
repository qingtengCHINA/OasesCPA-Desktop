import SwiftUI

struct PageHeader: View {
    let section: AppSection

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(LocalizedStringKey(section.title))
                .font(.largeTitle.weight(.bold))

            Text(LocalizedStringKey(section.subtitle))
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
