import Foundation

@main
struct ActivityIslandPreferencesTests {
    private static var passed = 0
    private static var failed = 0

    static func main() {
        let suite = "ActivityIslandPreferencesTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { exit(2) }
        defer { defaults.removePersistentDomain(forName: suite) }

        let initial = ActivityIslandPreferences.load(from: defaults)
        expect(initial == .defaults, "missing values use product defaults")
        expect(initial.surfaceOpacity == 0.38, "surface opacity keeps the approved default")
        expect(initial.showsFloatingIsland, "default mode shows the floating island")
        expect(!initial.routesTaskStateToMenuBar, "default mode leaves task state out of the menu bar")

        defaults.set(false, forKey: ActivityIslandPreferenceKey.enabled)
        defaults.set(ActivityIslandMode.menuBar.rawValue, forKey: ActivityIslandPreferenceKey.mode)
        defaults.set(MenuBarInformationDensity.detailed.rawValue, forKey: ActivityIslandPreferenceKey.menuBarDensity)
        defaults.set(ActivityIslandScreenMode.main.rawValue, forKey: ActivityIslandPreferenceKey.screen)
        defaults.set(ActivityIslandPosition.trailing.rawValue, forKey: ActivityIslandPreferenceKey.position)
        defaults.set(ActivityIslandVisualStyle.particleOrb.rawValue, forKey: ActivityIslandPreferenceKey.visualStyle)
        defaults.set(1.2, forKey: ActivityIslandPreferenceKey.surfaceOpacity)
        defaults.set(2.0, forKey: ActivityIslandPreferenceKey.surfaceScale)
        defaults.set(1, forKey: ActivityIslandPreferenceKey.expandedHold)
        defaults.set(500, forKey: ActivityIslandPreferenceKey.compactHide)
        defaults.set(true, forKey: ActivityIslandPreferenceKey.reduceMotion)
        defaults.set(false, forKey: ActivityIslandPreferenceKey.showCompletion)
        let customized = ActivityIslandPreferences.load(from: defaults)
        expect(customized.enabled == false, "enabled persists")
        expect(customized.mode == .menuBar, "presentation mode persists")
        expect(customized.menuBarDensity == .detailed, "menu-bar density persists")
        expect(customized.screen == .main, "screen choice persists")
        expect(customized.position == .trailing, "position persists")
        expect(customized.visualStyle == .particleOrb, "visual style persists")
        expect(customized.surfaceOpacity == 0.90, "surface opacity clamps to maximum")
        expect(customized.surfaceScale == 1.25, "surface scale clamps to maximum")
        expect(customized.expandedHold == 5, "expanded hold clamps to minimum")
        expect(customized.compactHide == 120, "compact hide clamps to maximum")
        expect(customized.reduceMotion, "app reduce motion persists")
        expect(customized.showCompletion == false, "completion preference persists")
        expect(!customized.showsFloatingIsland, "menu-bar mode hides the floating island")
        expect(!customized.routesTaskStateToMenuBar, "disabled master switch suppresses menu-bar task state")

        defaults.set(true, forKey: ActivityIslandPreferenceKey.enabled)
        defaults.set(0.08, forKey: ActivityIslandPreferenceKey.surfaceOpacity)
        defaults.set(0.10, forKey: ActivityIslandPreferenceKey.surfaceScale)
        let menuBarOnly = ActivityIslandPreferences.load(from: defaults)
        expect(!menuBarOnly.showsFloatingIsland, "menu-bar mode never creates a floating island")
        expect(menuBarOnly.routesTaskStateToMenuBar, "menu-bar mode routes live task state to the status item")
        expect(menuBarOnly.surfaceOpacity == 0.10, "surface opacity clamps to minimum")
        expect(menuBarOnly.surfaceScale == 0.25, "surface scale clamps to minimum")

        var signalCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .activityIslandPreferencesDidChange,
            object: nil,
            queue: nil
        ) { _ in
            signalCount += 1
        }
        ActivityIslandPreferenceSignal.post()
        NotificationCenter.default.removeObserver(observer)
        expect(signalCount == 1, "in-process preference signal is delivered immediately")
        expect(
            ActivityIslandPlacementPolicy.notchLift(safeAreaTop: 0) == 0,
            "notchless display keeps the existing vertical position"
        )
        expect(
            ActivityIslandPlacementPolicy.notchLift(safeAreaTop: 32) == 18,
            "standard notched display uses the maximum safe lift"
        )
        expect(
            ActivityIslandPlacementPolicy.notchLift(safeAreaTop: 20) == 10,
            "smaller safe area preserves readable content clearance"
        )
        expect(
            !ActivityIslandMotionPolicy.isReduced(
                systemPreference: false,
                appPreference: false
            ),
            "motion remains enabled when both preferences are off"
        )
        expect(
            ActivityIslandMotionPolicy.isReduced(
                systemPreference: true,
                appPreference: false
            ),
            "system reduce motion disables activity-island movement"
        )
        expect(
            ActivityIslandMotionPolicy.isReduced(
                systemPreference: false,
                appPreference: true
            ),
            "app reduce motion disables activity-island movement"
        )

        if failed > 0 {
            fputs("Activity Island preference tests failed: \(failed), passed: \(passed)\n", stderr)
            exit(1)
        }
        print("Activity Island preference tests passed: \(passed)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        if condition() {
            passed += 1
        } else {
            failed += 1
            fputs("FAIL: \(name)\n", stderr)
        }
    }
}
