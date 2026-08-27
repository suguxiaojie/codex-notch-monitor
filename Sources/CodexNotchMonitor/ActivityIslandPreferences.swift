import Foundation

extension Notification.Name {
    static let activityIslandPreferencesDidChange = Notification.Name(
        "CodexMonitor.activityIslandPreferencesDidChange"
    )
    static let activitySettingsPreviewVisibilityDidChange = Notification.Name(
        "CodexMonitor.activitySettingsPreviewVisibilityDidChange"
    )
}

enum ActivityIslandPreferenceSignal {
    static func post() {
        NotificationCenter.default.post(
            name: .activityIslandPreferencesDidChange,
            object: nil
        )
    }
}

enum ActivityIslandPreferenceKey {
    static let enabled = "activityIsland.enabled"
    static let mode = "activityIsland.mode"
    static let menuBarDensity = "activityIsland.menuBarDensity"
    static let screen = "activityIsland.screen"
    static let position = "activityIsland.position"
    static let visualStyle = "activityIsland.visualStyle"
    static let surfaceOpacity = "activityIsland.surfaceOpacity"
    static let surfaceScale = "activityIsland.surfaceScale"
    static let expandedHold = "activityIsland.expandedHold"
    static let compactHide = "activityIsland.compactHide"
    static let reduceMotion = "activityIsland.reduceMotion"
    static let showCompletion = "activityIsland.showCompletion"
}

enum ActivityIslandMode: String, CaseIterable, Identifiable {
    case floating
    case menuBar

    var id: String { rawValue }
    var title: String {
        switch self {
        case .floating: return "浮动状态岛"
        case .menuBar: return "仅菜单栏"
        }
    }
}

enum MenuBarInformationDensity: String, CaseIterable, Identifiable {
    case automatic
    case detailed
    case compact
    case iconOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "自动"
        case .detailed: return "详细"
        case .compact: return "精简"
        case .iconOnly: return "图标"
        }
    }
}

enum ActivityIslandScreenMode: String, CaseIterable, Identifiable {
    case automatic
    case main
    case notched

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "自动"
        case .main: return "主显示器"
        case .notched: return "刘海显示器"
        }
    }
}

enum ActivityIslandPosition: String, CaseIterable, Identifiable {
    case leading
    case center
    case trailing

    var id: String { rawValue }
    var title: String {
        switch self {
        case .leading: return "左侧"
        case .center: return "居中"
        case .trailing: return "右侧"
        }
    }
}

enum ActivityIslandVisualStyle: String, CaseIterable, Identifiable {
    case rippleGlow
    case particleOrb

    var id: String { rawValue }
    var title: String {
        switch self {
        case .rippleGlow: return "Ripple Glow"
        case .particleOrb: return "Particle Orb"
        }
    }
}

enum ActivityIslandPlacementPolicy {
    static let maximumNotchLift: CGFloat = 18
    static let readableContentSafety: CGFloat = 10

    static func notchLift(safeAreaTop: CGFloat) -> CGFloat {
        guard safeAreaTop > 0 else { return 0 }
        return min(
            maximumNotchLift,
            max(0, safeAreaTop - readableContentSafety)
        )
    }
}

enum ActivityIslandMotionPolicy {
    static func isReduced(
        systemPreference: Bool,
        appPreference: Bool
    ) -> Bool {
        systemPreference || appPreference
    }
}

struct ActivityIslandPreferences: Equatable {
    var enabled: Bool
    var mode: ActivityIslandMode
    var menuBarDensity: MenuBarInformationDensity
    var screen: ActivityIslandScreenMode
    var position: ActivityIslandPosition
    var visualStyle: ActivityIslandVisualStyle
    var surfaceOpacity: Double
    var surfaceScale: Double
    var expandedHold: TimeInterval
    var compactHide: TimeInterval
    var reduceMotion: Bool
    var showCompletion: Bool

    var showsFloatingIsland: Bool {
        enabled && mode == .floating
    }

    var routesTaskStateToMenuBar: Bool {
        enabled && mode == .menuBar
    }

    static let defaults = ActivityIslandPreferences(
        enabled: true,
        mode: .floating,
        menuBarDensity: .automatic,
        screen: .automatic,
        position: .center,
        visualStyle: .rippleGlow,
        surfaceOpacity: 0.38,
        surfaceScale: 1.00,
        expandedHold: 8,
        compactHide: 120,
        reduceMotion: false,
        showCompletion: true
    )

    static func load(from defaults: UserDefaults = .standard) -> ActivityIslandPreferences {
        let registered = Self.defaults
        return ActivityIslandPreferences(
            enabled: defaults.object(forKey: ActivityIslandPreferenceKey.enabled) as? Bool
                ?? registered.enabled,
            mode: ActivityIslandMode(
                rawValue: defaults.string(forKey: ActivityIslandPreferenceKey.mode) ?? ""
            ) ?? registered.mode,
            menuBarDensity: MenuBarInformationDensity(
                rawValue: defaults.string(forKey: ActivityIslandPreferenceKey.menuBarDensity) ?? ""
            ) ?? registered.menuBarDensity,
            screen: ActivityIslandScreenMode(
                rawValue: defaults.string(forKey: ActivityIslandPreferenceKey.screen) ?? ""
            ) ?? registered.screen,
            position: ActivityIslandPosition(
                rawValue: defaults.string(forKey: ActivityIslandPreferenceKey.position) ?? ""
            ) ?? registered.position,
            visualStyle: ActivityIslandVisualStyle(
                rawValue: defaults.string(forKey: ActivityIslandPreferenceKey.visualStyle) ?? ""
            ) ?? registered.visualStyle,
            surfaceOpacity: clamped(
                defaults.object(forKey: ActivityIslandPreferenceKey.surfaceOpacity) as? Double
                    ?? registered.surfaceOpacity,
                lower: 0.10,
                upper: 0.90
            ),
            surfaceScale: clamped(
                defaults.object(forKey: ActivityIslandPreferenceKey.surfaceScale) as? Double
                    ?? registered.surfaceScale,
                lower: 0.25,
                upper: 1.25
            ),
            expandedHold: clamped(
                defaults.object(forKey: ActivityIslandPreferenceKey.expandedHold) as? Double
                    ?? registered.expandedHold,
                lower: 5,
                upper: 60
            ),
            compactHide: clamped(
                defaults.object(forKey: ActivityIslandPreferenceKey.compactHide) as? Double
                    ?? registered.compactHide,
                lower: 5,
                upper: 120
            ),
            reduceMotion: defaults.object(forKey: ActivityIslandPreferenceKey.reduceMotion) as? Bool
                ?? registered.reduceMotion,
            showCompletion: defaults.object(forKey: ActivityIslandPreferenceKey.showCompletion) as? Bool
                ?? registered.showCompletion
        )
    }

    private static func clamped(_ value: Double, lower: Double, upper: Double) -> Double {
        max(lower, min(upper, value))
    }
}
