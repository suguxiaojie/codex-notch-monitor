import Foundation

@main
enum CostSmokeTests {
    static func main() {
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
                check(!projectNames.contains("独角兽卡网搭建"), "folder name replaced by card sidebar alias")
            }
            print(String(format:
                "Cost and usage smoke tests passed (19 checks): today $%.2f / %d tokens, month $%.2f / %d tokens. Aliases: %@",
                snapshot.today.dollars, snapshot.today.tokens,
                snapshot.month.dollars, snapshot.month.tokens,
                snapshot.estimatedModelAliases.description
            ))
            exit(0)
        }
        RunLoop.main.run()
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else {
            fputs("FAILED: \(label)\n", stderr)
            exit(1)
        }
    }
}
