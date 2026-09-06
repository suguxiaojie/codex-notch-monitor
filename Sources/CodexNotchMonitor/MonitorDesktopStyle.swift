import SwiftUI

/// Desktop windows have room for readable type; the menu bar and island keep
/// their existing compact typography and geometry.
enum MonitorDesktopTypography {
    static let pageTitle = Font.system(size: 22, weight: .semibold)
    static let pageSubtitle = Font.system(size: 12)
    static let cardTitle = Font.system(size: 15, weight: .semibold)
    static let rowTitle = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 13)
    static let metadata = Font.system(size: 11)
    static let metadataMedium = Font.system(size: 11, weight: .medium)
    static let control = Font.system(size: 12, weight: .medium)
    static let controlLarge = Font.system(size: 13, weight: .medium)
    static let primaryMetric = Font.system(size: 28, weight: .semibold)
    static let secondaryMetric = Font.system(size: 20, weight: .semibold)
}

enum MonitorDesktopTheme {
    static let controlCornerRadius: CGFloat = 8

    static let primaryText = Color.white.opacity(0.95)
    static let secondaryText = Color.white.opacity(0.78)
    static let tertiaryText = Color.white.opacity(0.66)
    static let faintText = Color.white.opacity(0.60)
    static let cardFill = Color.white.opacity(0.055)
    static let subtleCardFill = Color.white.opacity(0.035)
    static let controlFill = Color.white.opacity(0.085)
    static let separator = Color.white.opacity(0.13)
    static let hairline = Color.white.opacity(0.10)
    static let cyanAccent = Color(red: 0.48, green: 0.66, blue: 1.00)
    static let selection = Color.accentColor
    static let windowBackground = Color(red: 0.105, green: 0.105, blue: 0.115)
    static let sidebarBackground = Color(red: 0.080, green: 0.080, blue: 0.090)
}

struct MonitorDesktopReveal: ViewModifier {
    var delay: Double = 0
    var reduceMotion: Bool = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var isVisible = false

    func body(content: Content) -> some View {
        let reduced = systemReduceMotion || reduceMotion
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: reduced || isVisible ? 0 : 10)
            .onAppear {
                withAnimation(reduced
                              ? .easeOut(duration: 0.16)
                              : .spring(response: 0.38, dampingFraction: 1).delay(delay)) {
                    isVisible = true
                }
            }
            .onDisappear { isVisible = false }
    }
}
