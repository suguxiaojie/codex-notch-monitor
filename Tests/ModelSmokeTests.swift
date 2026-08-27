import AppKit
import Foundation

@main
enum ModelSmokeTests {
    static func main() {
        check(MonitorRefreshCadence.quota == 60, "quota refreshes every minute")
        check(MonitorRefreshCadence.cost == 300, "cost scan remains five minutes")
        check(
            MonitorRefreshCadence.sessionActivity == 5,
            "session transcript fallback avoids battery-heavy rapid reparsing"
        )
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
            "rateLimitResetCredits": [
                "availableCount": 2,
                "credits": [
                    [
                        "id": "credit-later",
                        "resetType": "temporary",
                        "status": "available",
                        "grantedAt": 1_800_000_000,
                        "expiresAt": 1_800_086_400,
                    ],
                    [
                        "id": "credit-sooner",
                        "resetType": "temporary",
                        "status": "available",
                        "grantedAt": 1_800_000_000,
                        "expiresAt": 1_800_043_200,
                    ],
                ],
            ],
        ]
        let buckets = QuotaService.parseBuckets(from: payload)
        check(buckets.first?.id == "codex", "Codex bucket ordering")
        check(buckets.first?.headlineWindow?.remainingPercent == 60, "short window becomes compact headline")
        check(buckets.first?.headlineWindow?.windowDurationMinutes == 300, "five-hour window priority")
        check(buckets.first?.windows.map(\.windowDurationMinutes) == [300, 10_080], "all windows sorted shortest first")
        check(buckets.first?.planType == "plus", "plan type")
        check(buckets.first?.hasCredits == true, "Credits availability")
        check(buckets.first?.creditBalance == "12.5", "Credits balance")
        check(OpenAIPlanDisplayName.resolve("plus") == "Plus", "Plus display name")
        check(OpenAIPlanDisplayName.resolve("prolite") == "Pro 5x", "Pro 5x display name")
        check(OpenAIPlanDisplayName.resolve("pro") == "Pro 20x", "Pro 20x display name")
        check(OpenAIPlanDisplayName.resolve("future_plan") == nil, "unknown plan remains undisclosed")
        check(buckets.count == 2, "multi-bucket payload")
        let resetCredits = QuotaService.parseResetCredits(from: payload)
        check(resetCredits?.availableCount == 2, "reset credit availability count")
        check(resetCredits?.credits.count == 2, "reset credit details are preserved")
        check(
            resetCredits?.nearestExpiration(relativeTo: countdownNow)
                == Date(timeIntervalSince1970: 1_800_043_200),
            "nearest future reset credit expiration"
        )
        check(
            resetCredits?.nextRedeemableCredit(relativeTo: countdownNow)?.id
                == "credit-sooner",
            "reset operation selects the earliest redeemable credit"
        )
        check(
            QuotaService.parseResetCredits(from: [:]) == nil,
            "missing reset-credit evidence stays unknown"
        )
        check(
            QuotaResetCreditSummary(availableCount: 1, credits: [])
                .nearestExpiration(relativeTo: countdownNow) == nil,
            "available reset credit without expiry stays explicitly unknown"
        )
        check(
            ["reset", "nothingToReset", "noCredit", "alreadyRedeemed"].allSatisfy {
                (try? QuotaService.parseConsumeOutcome(from: ["outcome": $0]))
                    == QuotaResetConsumeOutcome(rawValue: $0)
            },
            "all official reset-credit outcomes are parsed"
        )
        check(
            (try? QuotaService.parseConsumeOutcome(from: ["outcome": "unexpected"])) == nil,
            "unknown reset-credit outcome fails closed"
        )
        let consumeKey = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let consumeParams = QuotaService.consumeResetCreditParams(
            creditID: "credit-sooner",
            idempotencyKey: consumeKey
        )
        check(
            consumeParams["creditId"] as? String == "credit-sooner"
                && consumeParams["idempotencyKey"] as? String == consumeKey.uuidString,
            "reset-credit request carries the selected credit and idempotency key"
        )
        check(
            QuotaService.consumeResetCreditParams(
                creditID: nil,
                idempotencyKey: consumeKey
            )["creditId"] == nil,
            "reset-credit request lets the backend select a credit when details are absent"
        )

