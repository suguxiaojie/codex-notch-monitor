import Foundation

@main
struct ActivityIslandLifecycleTests {
    private static var passed = 0
    private static var failed = 0

    static func main() {
        testLiveActivityLifecycle()
        testAttentionDoesNotCollapse()
        testCompletionLifecycle()
        testNewActivityReopensCompactIsland()

        if failed > 0 {
            fputs("Activity Island tests failed: \(failed), passed: \(passed)\n", stderr)
            exit(1)
        }
        print("Activity Island tests passed: \(passed)")
    }

    private static func testLiveActivityLifecycle() {
        var lifecycle = ActivityIslandLifecycle()
        expect(lifecycle.handle(.activityChanged(requiresAttention: false)) == .expanded, "live activity expands")
        expect(lifecycle.handle(.expandedHoldElapsed) == .compact, "stable activity compacts")
        expect(lifecycle.handle(.compactHideElapsed) == .hidden, "stale compact activity hides")
    }

    private static func testAttentionDoesNotCollapse() {
        var lifecycle = ActivityIslandLifecycle()
        _ = lifecycle.handle(.activityChanged(requiresAttention: true))
        expect(lifecycle.handle(.expandedHoldElapsed) == .expanded, "approval remains expanded")
        expect(lifecycle.handle(.compactHideElapsed) == .expanded, "approval cannot be hidden by stale timer")
    }

    private static func testCompletionLifecycle() {
        var lifecycle = ActivityIslandLifecycle()
        _ = lifecycle.handle(.activityChanged(requiresAttention: false))
        expect(lifecycle.handle(.activityEnded) == .expanded, "completion feedback expands")
        expect(lifecycle.handle(.expandedHoldElapsed) == .compact, "completion feedback compacts")
        expect(lifecycle.handle(.compactHideElapsed) == .hidden, "completion feedback hides")
    }

    private static func testNewActivityReopensCompactIsland() {
        var lifecycle = ActivityIslandLifecycle()
        _ = lifecycle.handle(.activityChanged(requiresAttention: false))
        _ = lifecycle.handle(.expandedHoldElapsed)
        expect(lifecycle.handle(.activityChanged(requiresAttention: false)) == .expanded, "new action reopens compact island")
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
