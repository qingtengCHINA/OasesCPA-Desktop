import AppKit
import SwiftUI

extension Color {
    static let oasesBlue = Color(red: 0.18, green: 0.49, blue: 0.93)
    static let oasesMint = Color(red: 0.08, green: 0.66, blue: 0.55)
    static let oasesPurple = Color(red: 0.48, green: 0.38, blue: 0.92)
    static let oasesOrange = Color(red: 0.94, green: 0.57, blue: 0.13)
    static let oasesGreen = Color(red: 0.24, green: 0.70, blue: 0.29)
    static let oasesRed = Color(red: 0.92, green: 0.28, blue: 0.31)
    static let oasesInk = Color(red: 0.10, green: 0.15, blue: 0.22)
}

extension View {
    func oasesCard(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.62), lineWidth: 1)
            }
    }
}