        let idleGlow = RippleGlowStyles.style(for: nil)
        let workingGlow = RippleGlowStyles.style(for: .working)
        let toolGlow = RippleGlowStyles.style(for: .usingTool)
        let approvalGlow = RippleGlowStyles.style(for: .waitingApproval)
        let failedGlow = RippleGlowStyles.style(for: .failed)
        let endedGlow = RippleGlowStyles.style(for: .ended)
        let statusNow = Date(timeIntervalSince1970: 1_700_000_000)
        let statusWindow = RateLimitWindow(
            usedPercent: 4,
            windowDurationMinutes: 10_080,
            resetsAt: statusNow.addingTimeInterval(6 * 86_400 + 3_600)
        )
        check(
            MenuBarStatusFormatter.title(for: statusWindow, relativeTo: statusNow)
                == "96% · 6天",
            "menu bar status separates quota and reset day"
        )
        check(
            MenuBarStatusFormatter.resetText(
                statusNow.addingTimeInterval(4 * 3_600 + 59 * 60),
                relativeTo: statusNow
            ) == "4小时",
            "menu bar reset uses compact hour label"
        )
        let menuBarBucket = RateLimitBucket(
            id: "codex",
            name: "Codex",
            planType: "pro",
            primary: statusWindow,
            secondary: nil,
            creditBalance: nil,
            hasCredits: false
        )
        check(
            MenuBarQuotaIconModel.state(for: .loaded([menuBarBucket], statusNow)) == .ready(96),
            "menu bar quota ring reads the headline remainder"
        )
        check(
            MenuBarQuotaIconModel.state(for: .failed("offline", previous: [menuBarBucket])) == .ready(96),
            "menu bar quota ring preserves the last known remainder after failure"
        )
        check(
            MenuBarQuotaIconModel.state(for: .failed("offline", previous: [])) == .failed,
            "menu bar quota ring exposes a failure without cached quota"
        )
        check(
            MenuBarQuotaIconModel.state(for: .loading) == .loading,
            "menu bar quota ring exposes loading state"
        )
        check(MenuBarQuotaIconModel.progress(for: -20) == 0, "quota ring clamps low values")
        check(MenuBarQuotaIconModel.progress(for: 140) == 1, "quota ring clamps high values")
        let emptyRing = MenuBarQuotaRingRenderer.image(remainingPercent: 0)
        let partialRing = MenuBarQuotaRingRenderer.image(remainingPercent: 68)
        check(emptyRing.size == NSSize(width: 14, height: 14), "quota ring uses menu-bar dimensions")
        check(partialRing.isTemplate, "quota ring follows system menu-bar appearance")
        check(
            emptyRing.tiffRepresentation != partialRing.tiffRepresentation,
            "quota ring pixels change with remaining quota"
        )
        check(
            StatusItemCoexistencePolicy.usesIconOnlyMode(
                runningBundleIdentifiers: ["com.quotaview.menubar"]
            ),
            "QuotaView activates icon-only status coexistence"
        )
        check(
            !StatusItemCoexistencePolicy.usesIconOnlyMode(
                runningBundleIdentifiers: ["com.example.other"]
            ),
            "unrelated menu apps keep the normal status title"
        )
        check(
            StatusItemCoexistencePolicy.effectiveDensity(
                preference: .automatic,
                quotaViewIsRunning: true,
                availableWidth: 300
            ) == .iconOnly,
            "automatic density yields to QuotaView"
        )
        check(
            StatusItemCoexistencePolicy.effectiveDensity(
                preference: .automatic,
                quotaViewIsRunning: false,
                availableWidth: 220
            ) == .detailed,
            "automatic density keeps details when space is available"
        )
        check(
            StatusItemCoexistencePolicy.effectiveDensity(
                preference: .automatic,
                quotaViewIsRunning: false,
                availableWidth: 120
            ) == .compact,
            "automatic density compacts in a crowded menu bar"
        )
        check(
            StatusItemCoexistencePolicy.effectiveDensity(
                preference: .automatic,
                quotaViewIsRunning: false,
                availableWidth: 60
            ) == .iconOnly,
            "automatic density falls back to an icon in severe crowding"
        )
        check(
            MenuBarActivityFormatter.title(
                phase: .usingTool,
                projectName: "监控",
                actionSummary: "正在修改文件",
                projectCount: 3,
                quotaTitle: "90% 6天"
            ) == "工具 · 修改文件 · +2 · 90%",
            "menu bar activity uses one action focus plus parallel count and compact quota"
        )
        check(
            MenuBarActivityFormatter.title(
                phase: .working,
                projectName: "监控",
                actionSummary: "正在思考",
                projectCount: 1,
                quotaTitle: "90%"
            ) == "思考 · 监控 · 90%",
            "menu bar activity removes a duplicate phase action"
        )
        check(
            MenuBarActivityFormatter.tooltip(
                phase: .usingTool,
                projectName: "Codex额度监控macbook插件。",
                actionSummary: "正在修改 ParticleMetalOrb.swift\n同时：运行测试",
                projectCount: 2,
                quotaTitle: "90% 6天"
            ).contains("同时运行 2 个项目"),
            "menu bar tooltip preserves full task detail"
        )
        check(toolGlow.speed > workingGlow.speed, "tool glow moves faster than thinking glow")
        check(workingGlow.speed > idleGlow.speed, "working glow moves faster than idle glow")
        check(approvalGlow.speed < workingGlow.speed, "approval glow slows down to hold attention")
        check(failedGlow.accent.x > failedGlow.accent.y, "failed glow uses a red-orange accent")
        check(endedGlow.exposure < workingGlow.exposure, "ended glow settles to lower exposure")
        check(
            RippleGlowStyle.mix(idleGlow, toward: toolGlow, factor: 1) == toolGlow,
            "glow interpolation reaches its target"
        )

