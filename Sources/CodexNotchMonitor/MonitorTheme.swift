import SwiftUI

enum MonitorTheme {
    static let panelCornerRadius: CGFloat = 14
    static let compactCornerRadius: CGFloat = 16
    static let cardCornerRadius: CGFloat = 12
    static let compactCardCornerRadius: CGFloat = 11
    static let controlCornerRadius: CGFloat = 8

    static let primaryText = Color.white.opacity(0.92)
    static let secondaryText = Color.white.opacity(0.68)
    static let tertiaryText = Color.white.opacity(0.50)
    static let faintText = Color.white.opacity(0.38)
    static let cardFill = Color.white.opacity(0.038)
    static let subtleCardFill = Color.white.opacity(0.024)
    static let controlFill = Color.white.opacity(0.055)
    static let separator = Color.white.opacity(0.075)
    static let hairline = Color.white.opacity(0.055)
    static let cyanAccent = Color(red: 0.38, green: 0.56, blue: 1.00)
    static let selection = Color(red: 0.23, green: 0.34, blue: 0.82)
    static let windowBackground = Color(red: 0.080, green: 0.080, blue: 0.085)
    static let sidebarBackground = Color(red: 0.070, green: 0.070, blue: 0.074)
    static let glassTint = Color(red: 0.055, green: 0.055, blue: 0.060).opacity(0.92)

    static func ambientBackground(statusColor: Color) -> some View {
        ZStack {
            windowBackground
            LinearGradient(
                colors: [.white.opacity(0.012), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum MonitorTypography {
    static let pageTitle = AstaSans.semiBold(21)
    static let pageSubtitle = AstaSans.regular(10.5)
    static let cardTitle = AstaSans.semiBold(10.5)
    static let rowTitle = AstaSans.semiBold(9.5)
    static let body = AstaSans.regular(9.5)
    static let metadata = AstaSans.regular(8.5)
    static let metadataMedium = AstaSans.medium(8.5)
    static let control = AstaSans.semiBold(9)
    static let controlLarge = AstaSans.semiBold(10.5)
    static let primaryMetric = AstaSans.semiBold(21)
    static let secondaryMetric = AstaSans.semiBold(15)
}

enum MonitorGeometry {
    static let pageGap: CGFloat = 10
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let compactRadius: CGFloat = 10
    static let compactPadding: CGFloat = 10
    static let controlRadius: CGFloat = 8
    static let settingsRowHeight: CGFloat = 52
    static let chartHeight: CGFloat = 58
    static let overviewItemGap: CGFloat = 9
    static let accountEvidenceHeight: CGFloat = 12
}
