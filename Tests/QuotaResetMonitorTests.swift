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
        try detectsManualResetCredit()
        try confirmsPendingAsUserReset()
        try confirmsExpiredUnverifiedReset()
        try changesDisplayTypeWithoutOverwritingEvidence()
        try presentsExpiredUnverifiedRecoveryOnlyOnce()
        excludesDuplicateUnverifiedHistory()
        preservesConfirmedHistoryWithMatchingTimestamp()
        preservesHistoryWithoutCandidates()
        preservesHistoryWithDifferentChangesOrTimestamp()
        print("Quota reset tests: 15/15 passed")
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

    static func confirmsPendingAsUserReset() throws {
        let monitor = makeMonitor("user-confirmed-pending")
        let start = Date(timeIntervalSince1970: 2_000_500_000)
        _ = monitor.evaluate(buckets: [bucket(remaining: 0)], feed: nil, now: start)
        _ = monitor.evaluate(
            buckets: [bucket(remaining: 100)],
            feed: nil,
            now: start.addingTimeInterval(60)
        )
        guard let candidate = monitor.confirmableRecoveries.first else {
            expect(false, "待验证恢复应提供用户确认候选")
            return
        }
        let event = monitor.confirmUserReset(candidateID: candidate.id)
        expect(event?.reason == .userConfirmed, "用户确认应生成独立原因")
        expect(event?.detectedAt == start.addingTimeInterval(60), "用户确认应保留原检测时间")
        expect(event?.reason.title == "手动重置", "手动重置通知标题")
        expect(event?.reason.isNotifiable == true, "用户确认事件应允许通知")
        expect(monitor.confirmableRecoveries.isEmpty, "确认后应移除 pending")
        expect(monitor.history.filter { $0.reason == .userConfirmed }.count == 1, "确认历史只保留一条")
        expect(monitor.confirmUserReset(candidateID: candidate.id) == nil, "重复确认不得重复生成事件")
    }

    static func detectsManualResetCredit() throws {
        let monitor = makeMonitor("manual-credit")
        let start = Date(timeIntervalSince1970: 2_000_450_000)
        _ = monitor.evaluate(buckets: [bucket(remaining: 12)], feed: nil, now: start)
        monitor.markManualResetRequested(at: start.addingTimeInterval(30))
        let result = monitor.evaluate(
            buckets: [bucket(remaining: 100)],
            feed: nil,
            now: start.addingTimeInterval(60)
        )
        expect(result.events.first?.reason == .manualCredit, "重置卡兑换后应记录为手动重置")
        expect(result.events.first?.reason.title == "手动重置", "手动重置标题")
    }

    static func confirmsExpiredUnverifiedReset() throws {
        let monitor = makeMonitor("user-confirmed-expired")
        let start = Date(timeIntervalSince1970: 2_000_600_000)
        _ = monitor.evaluate(buckets: [bucket(remaining: 0)], feed: nil, now: start)
        _ = monitor.evaluate(
            buckets: [bucket(remaining: 100)],
            feed: nil,
            now: start.addingTimeInterval(60)
        )
        _ = monitor.evaluate(
            buckets: [bucket(remaining: 100)],
            feed: nil,
            now: start.addingTimeInterval(3 * 60 * 60 + 120)
        )
        expect(monitor.history.contains { $0.reason == .unverified }, "过期 pending 应先保留为未验证历史")
        guard let candidate = monitor.confirmableRecoveries.first else {
            expect(false, "未验证历史仍应允许用户确认")
            return
        }
        let event = monitor.confirmUserReset(candidateID: candidate.id)
        expect(event?.reason == .userConfirmed, "未验证历史应可转换为用户确认")
        expect(!monitor.history.contains { $0.reason == .unverified }, "转换后应移除对应未验证历史")
        expect(monitor.history.filter { $0.reason == .userConfirmed }.count == 1, "转换后不得产生重复历史")
    }

    static func changesDisplayTypeWithoutOverwritingEvidence() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quota-reset-test-display-type-\(UUID().uuidString).json")
        let monitor = QuotaResetMonitor(stateURL: url)
        let start = Date(timeIntervalSince1970: 2_000_700_000)
        _ = monitor.evaluate(buckets: [bucket(remaining: 20)], feed: nil, now: start)
        let result = monitor.evaluate(
            buckets: [bucket(remaining: 100)],
            feed: feed(kind: .resetCompleted, announcedAt: start.addingTimeInterval(30)),
            now: start.addingTimeInterval(60)
        )
        guard let original = result.events.first else {
            expect(false, "应先生成可修改显示类型的历史")
            return
        }

        let updated = monitor.setDisplayType(eventID: original.id, displayType: .manual)
        expect(updated?.reason == .officialCompleted, "用户修正不能覆盖原始检测原因")
        expect(updated?.displayReason == .userConfirmed, "显示类型应切换为手动重置")
        expect(updated?.userDisplayType == .manual, "用户修正类型应单独保存")

        let reloaded = QuotaResetMonitor(stateURL: url)
        expect(reloaded.history.first?.reason == .officialCompleted, "重载后应保留原始检测原因")
        expect(reloaded.history.first?.displayReason == .userConfirmed, "重载后应保留用户显示类型")

        let restored = reloaded.setDisplayType(eventID: original.id, displayType: nil)
        expect(restored?.displayReason == .officialCompleted, "自动判断应恢复原始显示类型")
        let redundant = reloaded.setDisplayType(eventID: original.id, displayType: .tibo)
        expect(redundant?.userDisplayType == nil, "与原始判断相同的类型不应保留冗余修正")
        let backupDirectory = url.deletingLastPathComponent()
            .appendingPathComponent("quota-reset-backups", isDirectory: true)
        let backups = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil
        )
        expect(backups.count >= 2, "每次类型修改前都应保留可恢复备份")
    }

    static func presentsExpiredUnverifiedRecoveryOnlyOnce() throws {
        let monitor = makeMonitor("history-presentation")
        let start = Date(timeIntervalSince1970: 2_000_800_000)
        _ = monitor.evaluate(buckets: [bucket(remaining: 20)], feed: nil, now: start)
        _ = monitor.evaluate(
            buckets: [bucket(remaining: 100)],
            feed: nil,
            now: start.addingTimeInterval(60)
        )
        _ = monitor.evaluate(
            buckets: [bucket(remaining: 100)],
            feed: nil,
            now: start.addingTimeInterval(3 * 60 * 60 + 120)
        )

        expect(monitor.history.count == 1, "过期恢复应保留一条原始历史")
        expect(monitor.confirmableRecoveries.count == 1, "过期恢复应保留一个确认入口")
        let displayedCount = QuotaResetHistoryPresentation.uniqueCount(
            events: monitor.history,
            candidates: monitor.confirmableRecoveries
        )
        expect(displayedCount == 1, "同一次恢复不能同时按候选和历史计算两条")
        expect(monitor.history.count == 1, "展示去重不得修改原始历史")
        expect(monitor.confirmableRecoveries.count == 1, "展示去重不得移除确认入口")
    }

    static func excludesDuplicateUnverifiedHistory() {
        let event = presentationEvent(reason: .unverified)
        let candidate = presentationCandidate(for: event)
        let candidates = [candidate, candidate]
        let history = QuotaResetHistoryPresentation.historyExcludingCandidates(
            events: [event], candidates: candidates
        )
        expect(history.isEmpty, "同时间且同 changes 的未确认历史应只通过候选呈现")
        expect(
            QuotaResetHistoryPresentation.uniqueCount(events: [event], candidates: candidates) == 1,
            "重复候选 ID 只能计数一次"
        )
    }

    static func preservesConfirmedHistoryWithMatchingTimestamp() {
        let candidate = presentationCandidate(for: presentationEvent(reason: .unverified))
        let events = [
            QuotaResetReason.officialCompleted, .officialScheduled, .natural,
            .mixed, .manualCredit, .userConfirmed
        ].map { presentationEvent(reason: $0) }
        let history = QuotaResetHistoryPresentation.historyExcludingCandidates(
            events: events, candidates: [candidate]
        )
        expect(history == events, "已确认历史即使时间和 changes 相同也不能被候选遮蔽")
        expect(
            QuotaResetHistoryPresentation.uniqueCount(events: events, candidates: [candidate]) == 7,
            "已确认历史与待确认候选应分别计数"
        )
    }

    static func preservesHistoryWithoutCandidates() {
        let events = [presentationEvent(reason: .unverified), presentationEvent(reason: .natural)]
        let history = QuotaResetHistoryPresentation.historyExcludingCandidates(
            events: events, candidates: []
        )
        expect(history == events, "无候选时应保留全部历史和原有顺序")
        expect(
            QuotaResetHistoryPresentation.uniqueCount(events: events, candidates: []) == 2,
            "无候选时应使用历史数量"
        )
        expect(
            QuotaResetHistoryPresentation.uniqueCount(events: [], candidates: []) == 0,
            "空记录应显示零条"
        )
    }

    static func preservesHistoryWithDifferentChangesOrTimestamp() {
        let original = presentationEvent(reason: .unverified)
        let candidate = presentationCandidate(for: original)
        let differentChanges = presentationEvent(reason: .unverified, previousRemaining: 35)
        let differentTime = presentationEvent(
            reason: .unverified,
            detectedAt: original.detectedAt.addingTimeInterval(1)
        )
        let events = [differentChanges, original, differentTime]
        let history = QuotaResetHistoryPresentation.historyExcludingCandidates(
            events: events, candidates: [candidate]
        )
        expect(history == [differentChanges, differentTime], "去重必须同时匹配检测时间和完整 changes")
        expect(
            QuotaResetHistoryPresentation.uniqueCount(events: events, candidates: [candidate]) == 3,
            "不同恢复记录不能因时间或变化之一相同而少计"
        )
    }

    static func presentationEvent(
        reason: QuotaResetReason,
        previousRemaining: Int = 20,
        detectedAt: Date = Date(timeIntervalSince1970: 2_000_900_000)
    ) -> QuotaResetEvent {
        QuotaResetEvent(
            id: "\(reason.rawValue)-\(previousRemaining)-\(detectedAt.timeIntervalSince1970)",
            detectedAt: detectedAt,
            reason: reason,
            changes: [QuotaResetChange(
                bucketID: "codex",
                bucketName: "Codex",
                windowDurationMinutes: 300,
                previousRemainingPercent: previousRemaining,
                currentRemainingPercent: 100
            )],
            sourcePostID: nil,
            sourceURL: nil
        )
    }

    static func presentationCandidate(for event: QuotaResetEvent) -> QuotaResetConfirmationCandidate {
        QuotaResetConfirmationCandidate(
            id: "candidate-\(event.id)",
            detectedAt: event.detectedAt,
            changes: event.changes
        )
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
