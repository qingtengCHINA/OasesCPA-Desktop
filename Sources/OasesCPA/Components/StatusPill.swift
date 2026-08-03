import SwiftUI

struct StatusPill: View {
    let title: String
    let tint: Color
    var systemImage: String = "circle.fill"

    var body: some View {
        Label(LocalizedStringKey(title), systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.11), in: Capsule())
    }
}
