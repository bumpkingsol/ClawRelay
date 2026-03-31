import SwiftUI

enum DarkUtilityGlass {
    // Corner radii
    static let panelCornerRadius: CGFloat = 24
    static let cardCornerRadius: CGFloat = 18

    // Colors and gradients
    static let shadow = Color.black.opacity(0.24)
    static let background = LinearGradient(
        colors: [Color(red: 0.10, green: 0.13, blue: 0.18), Color(red: 0.16, green: 0.20, blue: 0.27)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Typography
    static let monoCaption = Font.system(.caption, design: .monospaced)
    static let compactBody = Font.system(.callout)
}

// Reusable card modifier
struct GlassCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DarkUtilityGlass.cardCornerRadius))
            .shadow(color: DarkUtilityGlass.shadow, radius: 8, y: 4)
    }
}

extension View {
    func glassCard() -> some View {
        modifier(GlassCard())
    }
}
