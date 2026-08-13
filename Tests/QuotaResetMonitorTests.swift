import Foundation

@main
struct QuotaResetMonitorTests {
    static func main() throws {
        try firstSnapshotDoesNotNotify()
        try detectsNaturalReset()
        try detectsOfficialReset()
        try delaysUnverifiedJump()
        try mergesMultipleWindows()
        try detectsManualCompletionEvidence()
        print("Quota reset tests: 6/6 passed")
    }

    static func firstSnapshotDoesNotNotify() throws {
        let monitor = makeMonitor("first")
        let result = monitor.evaluate(buckets: [bucket(remaining: 100)], feed: nil, now: Date())
        expect(result.events.isEmpty, "首次启动不能把满额误报为重置")
    }

    static func detectsNaturalReset() throws {
        let monitor = makeMonitor("natural")
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        _ = monitor.evaluate(
            buckets: [bucket(remaining: 31, resetsAt: start.addingTimeInterval(60))],
            feed: nil,
            now: start
        )
        let result = monitor.evaluate(
            buckets: [bucket(remaining: 100, resetsAt: start.addingTimeInterval(5 * 60 * 60))],
            feed: nil,
            now: start.addingTimeInterval(90)
        )
        expect(result.events.count == 1, "自然重置应生成一个事件")
        expect(result.events.first?.reason == .natural, "自然重置原因错误")
    }

    static func detectsOfficialReset() throws {
        let monitor = makeMonitor("official")
        let start = Date(timeIntervalSince1970: 2_000_100_000)
        _ = monitor.evaluate(buckets: [bucket(remaining: 42)], feed: nil, now: start)
        let result = monitor.evaluate(
            buckets: [bucket(remaining: 100)],
            feed: feed(kind: .resetCompleted, announcedAt: start.addingTimeInterval(60)),
            now: start.addingTimeInterval(90)
        )
        expect(result.events.first?.reason == .officialCompleted, "官方重置应由动态佐证")
        expect(result.events.first?.sourcePostID == "post-1", "官方来源应被保留")
    }

    static func delaysUnverifiedJump() throws {
        let monitor = makeMonitor("pending")
        let start = Date(timeIntervalSince1970: 2_000_200_000)
        _ = monitor.evaluate(buckets: [bucket(remaining: 60)], feed: nil, now: start)
        let result = monitor.evaluate(
            buckets: [bucket(remaining: 100)],
            feed: nil,
            now: start.addingTimeInterval(60)
        )
        expect(result.events.isEmpty, "无证据跳变不应立刻通知")
        expect(result.needsFeedRefresh, "无证据跳变应请求刷新动态")
        let events = monitor.reconcile(
            feed: feed(kind: .resetScheduled, announcedAt: start, effectiveAt: start.addingTimeInterval(60)),
            now: start.addingTimeInterval(120)
        )
        expect(events.first?.reason == .officialScheduled, "延迟动态应补全官方重置事件")
    }

    static func mergesMultipleWindows() throws {
        let monitor = makeMonitor("multi")
        let start = Date(timeIntervalSince1970: 2_000_300_000)
        let old = RateLimitBucket(
            id: "codex", name: "Codex", planType: "pro",
            primary: window(remaining: 20, minutes: 300),
            secondary: window(remaining: 70, minutes: 10_080),
            creditBalance: nil, hasCredits: false
        )
        let full = RateLimitBucket(
            id: "codex", name: "Codex", planType: "pro",
            primary: window(remaining: 100, minutes: 300),
            secondary: window(remaining: 100, minutes: 10_080),
            creditBalance: nil, hasCredits: false
        )
        _ = monitor.evaluate(buckets: [old], feed: nil, now: start)
        let result = monitor.evaluate(
            buckets: [full],
            feed: feed(kind: .resetCompleted, announcedAt: start.addingTimeInterval(30)),
            now: start.addingTimeInterval(60)
        )
        expect(result.events.count == 1, "同批重置应合并成一个通知")
        expect(result.events.first?.changes.count == 2, "通知应包含两个额度窗口")
    }

    static func detectsManualCompletionEvidence() throws {
        let monitor = makeMonitor("manual")
        let start = Date(timeIntervalSince1970: 2_000_400_000)
        _ = monitor.evaluate(buckets: [bucket(remaining: 40)], feed: nil, now: start)
        let schedule = event(kind: .resetScheduled, announcedAt: start, effectiveAt: start.addingTimeInterval(30))
        let timeline = TiboResetTimeline(manualCompletions: [TiboManualCompletion(
            id: "manual:test",
            completedAt: iso(start.addingTimeInterval(60)),
            visibleUntil: iso(start.addingTimeInterval(10 * 24 * 60 * 60)),
            representativePostId: schedule.source.postId,
            schedulePostIds: [schedule.source.postId],
            schedules: [schedule],
            fulfillmentOrigin: "manual"
        )])
        let result = monitor.evaluate(
            buckets: [bucket(remaining: 100)],
            feed: TiboFeed(
                schemaVersion: 1,
                generatedAt: iso(start.addingTimeInterval(90)),
                lastSuccessfulCheckAt: iso(start.addingTimeInterval(90)),
                monitor: TiboFeedMonitor(status: "ok", errorCode: nil),
                events: [],
                resetTimeline: timeline
            ),
            now: start.addingTimeInterval(90)
        )
        expect(result.events.first?.reason == .officialCompleted, "人工确认重置应成为通知证据")
    }

    static func makeMonitor(_ name: String) -> QuotaResetMonitor {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-reset-test-\(name)-\(UUID().uuidString).json")
        return QuotaResetMonitor(stateURL: url)
    }

    static func bucket(remaining: Int, resetsAt: Date? = nil) -> RateLimitBucket {
        RateLimitBucket(
            id: "codex", name: "Codex", planType: "pro",
            primary: RateLimitWindow(
                usedPercent: 100 - remaining,
                windowDurationMinutes: 300,
                resetsAt: resetsAt
            ),
            secondary: nil, creditBalance: nil, hasCredits: false
        )
    }

    static func window(remaining: Int, minutes: Int) -> RateLimitWindow {
        RateLimitWindow(usedPercent: 100 - remaining, windowDurationMinutes: minutes, resetsAt: nil)
    }

    static func feed(kind: TiboEventKind, announcedAt: Date, effectiveAt: Date? = nil) -> TiboFeed {
        return TiboFeed(
            schemaVersion: 1,
            generatedAt: iso(announcedAt),
            lastSuccessfulCheckAt: iso(announcedAt),
            monitor: TiboFeedMonitor(status: "ok", errorCode: nil),
            events: [event(kind: kind, announcedAt: announcedAt, effectiveAt: effectiveAt)]
        )
    }

    static func event(kind: TiboEventKind, announcedAt: Date, effectiveAt: Date? = nil) -> TiboEvent {
        TiboEvent(
            kind: kind,
            announcedAt: iso(announcedAt),
            effectiveAt: effectiveAt.map(iso),
            scope: TiboEventScope(plans: ["pro"], windows: ["5h"]),
            source: TiboEventSource(handle: "thsottiaux", postId: "post-1", url: "https://x.com/thsottiaux/status/post-1"),
            confidence: 1,
            rationale: "test",
            text: "test"
        )
    }

    static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("Quota reset test failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
