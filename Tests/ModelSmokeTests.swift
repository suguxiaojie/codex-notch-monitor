import Foundation

@main
enum ModelSmokeTests {
    static func main() {
        check(
            RateLimitWindow(usedPercent: 25, windowDurationMinutes: 300, resetsAt: nil).remainingPercent == 75,
            "remaining percentage"
        )
        check(
            RateLimitWindow(usedPercent: 120, windowDurationMinutes: nil, resetsAt: nil).remainingPercent == 0,
            "remaining percentage clamp"
        )

        let countdownNow = Date(timeIntervalSince1970: 1_800_000_000)
        check(
            QuotaResetCountdown.text(
                until: countdownNow.addingTimeInterval(3 * 86_400 + 19 * 3_600),
                relativeTo: countdownNow
            ) == "3天19小时后重置",
            "quota countdown shows days and hours"
        )
        check(
            QuotaResetCountdown.text(
                until: countdownNow.addingTimeInterval(19 * 3_600 + 26 * 60),
                relativeTo: countdownNow
            ) == "19小时26分钟后重置",
            "quota countdown shows hours and minutes"
        )
        check(
            QuotaResetCountdown.text(
                until: countdownNow.addingTimeInterval(26 * 60),
                relativeTo: countdownNow
            ) == "26分钟后重置",
            "quota countdown shows minutes"
        )
        check(
            QuotaResetCountdown.text(until: countdownNow.addingTimeInterval(30), relativeTo: countdownNow)
                == "即将重置",
            "quota countdown handles the final minute"
        )
        check(
            QuotaResetCountdown.text(until: countdownNow, relativeTo: countdownNow) == "等待额度刷新",
            "quota countdown handles an elapsed reset time"
        )

        let payload: [String: Any] = [
            "rateLimitsByLimitId": [
                "codex": [
                    "limitId": "codex",
                    "primary": ["usedPercent": 23, "windowDurationMins": 10_080, "resetsAt": 1_786_000_000],
                    "secondary": ["usedPercent": 40, "windowDurationMins": 300, "resetsAt": 1_785_500_000],
                    "planType": "plus",
                    "credits": ["hasCredits": true, "unlimited": false, "balance": "12.5"],
                ],
                "codex_other": [
                    "limitName": "Spark",
                    "primary": ["usedPercent": 5],
                ],
            ],
        ]
        let buckets = QuotaService.parseBuckets(from: payload)
        check(buckets.first?.id == "codex", "Codex bucket ordering")
        check(buckets.first?.headlineWindow?.remainingPercent == 60, "short window becomes compact headline")
        check(buckets.first?.headlineWindow?.windowDurationMinutes == 300, "five-hour window priority")
        check(buckets.first?.windows.map(\.windowDurationMinutes) == [300, 10_080], "all windows sorted shortest first")
        check(buckets.first?.planType == "plus", "plan type")
        check(buckets.count == 2, "multi-bucket payload")

        check(HookEventMapper.phase(for: "PermissionRequest") == .waitingApproval, "approval mapping")
        check(HookEventMapper.phase(for: "Stop") == .completed, "completion mapping")
        check(HookEventMapper.phase(for: "PreToolUse") == .usingTool, "tool mapping")
        let commandInput = #"const r = await tools.exec_command({ cmd: "swift build && echo done", workdir: "/tmp" });"#
        let commandSummary = SessionActivityService.toolSummary(name: "exec", input: commandInput)
        check(
            commandSummary == "运行命令 · swift build && echo done",
            "command summary extraction"
        )
        check(
            SessionActivityService.toolSummary(name: "apply_patch", input: "ignored") == "修改项目文件",
            "file change summary"
        )
        let readInput = #"const r = await tools.exec_command({ cmd: "sed -n '1,200p' Sources/SessionActivityService.swift" });"#
        check(
            SessionActivityService.toolSummary(name: "exec", input: readInput)
                == "读取 SessionActivityService.swift",
            "file read summary"
        )
        let titledInput = #"await tools.mcp__node_repl__js({ title: "验证实时活动显示", code: "test" });"#
        check(
            SessionActivityService.toolSummary(name: "exec", input: titledInput) == "验证实时活动显示",
            "tool title summary"
        )

        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rollout-test-00000000-0000-0000-0000-000000000001.jsonl")
        let fixture = """
        {"timestamp":"2026-08-12T06:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}
        {"timestamp":"2026-08-12T06:00:00.100Z","type":"turn_context","payload":{"turn_id":"turn-1","cwd":"/tmp/DemoProject","model":"gpt-test"}}
        {"timestamp":"2026-08-12T06:00:01.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","call_id":"call-1","input":"const r = await tools.exec_command({ cmd: \\"sed -n '1,80p' Sources/App.swift\\" });"}}
        """
        try? fixture.data(using: .utf8)?.write(to: fixtureURL)
        let activityService = SessionActivityService()
        let activeSnapshot = activityService.readSnapshot(from: fixtureURL)
        check(activeSnapshot?.isActive == true, "active task boundary")
        check(activeSnapshot?.cwd == "/tmp/DemoProject", "session working directory")
        check(activeSnapshot?.activities.first?.title == "读取 App.swift", "live read activity")
        check(activeSnapshot?.activities.first?.isRunning == true, "running tool state")

        let completedSuffix = """

        {"timestamp":"2026-08-12T06:00:02.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"call-1"}}
        {"timestamp":"2026-08-12T06:00:03.000Z","type":"event_msg","payload":{"type":"task_complete"}}
        """
        if let handle = try? FileHandle(forWritingTo: fixtureURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: completedSuffix.data(using: .utf8)!)
            try? handle.close()
        }
        let completedSnapshot = activityService.readSnapshot(from: fixtureURL)
        check(completedSnapshot?.isActive == false, "completed task boundary")
        check(completedSnapshot?.activities.first?.isRunning == false, "completed tool state")
        check(
            completedSnapshot?.activities.first?.updatedAt
                == ISO8601DateFormatter().date(from: "2026-08-12T06:00:02Z"),
            "tool completion carries its event timestamp"
        )

