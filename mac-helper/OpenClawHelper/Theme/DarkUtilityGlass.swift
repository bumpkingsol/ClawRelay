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

    // Popover-specific
    static let popoverCardRadius: CGFloat = 10
    static let popoverSegmentRadius: CGFloat = 8

    // State colors
    static let activeGreen = Color(red: 0.247, green: 0.725, blue: 0.314)       // #3fb950
    static let warningAmber = Color(red: 0.824, green: 0.600, blue: 0.133)       // #d29922
    static let sensitivePurple = Color(red: 0.545, green: 0.361, blue: 0.965)    // #8b5cf6
    static let errorRed = Color(red: 0.973, green: 0.318, blue: 0.286)           // #f85149
    static let accentBlue = Color(red: 0.345, green: 0.651, blue: 1.0)           // #58a6ff
    static let mutedGray = Color(red: 0.302, green: 0.341, blue: 0.376)          // #4d5761

    // Card backgrounds
    static let cardBackground = Color.white.opacity(0.04)
    static let cardBorder = Color.white.opacity(0.06)
    static let subtleBackground = Color.white.opacity(0.03)
    static let divider = Color.white.opacity(0.06)

    // Section label style
    static let sectionLabel = Font.system(size: 10).weight(.medium)
    static let sectionLabelColor = Color(red: 0.282, green: 0.310, blue: 0.345) // #484f58
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
