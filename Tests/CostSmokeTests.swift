import Foundation

@main
enum CostSmokeTests {
    static func main() {
        verifyArchivedSessionsAreIncludedOnce()
        verifyMovedThreadUsesCurrentProject()
        verifyTokenActivityGridGeometry()
        verifyProjectCatalogAliases()
        verifyCurrentAccountSelection()
        verifyRollingWindowsAndAccountScopes()
        verifyAccountTimelineSplitsExistingSession()
        let service = CostService()
        let fetchStartedAt = Date()
        var immediateSnapshotSeconds: TimeInterval = 0
        var receivedImmediateSnapshot = false
        service.fetch { snapshot in
            if snapshot.usage.activity.isEmpty {
                check(!snapshot.usage.activityIsReady, "immediate snapshot marks activity as loading")
                check(snapshot.costActivity.isEmpty, "immediate snapshot defers 180-day cost activity")
                check(snapshot.today.series.count == 24, "immediate snapshot keeps quota summaries responsive")
                receivedImmediateSnapshot = true
                immediateSnapshotSeconds = Date().timeIntervalSince(fetchStartedAt)
                return
            }
            check(receivedImmediateSnapshot, "180-day activity follows the immediate summary snapshot")
            check(snapshot.usage.activityIsReady, "extended snapshot marks activity ready")
            check(snapshot.today.series.count == 24, "24-hour trend")
            check(snapshot.week.series.count == 7, "7-day cost trend")
            check(snapshot.month.series.count == 30, "rolling 30-day cost trend")
            check(snapshot.month.tokens >= snapshot.today.tokens, "month contains today")
            check(snapshot.week.tokens >= snapshot.today.tokens, "week cost contains today")
            check(snapshot.month.dollars >= snapshot.today.dollars, "month cost contains today")
            check(snapshot.week.dollars >= snapshot.today.dollars, "week dollars contain today")
            check(
                abs(snapshot.week.series.reduce(0, +) - snapshot.week.dollars) < 0.000_001,
                "weekly cost buckets sum to total cost"
            )
            check(snapshot.month.tokens > 0, "local Codex token events")
            check(snapshot.month.dollars > 0 || !snapshot.unknownModels.isEmpty, "priced or reported unknown models")
            check(
                snapshot.estimatedModelAliases["codex-auto-review"] == nil ||
                !snapshot.unknownModels.contains("codex-auto-review"),
                "estimated auto review is not also reported unknown"
            )
            check(snapshot.usage.day.series.count == 24, "daily usage has 24 hourly buckets")
            check(snapshot.usage.week.series.count == 7, "weekly usage has 7 daily buckets")
            check(snapshot.usage.month.series.count == 30, "rolling 30-day usage has daily buckets")
            check(snapshot.usage.activity.count == 180, "token activity has 180 daily buckets")
            check(snapshot.costActivity.count == 180, "cost activity has 180 daily buckets")
            check(snapshot.usage.month.tokens >= snapshot.usage.week.tokens, "month usage contains current week")
            check(snapshot.usage.week.tokens >= snapshot.usage.day.tokens, "week usage contains today")
            check(snapshot.usage.month.sessionCount > 0, "usage session aggregation")
            check(snapshot.usage.month.projectCount > 0, "usage project aggregation")
            check(!snapshot.usage.month.projects.isEmpty, "usage project ranking")
            let catalog = CodexProjectCatalog.loadState()
            for project in snapshot.usage.month.projects {
                if let alias = CodexProjectCatalog.displayName(
                    for: project.path,
                    namesByPath: catalog.namesByPath
                ) {
                    check(project.name == alias, "runtime project ranking uses current sidebar alias")
                }
            }
            print(String(format:
                "Cost and usage smoke tests passed: immediate %.2fs, activity %.2fs, today $%.2f / %lld tokens, rolling 30 days $%.2f / %lld tokens. Aliases: %@",
                immediateSnapshotSeconds,
                Date().timeIntervalSince(fetchStartedAt),
                snapshot.today.dollars, snapshot.today.tokens,
                snapshot.month.dollars, snapshot.month.tokens,
                snapshot.estimatedModelAliases.description
            ))
            exit(0)
        }
        RunLoop.main.run()
    }

