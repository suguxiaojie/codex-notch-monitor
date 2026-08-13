import Foundation

@main
enum CostSmokeTests {
    static func main() {
        verifyArchivedSessionsAreIncludedOnce()
        verifyMovedThreadUsesCurrentProject()
        let service = CostService()
        service.fetch { snapshot in
            check(snapshot.today.series.count == 24, "24-hour trend")
            check(snapshot.month.series.count >= 28, "month trend")
            check(snapshot.month.tokens >= snapshot.today.tokens, "month contains today")
            check(snapshot.month.dollars >= snapshot.today.dollars, "month cost contains today")
            check(snapshot.month.tokens > 0, "local Codex token events")
            check(snapshot.month.dollars > 0 || !snapshot.unknownModels.isEmpty, "priced or reported unknown models")
            check(
                snapshot.estimatedModelAliases["codex-auto-review"] == nil ||
                !snapshot.unknownModels.contains("codex-auto-review"),
                "estimated auto review is not also reported unknown"
            )
            check(snapshot.usage.day.series.count == 24, "daily usage has 24 hourly buckets")
            check(snapshot.usage.week.series.count == 7, "weekly usage has 7 daily buckets")
            check(snapshot.usage.month.series.count >= 28, "monthly usage has calendar-day buckets")
            check(snapshot.usage.month.tokens >= snapshot.usage.week.tokens, "month usage contains current week")
            check(snapshot.usage.week.tokens >= snapshot.usage.day.tokens, "week usage contains today")
            check(snapshot.usage.month.sessionCount > 0, "usage session aggregation")
            check(snapshot.usage.month.projectCount > 0, "usage project aggregation")
            check(!snapshot.usage.month.projects.isEmpty, "usage project ranking")
            let projectNames = Set(snapshot.usage.month.projects.map(\.name))
            if FileManager.default.fileExists(atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/.codex-global-state.json").path) {
                check(projectNames.contains("自媒体选题"), "Codex sidebar alias for media project")
                check(projectNames.contains("卡网搭建"), "Codex sidebar alias for card project")
                check(!projectNames.contains("AI博主选题"), "folder name replaced by media sidebar alias")
            }
            print(String(format:
                "Cost and usage smoke tests passed (24 checks): today $%.2f / %d tokens, month $%.2f / %d tokens. Aliases: %@",
                snapshot.today.dollars, snapshot.today.tokens,
                snapshot.month.dollars, snapshot.month.tokens,
                snapshot.estimatedModelAliases.description
            ))
            exit(0)
        }
        RunLoop.main.run()
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
        let archiveDirectory = home.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        try! manager.createDirectory(at: liveDirectory, withIntermediateDirectories: true)
        try! manager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)

        let live = rollout(sessionID: "live-session", timestamp: "2026-08-12T08:00:00Z", input: 100)
        let archived = rollout(sessionID: "archived-session", timestamp: "2026-08-11T08:00:00Z", input: 200)
        let liveURL = liveDirectory.appendingPathComponent("rollout-live.jsonl")
        let archivedURL = archiveDirectory.appendingPathComponent("rollout-archived.jsonl")
        let duplicateURL = liveDirectory.appendingPathComponent("rollout-archived-copy.jsonl")
        try! Data(live.utf8).write(to: liveURL)
        try! Data(archived.utf8).write(to: archivedURL)
        try! Data(archived.utf8).write(to: duplicateURL)
        try! manager.setAttributes([.modificationDate: now], ofItemAtPath: archivedURL.path)

        let events = CostService.scanCodex(homeDirectory: home, now: now, calendar: calendar)
        check(events.count == 2, "live and archived events included without duplicate counting")
        check(Set(events.map(\.sessionID)) == Set(["live-session", "archived-session"]), "archived session identity retained")
        check(events.reduce(0) { $0 + $1.input } == 300, "archived tokens included exactly once")

        let staleURL = archiveDirectory.appendingPathComponent("rollout-stale.jsonl")
        try! Data(rollout(sessionID: "stale-session", timestamp: "2026-07-01T08:00:00Z", input: 900).utf8)
            .write(to: staleURL)
        try! manager.setAttributes([
            .modificationDate: ISO8601DateFormatter().date(from: "2026-07-01T09:00:00Z")!
        ], ofItemAtPath: staleURL.path)
        let filtered = CostService.scanCodex(homeDirectory: home, now: now, calendar: calendar)
        check(!filtered.contains(where: { $0.sessionID == "stale-session" }), "old archive skipped outside current ranges")
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