        let baseDate = Date(timeIntervalSince1970: 1_786_000_000)
        let projectA = LocalSessionSnapshot(
            sessionID: "session-a",
            turnID: "turn-a",
            cwd: "/tmp/ProjectA",
            model: "gpt-test",
            isActive: true,
            updatedAt: baseDate,
            activities: [SessionActivityItem(
                id: "command-a", kind: .command, title: "运行测试", isRunning: true, updatedAt: baseDate
            )]
        )
        let projectB = LocalSessionSnapshot(
            sessionID: "session-b",
            turnID: "turn-b",
            cwd: "/tmp/ProjectB",
            model: "gpt-test",
            isActive: true,
            updatedAt: baseDate.addingTimeInterval(10),
            activities: []
        )
        let approval = MonitoredTask(
            id: "session-b", turnID: "turn-b", projectName: "ProjectB",
            projectPath: "/tmp/ProjectB", model: "gpt-test", toolName: nil,
            phase: .waitingApproval, updatedAt: baseDate.addingTimeInterval(10)
        )
        let projects = ProjectActivityAggregator.projects(
            snapshots: [projectA, projectB], hookTasks: [approval],
            now: baseDate.addingTimeInterval(20)
        )
        check(projects.count == 2, "aggregate concurrent projects")
        check(projects.first?.name == "ProjectB", "approval project receives focus")
        check(projects.first?.task.phase == .waitingApproval, "approval phase preserved")

        let catalogFixture: [String: Any] = [
            "local-projects": [
                "media-project": [
                    "id": "media-project",
                    "name": "自媒体选题",
                    "rootPaths": ["/tmp/AI博主选题"],
                ],
                "moved-project": [
                    "id": "moved-project",
                    "name": "新项目",
                    "rootPaths": ["/tmp/NewProject"],
                ],
            ],
            "thread-project-assignments": [
                "session-a": [
                    "projectKind": "local",
                    "projectId": "moved-project",
                    "cwd": "/tmp/NewProject",
                    "pendingCoreUpdate": true,
                ],
            ],
        ]
        let catalogData = try! JSONSerialization.data(withJSONObject: catalogFixture)
        let catalogState = CodexProjectCatalog.state(from: catalogData)
        let catalogNames = catalogState.namesByPath
        check(catalogNames["/tmp/AI博主选题"] == "自媒体选题", "read Codex saved project label")
        check(
            CodexProjectCatalog.displayName(
                for: "/tmp/AI博主选题/Sources",
                namesByPath: catalogNames
            ) == "自媒体选题",
            "saved project label also resolves child cwd"
        )
        check(
            catalogState.assignmentsByThread["session-a"]?.projectName == "新项目",
            "read moved thread project name"
        )
        check(
            catalogState.assignmentsByThread["session-a"]?.path == "/tmp/NewProject",
            "read moved thread project path"
        )

        let oldActivity = SessionActivityItem(
            id: "old", kind: .command, title: "运行旧命令",
            isRunning: false, updatedAt: baseDate
        )
        let newestActivity = SessionActivityItem(
            id: "new", kind: .read, title: "读取最新文件",
            isRunning: true, updatedAt: baseDate.addingTimeInterval(30)
        )
        let unsortedProject = ActiveProjectState(
            id: "/tmp/ProjectA", name: "ProjectA", path: "/tmp/ProjectA",
            sessions: [], task: projects.last!.task,
            activities: Array([newestActivity, oldActivity].reversed())
        )
        check(unsortedProject.latestDisplayActivity?.id == "new", "compact card selects newest real activity")