    private static func verifyTokenActivityGridGeometry() {
        check(
            UsageTrendPeriod.allCases.map(\.rawValue) == ["周", "月", "三月"],
            "Usage trend exposes week, month, and quarter filters"
        )
        check(UsageTrendPeriod.week.dayCount == 7, "weekly Usage trend uses seven daily points")
        check(UsageTrendPeriod.month.dayCount == 30, "monthly Usage trend uses thirty daily points")
        check(UsageTrendPeriod.quarter.dayCount == 90, "quarterly Usage trend uses ninety daily points")
        check(UsageSnapshot.empty.quarter.series.count == 90, "empty quarterly Usage trend keeps ninety buckets")
        check(
            ActivityPeriod.allCases.map(\.dayCount) == [30, 90, 180],
            "standalone Usage and Cost activity expose 30-day, 90-day, and half-year ranges"
        )
        check(UsagePeriod.day.activityDayCount == 1, "daily activity follows the daily summary period")
        check(UsagePeriod.week.activityDayCount == 7, "weekly activity follows the weekly summary period")
        check(UsagePeriod.month.activityDayCount == 30, "monthly activity follows the monthly summary period")
        check(UsagePeriod.day.emptyActivityTitle == "今日暂无活动", "daily empty-state copy")
        check(UsagePeriod.week.emptyActivityTitle == "近 7 日暂无活动", "weekly empty-state copy")
        check(TokenActivityLayout.placeholderCount(for: 30) == 2, "30-day heatmap left padding")
        check(TokenActivityLayout.rowCount(for: 30) == 2, "30-day heatmap rows")
        check(TokenActivityLayout.placeholderCount(for: 90) == 6, "90-day heatmap left padding")
        check(TokenActivityLayout.rowCount(for: 90) == 6, "90-day heatmap rows")
        check(TokenActivityLayout.placeholderCount(for: 180) == 12, "180-day heatmap left padding")
        check(TokenActivityLayout.rowCount(for: 180) == 12, "180-day heatmap rows")
        check(CostActivityScale.level(dollars: 0, maximum: 10) == 0, "zero-cost activity uses the empty level")
        check(CostActivityScale.level(dollars: 1, maximum: 10) == 1, "low-cost activity uses level one")
        check(CostActivityScale.level(dollars: 3, maximum: 10) == 2, "quarter-cost activity uses level two")
        check(CostActivityScale.level(dollars: 6, maximum: 10) == 3, "mid-cost activity uses level three")
        check(CostActivityScale.level(dollars: 10, maximum: 10) == 4, "maximum-cost activity uses level four")
        check(
            (0...4).map(ActivityHeatmapPalette.opacity(for:)) == [0.12, 0.28, 0.44, 0.62, 0.82],
            "Token and Cost activity share one neutral heatmap palette"
        )
        check(
            ActivityHeatmapScale.level(value: 6, maximum: 10)
                == CostActivityScale.level(dollars: 6, maximum: 10),
            "Token and Cost activity share the same density thresholds"
        )
        let weeklyCostRanges = CostActivityBucketLayout.ranges(dayCount: 7, rangeDays: 7)
        check(weeklyCostRanges.count == 7, "weekly cost chart uses seven daily bars")
        let monthlyCostRanges = CostActivityBucketLayout.ranges(dayCount: 30, rangeDays: 30)
        check(
            monthlyCostRanges.count == 30 && monthlyCostRanges.allSatisfy { $0.count == 1 },
            "monthly cost chart uses thirty daily bars"
        )
        let quarterlyCostRanges = CostActivityBucketLayout.ranges(dayCount: 90, rangeDays: 90)
        check(
            quarterlyCostRanges.count == 30
                && quarterlyCostRanges.allSatisfy { $0.count == 3 },
            "quarterly cost chart uses thirty three-day bars"
        )
        let halfYearCostRanges = CostActivityBucketLayout.ranges(dayCount: 180, rangeDays: 180)
        check(
            halfYearCostRanges.count == 26
                && halfYearCostRanges.dropLast().allSatisfy { $0.count == 7 }
                && halfYearCostRanges.last?.count == 5,
            "half-year cost chart uses weekly bars with one five-day edge bucket"
        )
    }

    private static func verifyProjectCatalogAliases() {
        let fixture = Data("""
        {
          "local-projects": {
            "media": {
              "id": "media",
              "name": "自媒体选题",
              "rootPaths": ["/tmp/AI博主选题"]
            },
            "cards": {
              "id": "cards",
              "name": "卡网搭建",
              "rootPaths": ["/tmp/独角兽卡网搭建"]
            }
          }
        }
        """.utf8)
        let names = CodexProjectCatalog.namesByPath(from: fixture)
        check(names["/tmp/AI博主选题"] == "自媒体选题", "media sidebar alias fixture")
        check(names["/tmp/独角兽卡网搭建"] == "卡网搭建", "card sidebar alias fixture")
        check(
            CodexProjectCatalog.displayName(
                for: "/tmp/AI博主选题/drafts",
                namesByPath: names
            ) == "自媒体选题",
            "nested media path inherits sidebar alias"
        )
    }