        check(HookEventMapper.phase(for: "PermissionRequest") == .waitingApproval, "approval mapping")
        check(HookEventMapper.phase(for: "Stop") == .completed, "completion mapping")
        check(HookEventMapper.phase(for: "PreToolUse") == .usingTool, "tool mapping")
        let commandInput = #"const r = await tools.exec_command({ cmd: "swift build && echo done", workdir: "/tmp" });"#
        let commandSummary = SessionActivityService.toolSummary(name: "exec", input: commandInput)
        check(
            commandSummary == "运行命令 · swift build && echo done",
            "command summary extraction"
        )
        let quotedCommandInput = #"const r = await tools.exec_command({"cmd":"./scripts/test.sh","workdir":"/tmp"});"#
        check(
            SessionActivityService.toolSummary(name: "exec", input: quotedCommandInput)
                == "运行命令 · ./scripts/test.sh",
            "quoted command key summary extraction"
        )
        let wrappedPatchInput = """
        const patch = "*** Update File: /tmp/ActivityIslandView.swift
        "; await tools.apply_patch(patch);
        """
        check(
            SessionActivityService.toolSummary(name: "exec", input: wrappedPatchInput)
                == "修改 · ActivityIslandView.swift",
            "wrapped patch extracts the changed file"
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
        let titledInput = #"await tools.mcp__node_repl__js({"title":"验证实时活动显示","code":"test"});"#
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
        let parallelActivity = SessionActivityItem(
            id: "parallel", kind: .command, title: "运行并行命令",
            isRunning: true, updatedAt: baseDate.addingTimeInterval(20)
        )
        let parallelProject = ActiveProjectState(
            id: "/tmp/ProjectA", name: "ProjectA", path: "/tmp/ProjectA",
            sessions: [], task: projects.last!.task,
            activities: [parallelActivity, newestActivity]
        )
        check(
            parallelProject.detailedActionSummary
                == "正在读取最新文件\n同时：正在运行并行命令",
            "activity island summary includes one parallel structured action"
        )

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
                && CoverAILinks.url(for: .appMenu)?.absoluteString.contains("utm_campaign=app_menu") == true,
            "remaining CoverAI entry points use their intended campaigns"
        )
        try? FileManager.default.removeItem(at: fixtureURL)

        print("Model smoke tests passed (101 checks).")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else {
            fputs("FAILED: \(label)\n", stderr)
            exit(1)
        }
    }
}