        let renamedHook = MonitoredTask(
            id: "session-a", turnID: "turn-a", projectName: "ProjectA-Renamed",
            projectPath: "/tmp/ProjectA-Renamed", model: "gpt-test", toolName: nil,
            phase: .working, updatedAt: baseDate.addingTimeInterval(12)
        )
        let renamedProjects = ProjectActivityAggregator.projects(
            snapshots: [projectA], hookTasks: [renamedHook],
            now: baseDate.addingTimeInterval(20)
        )
        check(renamedProjects.first?.name == "ProjectA-Renamed", "live hook updates renamed project")
        check(renamedProjects.first?.task.phase == .usingTool, "rename keeps higher-priority live tool phase")
        let reassignedProjects = ProjectActivityAggregator.projects(
            snapshots: [projectA], hookTasks: [renamedHook],
            now: baseDate.addingTimeInterval(20), catalog: catalogState
        )
        check(reassignedProjects.first?.name == "新项目", "thread assignment updates live card name")
        check(reassignedProjects.first?.path == "/tmp/NewProject", "thread assignment beats historical and hook cwd")

        let staleCompletionHook = MonitoredTask(
            id: "session-b", turnID: "turn-b", projectName: "ProjectB",
            projectPath: "/tmp/ProjectB", model: "gpt-test", toolName: nil,
            phase: .completed, updatedAt: baseDate.addingTimeInterval(11)
        )
        check(
            ProjectActivityAggregator.projects(
                snapshots: [projectA, projectB], hookTasks: [staleCompletionHook],
                now: baseDate.addingTimeInterval(20)
            ).count == 2,
            "active transcript is not suppressed by stale completion hook"
        )

        let secondSessionSameProject = LocalSessionSnapshot(
            sessionID: "session-c", turnID: "turn-c", cwd: "/tmp/ProjectA",
            model: "gpt-test", isActive: true,
            updatedAt: baseDate.addingTimeInterval(5), activities: []
        )
        let groupedProjects = ProjectActivityAggregator.projects(
            snapshots: [projectA, secondSessionSameProject], hookTasks: [],
            now: baseDate.addingTimeInterval(20)
        )
        check(groupedProjects.count == 1, "group sessions by project path")
        check(groupedProjects.first?.sessionCount == 2, "show session count per project")
        check(CompactProjectLayout.contentHeight(for: 1) == 22, "single project compact height")
        check(CompactProjectLayout.contentHeight(for: 2) == 38, "two project compact height")
        check(CompactProjectLayout.contentHeight(for: 4) == 62, "four project compact height")
        check(CompactProjectLayout.directProjectCount(for: 6) == 3, "large project summary slot")
        check(
            CompactProjectLayout.reconcileOrder(
                existing: ["project-b", "project-a"],
                discovered: ["project-a", "project-b", "project-c"]
            ) == ["project-b", "project-a", "project-c"],
            "preserve project slots while appending newcomers"
        )
        check(
            CompactGeometryPolicy.fittedNotchedPanelWidth(
                hardwareGap: 140,
                leftCapacity: 180,
                rightCapacity: 150,
                screenWidth: 1_512
            ) == 430,
            "notch geometry fits balanced wings within the host"
        )
        check(
            CompactGeometryPolicy.fittedNotchedPanelWidth(
                hardwareGap: 140,
                leftCapacity: 600,
                rightCapacity: 600,
                screenWidth: 1_512
            ) == 430,
            "missing menu boundary cannot stretch compact island"
        )
        check(
            CompactGeometryPolicy.fittedNotchedPanelWidth(
                hardwareGap: 420,
                leftCapacity: 180,
                rightCapacity: 180,
                screenWidth: 1_512
            ) == nil,
            "transitional oversized notch sample is rejected"
        )
        check(
            CompactGeometryPolicy.fittedNotchedPanelWidth(
                hardwareGap: 140,
                leftCapacity: 180,
                rightCapacity: 40,
                screenWidth: 1_512
            ) == nil,
            "missing right menu capacity is rejected"
        )

        let attributionURL = CoverAILinks.url(for: .brandAttribution)
        check(
            attributionURL?.scheme == "https" && attributionURL?.host == "coverai.store",
            "CoverAI links use the fixed HTTPS host"
        )
        let attributionItems = URLComponents(url: attributionURL!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        check(
            attributionItems.contains(URLQueryItem(name: "utm_source", value: "codex_monitor")),
            "CoverAI links identify the app source"
        )
        check(
            attributionItems.contains(URLQueryItem(name: "utm_campaign", value: "brand_attribution"))
                && CoverAILinks.url(for: .dashboardCard)?.absoluteString.contains("utm_campaign=dashboard_card") == true
                && CoverAILinks.url(for: .appMenu)?.absoluteString.contains("utm_campaign=app_menu") == true,
            "CoverAI entry points use distinct campaigns"
        )
        try? FileManager.default.removeItem(at: fixtureURL)

        print("Model smoke tests passed (50 checks).")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else {
            fputs("FAILED: \(label)\n", stderr)
            exit(1)
        }
    }
}