    private static func verifyCurrentAccountSelection() {
        let options = [
            UsageAccountOption(id: "account-1", alias: "账号 1", emailSummary: nil, isCurrent: false),
            UsageAccountOption(id: "account-2", alias: "账号 2", emailSummary: nil, isCurrent: true),
        ]
        check(
            UsageAccountSelection.currentAccountID(in: options) == "account-2",
            "Glance follows the observed current account"
        )
        check(
            UsageAccountSelection.currentAccountID(in: options.map {
                UsageAccountOption(
                    id: $0.id,
                    alias: $0.alias,
                    emailSummary: $0.emailSummary,
                    isCurrent: false
                )
            }) == nil,
            "Glance never falls back to aggregate history without a current account"
        )
    }

    private static func verifyRollingWindowsAndAccountScopes() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-08-17T12:00:00Z")!
        let today = calendar.startOfDay(for: now)
        func date(daysAgo: Int, hour: Int = 8) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: today)!
            return calendar.date(byAdding: .hour, value: hour, to: day)!
        }
        func event(_ sessionID: String, daysAgo: Int, input: Int) -> TokenUsageEvent {
            TokenUsageEvent(
                provider: .codex,
                timestamp: date(daysAgo: daysAgo),
                model: "gpt-5.4",
                sessionID: sessionID,
                projectPath: "/tmp/\(sessionID)",
                input: input,
                output: 0,
                cacheCreate: 0,
                cacheRead: 0
            )
        }
        let events = [
            event("account-1-today", daysAgo: 0, input: 100),
            event("account-2-week-start", daysAgo: 6, input: 200),
            event("unknown-month-start", daysAgo: 29, input: 300),
            event("outside-window", daysAgo: 30, input: 400),
            event("quarter-only", daysAgo: 60, input: 500),
        ]
        let context = UsageAccountContext(
            accounts: [
                UsageAccountOption(id: "account-1", alias: "账号 1", emailSummary: "ac***-1@example.com", isCurrent: true),
                UsageAccountOption(id: "account-2", alias: "账号 2", emailSummary: nil, isCurrent: false),
            ],
            accountIDByThread: [
                "account-1-today": "account-1",
                "account-2-week-start": "account-2",
            ],
            accountTimeline: []
        )
        let snapshot = CostService.summarize(
            events,
            projectNames: [:],
            accountContext: context,
            now: now,
            calendar: calendar
        )
        let account1 = snapshot.scope(for: "account-1")
        let account2 = snapshot.scope(for: "account-2")
        let unknown = snapshot.scope(for: UsageAccountScope.unknown)

        check(snapshot.week.tokens == 300, "rolling 7 days include today through six days ago")
        check(snapshot.month.tokens == 600, "rolling 30 days include today through 29 days ago")
        check(snapshot.usage.week.series[0] == 200, "rolling week starts six days ago")
        check(snapshot.usage.week.series[6] == 100, "rolling week ends today")
        check(snapshot.usage.month.series[0] == 300, "rolling month starts 29 days ago")
        check(snapshot.usage.month.series[29] == 100, "rolling month ends today")
        check(snapshot.usage.quarter.tokens == 1_500, "rolling 90 days includes the full quarterly window")
        check(snapshot.usage.quarter.series[29] == 500, "quarterly Usage trend places the 60-day event correctly")
        check(snapshot.usage.quarter.series[89] == 100, "quarterly Usage trend ends on today")
        check(snapshot.usage.activity.count == 180, "activity keeps a stable 180-day range")
        check(snapshot.usage.activity.last?.date == today, "activity ends on today")
        check(snapshot.usage.activity.reduce(0) { $0 + $1.tokens } == 1_500, "activity includes events outside the 30-day summary")
        check(snapshot.costActivity.count == 180, "cost activity keeps a stable 180-day range")
        check(snapshot.costActivity.last?.date == today, "cost activity ends on today")
        check(
            snapshot.costActivity.reduce(0) { $0 + $1.dollars } > snapshot.month.dollars,
            "cost activity includes priced events outside the 30-day summary"
        )
        check(account1.month.tokens == 100, "account 1 scope")
        check(account2.month.tokens == 200, "account 2 scope")
        check(unknown.month.tokens == 300, "unknown ownership scope")
        check(
            snapshot.month.tokens == account1.month.tokens + account2.month.tokens + unknown.month.tokens,
            "account token scopes reconcile with aggregate"
        )
        check(
            abs(snapshot.month.dollars - account1.month.dollars - account2.month.dollars - unknown.month.dollars) < 0.000_001,
            "account cost scopes reconcile with aggregate"
        )
        check(
            zip(snapshot.month.series, zip(account1.month.series, zip(account2.month.series, unknown.month.series))).allSatisfy {
                abs($0.0 - $0.1.0 - $0.1.1.0 - $0.1.1.1) < 0.000_001
            },
            "account cost curves reconcile with aggregate"
        )
        check(
            zip(snapshot.usage.activity, zip(account1.usage.activity, zip(account2.usage.activity, unknown.usage.activity))).allSatisfy {
                $0.0.tokens == $0.1.0.tokens + $0.1.1.0.tokens + $0.1.1.1.tokens
            },
            "account activity cells reconcile with aggregate"
        )
        check(
            zip(snapshot.costActivity, zip(account1.costActivity, zip(account2.costActivity, unknown.costActivity))).allSatisfy {
                abs($0.0.dollars - $0.1.0.dollars - $0.1.1.0.dollars - $0.1.1.1.dollars) < 0.000_001
            },
            "account cost activity cells reconcile with aggregate"
        )
    }

    private static func verifyAccountTimelineSplitsExistingSession() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let formatter = ISO8601DateFormatter()
        let now = formatter.date(from: "2026-08-17T12:00:00Z")!
        func event(_ sessionID: String, _ timestamp: String, _ input: Int) -> TokenUsageEvent {
            TokenUsageEvent(
                provider: .codex,
                timestamp: formatter.date(from: timestamp)!,
                model: "gpt-5.4",
                sessionID: sessionID,
                projectPath: "/tmp/SharedProject",
                input: input,
                output: 0,
                cacheCreate: 0,
                cacheRead: 0
            )
        }
        let events = [
            event("shared-session", "2026-08-17T08:30:00Z", 50),
            event("unknown-session", "2026-08-17T08:45:00Z", 25),
            event("shared-session", "2026-08-17T09:30:00Z", 100),
            event("shared-session", "2026-08-17T10:30:00Z", 200),
            event("shared-session", "2026-08-17T11:30:00Z", 300),
        ]
        let context = UsageAccountContext(
            accounts: [
                UsageAccountOption(id: "account-1", alias: "账号 1", emailSummary: nil, isCurrent: true),
                UsageAccountOption(id: "account-2", alias: "账号 2", emailSummary: nil, isCurrent: false),
            ],
            accountIDByThread: ["shared-session": "account-2"],
            accountTimeline: [
                UsageAccountObservation(
                    accountID: "account-1",
                    startsAt: formatter.date(from: "2026-08-17T09:00:00Z")!
                ),
                UsageAccountObservation(
                    accountID: "account-2",
                    startsAt: formatter.date(from: "2026-08-17T10:00:00Z")!
                ),
                UsageAccountObservation(
                    accountID: "account-1",
                    startsAt: formatter.date(from: "2026-08-17T11:00:00Z")!
                ),
            ]
        )
        let snapshot = CostService.summarize(
            events,
            projectNames: [:],
            accountContext: context,
            now: now,
            calendar: calendar
        )
        let account1 = snapshot.scope(for: "account-1")
        let account2 = snapshot.scope(for: "account-2")
        let unknown = snapshot.scope(for: UsageAccountScope.unknown)

        check(account1.today.tokens == 400, "existing session events after switches follow account timeline")
        check(account2.today.tokens == 250, "pre-timeline event falls back without moving old history")
        check(unknown.today.tokens == 25, "pre-timeline session without reliable ownership stays unknown")
        check(snapshot.today.tokens == 675, "timeline account scopes reconcile with aggregate")
        check(
            snapshot.today.tokens == account1.today.tokens + account2.today.tokens + unknown.today.tokens,
            "timeline token totals partition the aggregate"
        )
        check(
            abs(snapshot.today.dollars - account1.today.dollars - account2.today.dollars - unknown.today.dollars) < 0.000_001,
            "timeline cost totals partition the aggregate"
        )
    }

    private static func verifyMovedThreadUsesCurrentProject() {
        let event = TokenUsageEvent(
            provider: .codex,
            timestamp: Date(),
            model: "gpt-5.4",
            sessionID: "moved-session",
            projectPath: "/tmp/OldProject",
            input: 100,
            output: 10,
            cacheCreate: 0,
            cacheRead: 0
        )
        let catalog = CodexProjectCatalog.State(
            namesByPath: ["/tmp/NewProject": "新项目"],
            assignmentsByThread: [
                "moved-session": CodexProjectCatalog.Assignment(
                    projectID: "new-project",
                    projectName: "新项目",
                    path: "/tmp/NewProject"
                ),
            ]
        )
        let remapped = CostService.remapEvents(
            [event],
            sessionPathOverrides: ["moved-session": "/tmp/HookStillOld"],
            catalog: catalog
        )
        check(remapped.first?.projectPath == "/tmp/NewProject", "moved thread remaps usage and cost path")
        check(remapped.first?.sessionID == "moved-session", "moved thread retains usage session identity")
    }

    private static func verifyArchivedSessionsAreIncludedOnce() {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: home) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = ISO8601DateFormatter().date(from: "2026-08-12T12:00:00Z")!
        let liveDirectory = home.appendingPathComponent(".codex/sessions/2026/08/12", isDirectory: true)
        let oldLiveDirectory = home.appendingPathComponent(".codex/sessions/2026/06/01", isDirectory: true)
        let archiveDirectory = home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        try! manager.createDirectory(at: liveDirectory, withIntermediateDirectories: true)
        try! manager.createDirectory(at: oldLiveDirectory, withIntermediateDirectories: true)
        try! manager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)

        let live = rollout(sessionID: "live-session", timestamp: "2026-08-12T08:00:00Z", input: 100)
        let archived = rollout(sessionID: "archived-session", timestamp: "2026-08-11T08:00:00Z", input: 200)
        let liveURL = liveDirectory.appendingPathComponent("rollout-live.jsonl")
        let archivedURL = archiveDirectory.appendingPathComponent("rollout-archived.jsonl")
        let duplicateURL = liveDirectory.appendingPathComponent("rollout-archived-copy.jsonl")
        let longRunningURL = oldLiveDirectory.appendingPathComponent("rollout-long-running.jsonl")
        try! Data(live.utf8).write(to: liveURL)
        try! Data(archived.utf8).write(to: archivedURL)
        try! Data(archived.utf8).write(to: duplicateURL)
        try! Data(rollout(sessionID: "long-running", timestamp: "2026-08-10T08:00:00Z", input: 50).utf8)
            .write(to: longRunningURL)
        try! manager.setAttributes([.modificationDate: now], ofItemAtPath: archivedURL.path)
        try! manager.setAttributes([.modificationDate: now], ofItemAtPath: longRunningURL.path)

        let events = CostService.scanCodex(homeDirectory: home, now: now, calendar: calendar)
        check(events.count == 3, "live and archived events included without duplicate counting")
        check(
            Set(events.map(\.sessionID)) == Set(["live-session", "archived-session", "long-running"]),
            "rolling scan retains archived and long-running session identity"
        )
        check(events.reduce(0) { $0 + $1.input } == 350, "archived tokens included exactly once")

        let staleURL = archiveDirectory.appendingPathComponent("rollout-stale.jsonl")
        try! Data(rollout(sessionID: "stale-session", timestamp: "2025-12-01T08:00:00Z", input: 900).utf8)
            .write(to: staleURL)
        try! manager.setAttributes([
            .modificationDate: ISO8601DateFormatter().date(from: "2025-12-01T09:00:00Z")!
        ], ofItemAtPath: staleURL.path)
        let filtered = CostService.scanCodex(homeDirectory: home, now: now, calendar: calendar)
        check(!filtered.contains(where: { $0.sessionID == "stale-session" }), "old archive skipped outside 180-day activity range")
    }

    private static func rollout(sessionID: String, timestamp: String, input: Int) -> String {
        """
        {"timestamp":"\(timestamp)","type":"session_meta","payload":{"id":"\(sessionID)","cwd":"/tmp/\(sessionID)"}}
        {"timestamp":"\(timestamp)","type":"turn_context","payload":{"model":"gpt-5.4"}}
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(input),"cached_input_tokens":0,"output_tokens":10}}}}

        """
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else {
            fputs("FAILED: \(label)\n", stderr)
            exit(1)
        }
    }
}
