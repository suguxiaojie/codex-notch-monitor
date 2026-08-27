import Foundation

@main
enum ContinuityTests {
    static func main() throws {
        if ProcessInfo.processInfo.environment["CONTINUITY_BENCHMARK"] == "1" {
            runLocalInventoryBenchmark()
            return
        }
        try accountObservationDoesNotGuessHistory()
        try accountTransitionTracksOnlyNewSessions()
        try usageAccountContextExposesOnlyObservedOwnership()
        try accountTimelinePersistsRepeatedSwitches()
        try emailSummaryIsRedactedAndBackwardCompatible()
        threadKindsFollowAppServerSourceSemantics()
        recoveryResultsClassifyZeroPartialAndCompleteOutcomes()
        threadDeleteUsesOfficialAppServerMethod()
        threadIndexRepairRetriesUntilRequiredIDsVisible()
        continuityCountsOnlyUserConversations()
        projectGroupsContainTheirConversations()
        try exactProjectBindingIsConservative()
        try accountStateWatcherTracksOnlyAccountFileMetadata()
        try sidebarCleanupIsExactAndRecoverable()
        try sidebarCleanupQueuesWhileCodexRuns()
        try responseItemMessagesAreRecognizedWithoutDuplicates()
        try largeThreadUsesBoundedHeadAndTailParsing()
        try readableSessionExportIsCompleteAndRedacted()
        try portableBundlePreservesActiveAndArchivedSessions()
        try sessionImportValidatesMapsSkipsAndRollsBack()
        try duplicateImportGeneratesNewThreadID()
        try damagedPortableBundleIsRejected()
        try importConflictMatrixIsCompleteAndRollbackRestoresResidue()
        try cancelledImportRollsBackCreatedSessions()
        try archiveSafetyLimitsAreEnforcedBeforeExtraction()
        try importedRolloutPathRepairIsRecoverable()
        try projectTransferP0ExportsImportsAndRollsBack()
        try projectTransferP1PreservesGitAndAttachments()
        try projectTransferLargeGitOutputDoesNotDeadlock()
        projectImportDirectoryDefaultsToCodexProjectsContainer()
        print("Continuity tests: 30/30 passed")
    }

    private static func runLocalInventoryBenchmark() {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let roots = [
            home.appendingPathComponent("sessions", isDirectory: true),
            home.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
        let files = roots.flatMap { root -> [URL] in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) else { return [] }
            return enumerator.compactMap { value in
                guard let url = value as? URL, url.pathExtension == "jsonl" else { return nil }
                return url
            }
        }
        let startedAt = Date()
        let envelopes = files.compactMap(SessionContinuityService.parseThreadEnvelope(at:))
        let bytesRead = envelopes.reduce(0) { $0 + $1.bytesRead }
        print(
            "Continuity benchmark: files=\(files.count), parsed=\(envelopes.count), "
                + "boundedBytes=\(bytesRead), elapsed=\(String(format: "%.3f", Date().timeIntervalSince(startedAt)))s"
        )
    }

    private static func projectImportDirectoryDefaultsToCodexProjectsContainer() {
        let projectsContainer = temporaryDirectory("project-import-container")
        let originalProject = projectsContainer.appendingPathComponent("OriginalProject", isDirectory: true)
        try! FileManager.default.createDirectory(at: originalProject, withIntermediateDirectories: true)
        let fallbackContainer = temporaryDirectory("project-import-fallback")
        let currentProject = fallbackContainer.appendingPathComponent("CurrentProject", isDirectory: true)
        try! FileManager.default.createDirectory(at: currentProject, withIntermediateDirectories: true)

        let preferred = ProjectTransferDirectoryDefaults.importContainerDirectory(
            originalProjectPath: originalProject.path,
            currentProjectDirectory: currentProject
        )
        expect(preferred == projectsContainer, "完整项目导入应默认打开原 Codex 项目所在的上级目录")

        let fallback = ProjectTransferDirectoryDefaults.importContainerDirectory(
            originalProjectPath: "/missing/codex-project",
            currentProjectDirectory: currentProject
        )
        expect(fallback == fallbackContainer, "原路径不可用时应回退到当前 Codex 项目所在的上级目录")
    }

    private static func threadKindsFollowAppServerSourceSemantics() {
        expect(
            CodexThreadService.continuitySourceKinds == ["vscode", "subAgent"],
            "盘点和恢复必须查询用户会话与 Subagent"
        )
        expect(
            SessionContinuityService.threadKind(
                source: ["subagent": ["other": "guardian"]],
                hasUserMessage: true
            ) == .subagent,
            "Guardian 即使带任务消息也必须归为内部线程"
        )
        expect(
            SessionContinuityService.threadKind(source: "vscode", hasUserMessage: false) == .system,
            "没有用户消息的 vscode 记录必须归为系统线程"
        )
        expect(
            SessionContinuityService.threadKind(source: "vscode", hasUserMessage: true) == .userConversation,
            "有用户消息的 vscode 记录应归为用户会话"
        )
        expect(
            SessionContinuityService.threadKind(
                source: "exec",
                originator: "codex_exec",
                hasUserMessage: true
            ) == .system,
            "OpenDesign Local Codex 执行线程即使有用户 Prompt 也必须归为内部系统线程"
        )
        expect(
            SessionContinuityService.threadKind(
                source: "exec",
                hasUserMessage: true
            ) == .system,
            "非交互 codex exec 线程不得计入待恢复用户会话"
        )
    }

    private static func recoveryResultsClassifyZeroPartialAndCompleteOutcomes() {
        let backupURL = URL(fileURLWithPath: "/tmp/continuity-backup")
        expect(
            SessionRecoveryResult(
                requestedCount: 1,
                recoveredCount: 0,
                projectBindingsAdded: 0,
                backupURL: backupURL
            ).completionState == .ineffective,
            "0 / N 恢复结果必须标记为未生效"
        )
        expect(
            SessionRecoveryResult(
                requestedCount: 2,
                recoveredCount: 1,
                projectBindingsAdded: 1,
                backupURL: backupURL
            ).completionState == .partial,
            "部分恢复必须显示警告而不是完整成功"
        )
        expect(
            SessionRecoveryResult(
                requestedCount: 2,
                recoveredCount: 2,
                projectBindingsAdded: 1,
                backupURL: backupURL
            ).completionState == .complete,
            "N / N 恢复结果才允许标记为完整成功"
        )
    }

    private static func threadDeleteUsesOfficialAppServerMethod() {
        var calls: [(method: String, params: [String: Any], timeout: TimeInterval)] = []
        var completed = false
        let service = CodexThreadService { method, params, timeout, completion in
            calls.append((method, params, timeout))
            if method == "thread/delete" {
                completion(.success([:]))
            } else {
                completion(.success(["data": []]))
            }
        }
        service.deleteThread(id: "thread-to-delete") { result in
            if case .success = result { completed = true }
        }

        let deleteCall = calls.first
        expect(deleteCall?.method == "thread/delete", "删除必须调用 Codex App Server thread/delete")
        expect(deleteCall?.params["threadId"] as? String == "thread-to-delete", "删除必须只传递目标 threadId")
        expect(deleteCall?.timeout == 20, "删除应使用独立请求超时")
        expect(calls.filter { $0.method == "thread/list" }.count == 2, "删除后必须复核活动与归档线程索引")
        expect(
            calls.filter { $0.method == "thread/list" }.allSatisfy {
                $0.params["useStateDbOnly"] as? Bool == true
            },
            "删除复核必须读取 Codex 当前状态数据库"
        )
        expect(completed, "Codex 索引确认不存在后才能返回成功")

        var archivedLoadedThread = false
        service.archiveThread(id: "loaded-thread") { result in
            if case .success = result { archivedLoadedThread = true }
        }
        let archiveCall = calls.last
        expect(archiveCall?.method == "thread/archive", "活动写入器应通过官方 thread/archive 释放")
        expect(archiveCall?.params["threadId"] as? String == "loaded-thread", "归档只能针对确认的目标线程")
        expect(archivedLoadedThread, "官方归档成功后应继续删除流程")

        var staleIndexWasRejected = false
        let staleService = CodexThreadService { method, _, _, completion in
            if method == "thread/delete" {
                completion(.success([:]))
            } else {
                completion(.success(["data": [["id": "thread-to-delete"]]]))
            }
        }
        staleService.deleteThread(id: "thread-to-delete") { result in
            if case let .failure(error) = result {
                staleIndexWasRejected = error.localizedDescription.contains("仍返回该会话")
            }
        }
        expect(staleIndexWasRejected, "Codex 仍返回目标线程时不得伪报删除成功")
    }

    private static func threadIndexRepairRetriesUntilRequiredIDsVisible() {
        var listCallCount = 0
        var completedIDs = Set<String>()
        let service = CodexThreadService { method, params, _, completion in
            guard method == "thread/list" else {
                completion(.success([:]))
                return
            }
            listCallCount += 1
            let archived = params["archived"] as? Bool == true
            if listCallCount >= 3, !archived {
                completion(.success(["data": [["id": "imported-thread"]]]))
            } else {
                completion(.success(["data": []]))
            }
        }
        service.rebuildThreadIndex(
            requiredThreadIDs: ["imported-thread"],
            maximumAttempts: 3,
            retryDelay: 0
        ) { result in
            if case let .success(ids) = result { completedIDs = ids }
        }
        expect(completedIDs.contains("imported-thread"), "首轮扫描只修复元数据时应自动再扫描")
        expect(listCallCount == 4, "目标会话第二轮可见后应停止重试")
    }

    private static func accountObservationDoesNotGuessHistory() throws {
        let store = makeStore("baseline")
        let info = account("owner@example.com", at: 1_800_000_000)
        let observation = try store.observe(account: info, localSessionIDs: ["historical"])

        expect(observation.account.alias == "账号 1", "首次账号别名")
        expect(observation.transition == nil, "首次观察不能被当作切号")
        expect(
            observation.ownershipByThread["historical"]?.confidence == .baseline,
            "历史会话应标记为基线前未记录"
        )
        expect(info.maskedEmail == "o***@example.com", "界面只能显示脱敏邮箱")
        expect(store.currentAccountAlias() == "账号 1", "初始化时应能立即显示上次确认的账号别名")
    }

    private static func continuityCountsOnlyUserConversations() {
        var user = record(id: "user", path: "/tmp/User")
        user.visibility = .localOnly
        user.ownership = .baseline
        var subagent = record(id: "subagent", path: "/tmp/User", kind: .subagent)
        subagent.visibility = .internalThread
        subagent.ownership = .baseline
        var system = record(id: "system", path: "/tmp/User", messages: [], kind: .system)
        system.visibility = .internalThread
        let snapshot = SessionContinuitySnapshot(
            threads: [user, subagent, system],
            unreadableFileCount: 0,
            checkedAt: Date()
        )

        expect(snapshot.sessionCount == 1, "会话总数不应包含内部线程")
        expect(snapshot.recoverableThreads.map(\.id) == ["user"], "只有用户会话可恢复")
        expect(!subagent.canRecover && !system.canRecover, "内部线程不得进入恢复")
        expect(snapshot.baselineOwnershipCount == 1, "内部线程不应计入基线前归属统计")
    }

    private static func projectGroupsContainTheirConversations() {
        let snapshot = SessionContinuitySnapshot(
            threads: [
                record(id: "project-a-1", path: "/tmp/ProjectA"),
                record(id: "project-a-2", path: "/tmp/ProjectA"),
                record(id: "project-b-1", path: "/tmp/ProjectB"),
                record(id: "internal", path: "/tmp/ProjectA", kind: .subagent),
            ],
            unreadableFileCount: 0,
            checkedAt: Date()
        )

        expect(snapshot.projectGroups.count == 2, "应按项目路径分组")
        expect(
            snapshot.projectGroups.first { $0.id == "/tmp/ProjectA" }?.threads.count == 2,
            "项目下应包含对应的用户对话"
        )
        expect(
            snapshot.projectGroups.flatMap(\.threads).allSatisfy { $0.kind == .userConversation },
            "项目分组不应包含内部线程"
        )
    }

    private static func accountTransitionTracksOnlyNewSessions() throws {
        let store = makeStore("transition")
        _ = try store.observe(
            account: account("first@example.com", at: 1_800_000_000),
            localSessionIDs: ["old"]
        )
        let firstNew = try store.observe(
            account: account("first@example.com", at: 1_800_000_100),
            localSessionIDs: ["old", "first-new"]
        )
        expect(
            firstNew.ownershipByThread["first-new"]?.accountAlias == "账号 1",
            "建立基线后新增会话应归属当前账号"
        )

        let switched = try store.observe(
            account: account("second@example.com", at: 1_800_000_200),
            localSessionIDs: ["old", "first-new", "second-new"]
        )
        expect(switched.transition?.previousAlias == "账号 1", "应记录切号前别名")
        expect(switched.transition?.currentAlias == "账号 2", "应记录切号后别名")
        expect(
            switched.ownershipByThread["second-new"]?.accountAlias == "账号 2",
            "切号后新增会话应归属新账号"
        )
    }

    private static func usageAccountContextExposesOnlyObservedOwnership() throws {
        let store = makeStore("usage-context")
        _ = try store.observe(
            account: account("first@example.com", at: 1_800_000_000),
            localSessionIDs: ["baseline"]
        )
        _ = try store.observe(
            account: account("first@example.com", at: 1_800_000_100),
            localSessionIDs: ["baseline", "account-1-session"]
        )
        _ = try store.observe(
            account: account("second@example.com", at: 1_800_000_200),
            localSessionIDs: ["baseline", "account-1-session", "account-2-session"]
        )
        let context = store.usageAccountContext()
        expect(context.accounts.map(\.alias) == ["账号 1", "账号 2"], "账号筛选应按别名稳定排序")
        expect(context.accounts.first(where: { $0.alias == "账号 2" })?.isCurrent == true, "当前账号标记")
        expect(context.accountIDByThread["baseline"] == nil, "基线前会话必须进入归属未知")
        expect(context.accountIDByThread["account-1-session"] == context.accounts[0].id, "账号 1 会话归属")
        expect(context.accountIDByThread["account-2-session"] == context.accounts[1].id, "账号 2 会话归属")
        expect(context.accounts[0].emailSummary == "fi***st@example.com", "账号筛选应暴露脱敏邮箱摘要")
        expect(context.accounts[1].emailSummary == "se***nd@example.com", "当前账号摘要")
    }

    private static func accountTimelinePersistsRepeatedSwitches() throws {
        let root = temporaryDirectory("account-timeline")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("account-continuity.json")
        let store = AccountContinuityStore(stateURL: stateURL)

        _ = try store.observe(
            account: account("first@example.com", at: 1_800_000_000),
            localSessionIDs: ["existing"]
        )
        _ = try store.observe(
            account: account("first@example.com", at: 1_800_000_050),
            localSessionIDs: ["existing"]
        )
        _ = try store.observe(
            account: account("second@example.com", at: 1_800_000_100),
            localSessionIDs: ["existing"]
        )
        _ = try store.observe(
            account: account("first@example.com", at: 1_800_000_200),
            localSessionIDs: ["existing"]
        )

        let context = store.usageAccountContext()
        let account1 = context.accounts.first(where: { $0.alias == "账号 1" })!.id
        let account2 = context.accounts.first(where: { $0.alias == "账号 2" })!.id
        expect(context.accountTimeline.map(\.accountID) == [account1, account2, account1], "重复切号应形成有序账号时间线")
        expect(
            context.accountTimeline.map(\.startsAt) == [
                Date(timeIntervalSince1970: 1_800_000_000),
                Date(timeIntervalSince1970: 1_800_000_100),
                Date(timeIntervalSince1970: 1_800_000_200),
            ],
            "账号时间线应保留可靠观察时间"
        )

        let reloaded = AccountContinuityStore(stateURL: stateURL).usageAccountContext()
        expect(reloaded.accountTimeline == context.accountTimeline, "应用重启后账号时间线应完整恢复")
        expect(
            context.accountID(for: "existing", at: Date(timeIntervalSince1970: 1_800_000_150)) == account2,
            "既有会话切号后的事件应按时间归入新账号"
        )
    }

    private static func emailSummaryIsRedactedAndBackwardCompatible() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("email-summary-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        let stateURL = root.appendingPathComponent("account-continuity.json")
        let store = AccountContinuityStore(stateURL: stateURL)
        _ = try store.observe(
            account: account("owner@example.com", at: 1_800_000_000),
            localSessionIDs: []
        )
        let persisted = try String(contentsOf: stateURL, encoding: .utf8)
        expect(persisted.contains("ow***er@example.com"), "状态文件应保存脱敏邮箱摘要")
        expect(!persisted.contains("owner@example.com"), "状态文件不得保存完整邮箱")
        expect(store.usageAccountContext().accounts.first?.emailSummary == "ow***er@example.com", "摘要应供账号菜单使用")
        expect(CodexAccountInfo.summarize(email: "ab@example.com") == "a***b@example.com", "短邮箱本地部分也要脱敏")

        let legacyURL = root.appendingPathComponent("legacy-account-continuity.json")
        let legacy = """
        {
          "version": 1,
          "salt": "legacy-salt",
          "currentAccountFingerprint": "legacy-fingerprint",
          "accounts": {
            "legacy-fingerprint": {
              "alias": "账号 1",
              "firstSeenAt": "2027-01-15T08:00:00Z",
              "lastSeenAt": "2027-01-15T08:00:00Z"
            }
          },
          "knownSessionIDs": [],
          "sessionOwnership": {}
        }
        """
        try Data(legacy.utf8).write(to: legacyURL)
        let legacyStore = AccountContinuityStore(stateURL: legacyURL)
        let legacyAccount = legacyStore.usageAccountContext().accounts.first
        expect(legacyAccount?.alias == "账号 1", "旧状态文件仍应正常读取")
        expect(legacyAccount?.emailSummary == nil, "旧账号在再次观察前应显示邮箱待记录")
        expect(legacyStore.usageAccountContext().accountTimeline.isEmpty, "旧状态在首次可靠观察前不应猜测时间线")
    }

    private static func readableSessionExportIsCompleteAndRedacted() throws {
        let root = temporaryDirectory("readable-export")
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appendingPathComponent("rollout-readable.jsonl")
        var events: [[String: Any]] = [[
            "timestamp": "2026-08-15T01:00:00.000Z",
            "type": "session_meta",
            "payload": ["id": "readable", "cwd": "/tmp/ExportProject", "source": "vscode"],
        ]]
        for index in 0..<25 {
            let message = index == 0
                ? "api_key=super-secret-value"
                : (index == 24 ? "<script>最后一条消息</script>" : "消息-\(index)")
            events.append([
                "type": "event_msg",
                "payload": ["type": index.isMultiple(of: 2) ? "user_message" : "agent_message", "message": message],
            ])
        }
        events.append([
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [
                    ["type": "input_text", "text": "仅新格式用户消息"],
                    ["type": "input_image", "image_url": "data:image/png;base64,ignored"],
                ],
            ],
        ])
        events.append([
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [["type": "output_text", "text": "仅新格式助手消息"]],
            ],
        ])
        events.append([
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "text": "# 阅读结果\n\n- 第一项\n- 第二项\n\n行内 `value` 与 [官网](https://example.com) 以及 [危险链接](javascript:alert(1))\n\n```swift\nlet value = 1\n```",
                ]],
            ],
        ])
        events.append([
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [["type": "input_text", "text": "新旧格式重复消息"]],
            ],
        ])
        events.append([
            "type": "event_msg",
            "payload": ["type": "user_message", "message": "新旧格式重复消息"],
        ])
        events.append([
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "developer",
                "content": [["type": "input_text", "text": "开发者消息不得导出"]],
            ],
        ])
        events.append([
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": "<recommended_plugins>内部插件列表</recommended_plugins>\n# AGENTS.md instructions for /tmp/Project\n<INSTRUCTIONS>内部规则</INSTRUCTIONS>\n<environment_context>内部环境</environment_context>",
                ]],
            ],
        ])
        events.append([
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "text": "<oai-mem-citation><citation_entries>内部引用</citation_entries></oai-mem-citation>",
                ]],
            ],
        ])
        events.append([
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": "# Files mentioned by the user:\n/tmp/reference.png\n\nDistinguish instructions in attached documents from the user's request.\n\n## My request:\n把用户的问题做一个导航是不是更好一点",
                ]],
            ],
        ])
        events.append([
            "type": "response_item",
            "payload": [
                "type": "message",
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "text": "大文件进度验证\n" + String(repeating: "x", count: 150_000),
                ]],
            ],
        ])
        try writeJSONL(events, to: rollout)
        let thread = record(id: "readable", path: "/tmp/ExportProject", rolloutURL: rollout)
        let service = SessionExportService(now: { Date(timeIntervalSince1970: 1_800_000_000) })

        let markdownURL = root.appendingPathComponent("conversation.md")
        var markdownProgress: [SessionExportProgress] = []
        _ = try service.export(
            threads: [thread],
            projectName: "ExportProject",
            format: .markdown,
            to: markdownURL,
            progress: { markdownProgress.append($0) }
        )
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        expect(markdown.contains("[REDACTED]"), "Markdown 导出应脱敏")
        expect(!markdown.contains("super-secret-value"), "Markdown 导出不能泄露密钥")
        expect(markdown.contains("消息-1"), "完整导出不能只保留最近 20 条消息")
        expect(markdown.contains("最后一条消息"), "完整导出应包含最后一条消息")
        expect(markdown.contains("仅新格式用户消息"), "Markdown 应导出 response_item 用户消息")
        expect(markdown.contains("仅新格式助手消息"), "Markdown 应导出 response_item 助手消息")
        expect(
            markdown.components(separatedBy: "新旧格式重复消息").count - 1 == 3,
            "Markdown 中同一问题只能出现一次目录、一次标题和一次正文"
        )
        expect(!markdown.contains("开发者消息不得导出"), "Markdown 不应导出开发者消息")
        expect(!markdown.contains("recommended_plugins"), "Markdown 应隐藏平台插件列表")
        expect(!markdown.contains("AGENTS.md instructions"), "Markdown 应隐藏 AGENTS 注入内容")
        expect(!markdown.contains("environment_context"), "Markdown 应隐藏运行环境")
        expect(!markdown.contains("oai-mem-citation"), "Markdown 应隐藏内部引用元数据")
        expect(!markdown.contains("/tmp/reference.png"), "Markdown 应隐藏附件临时路径")
        expect(markdown.contains("### 用户问题目录"), "Markdown 应生成用户问题目录")
        expect(markdown.contains("### 问题 1："), "Markdown 应按用户问题分轮")
        expect(markdown.contains("#### Codex 最终回复"), "Markdown 应标记同一轮的最终回复")
        expect(markdown.contains("[返回问题目录]"), "Markdown 应提供返回目录链接")
        expect(markdownProgress.first?.completed == 0, "Markdown 导出应从 0 开始报告进度")
        let readingProgress = markdownProgress.filter { $0.stage == .reading }
        expect(readingProgress.first?.processedBytes == 0, "单会话读取进度应从 0 字节开始")
        expect(
            readingProgress.contains {
                guard let processed = $0.processedBytes, let total = $0.totalBytes else { return false }
                return processed > 0 && processed < total
            },
            "单条大会话应报告中间字节进度"
        )
        expect(markdownProgress.contains { $0.stage == .processing }, "Markdown 应报告清理脱敏阶段")
        expect(markdownProgress.contains { $0.stage == .rendering }, "Markdown 应报告文档生成阶段")
        expect(markdownProgress.contains { $0.stage == .writing }, "Markdown 应报告文件写入阶段")
        expect(markdownProgress.last?.stage == .completed, "Markdown 应报告完成阶段")
        expect(markdownProgress.last?.fraction == 1, "Markdown 完成进度应为 100%")
        expect(
            zip(markdownProgress, markdownProgress.dropFirst()).allSatisfy { $0.fraction <= $1.fraction },
            "单会话总体进度必须单调递增"
        )

        let htmlURL = root.appendingPathComponent("conversation.html")
        _ = try service.export(
            threads: [thread],
            projectName: "ExportProject",
            format: .html,
            to: htmlURL
        )
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        expect(html.contains("&lt;script&gt;最后一条消息&lt;/script&gt;"), "HTML 导出必须转义消息内容")
        expect(!html.contains("<script>最后一条消息</script>"), "HTML 导出不能注入消息标签")
        expect(html.contains("仅新格式用户消息"), "HTML 应导出 response_item 用户消息")
        expect(html.contains("仅新格式助手消息"), "HTML 应导出 response_item 助手消息")
        expect(
            html.components(separatedBy: "新旧格式重复消息").count - 1 == 4,
            "HTML 中同一用户消息只能出现一次正文、一次问题标题，以及一组导航标题和标签"
        )
        expect(!html.contains("开发者消息不得导出"), "HTML 不应导出开发者消息")
        expect(!html.contains("recommended_plugins"), "HTML 应隐藏平台插件列表")
        expect(!html.contains("AGENTS.md instructions"), "HTML 应隐藏 AGENTS 注入内容")
        expect(!html.contains("environment_context"), "HTML 应隐藏运行环境")
        expect(!html.contains("oai-mem-citation"), "HTML 应隐藏内部引用元数据")
        expect(!html.contains("/tmp/reference.png"), "HTML 应隐藏附件临时路径")
        expect(html.contains("<h1>阅读结果</h1>"), "HTML 应渲染 Markdown 标题")
        expect(html.contains("<ul><li>第一项</li><li>第二项</li></ul>"), "HTML 应渲染 Markdown 列表")
        expect(html.contains("<code>value</code>"), "HTML 应渲染行内代码")
        expect(html.contains("class=\"code-block\""), "HTML 应渲染围栏代码块")
        expect(html.contains("href=\"https://example.com\""), "HTML 应生成安全链接")
        expect(!html.contains("href=\"javascript:"), "HTML 必须拒绝脚本链接")
        expect(html.contains("id=\"search\""), "HTML 应包含离线搜索框")
        expect(html.contains("class=\"toc\""), "HTML 应包含会话目录")
        expect(html.contains("class=\"question-section\""), "HTML 应按用户问题生成阅读单元")
        expect(html.contains("class=\"user-prompt\""), "HTML 问题单元应包含用户问题")
        expect(html.contains("class=\"final-response\""), "HTML 问题单元应突出最终回复")
        expect(html.contains("<details class=\"process-group\">"), "HTML 过程更新应默认折叠")
        expect(!html.contains("<details class=\"process-group\" open>"), "HTML 过程更新不得默认展开")
        expect(html.contains("class=\"question-link\""), "HTML 应包含用户问题导航")
        expect(html.contains("<details class=\"question-group\" open>"), "HTML 应按问题区间折叠目录")
        expect(html.contains("问题 1–"), "HTML 目录分组应显示问题范围")
        expect(
            html.contains("<span>把用户的问题做一个导航是不是更好一点</span>"),
            "问题导航应优先提取 My request 正文"
        )
        expect(!html.contains("title=\"# Files mentioned by the user"), "问题导航不得使用附件说明作为标题")
        expect(!html.contains("class=\"message-index\""), "HTML 不应继续显示原始消息序号")
        expect(html.contains("new IntersectionObserver"), "问题导航应跟随正文滚动高亮")
        expect(html.contains("aria-current', 'location'"), "当前问题导航应设置 aria-current")
        expect(html.contains("classList.add('flash')"), "点击问题导航应高亮目标消息")
        expect(html.contains("link.hidden = !!term"), "搜索应同步过滤问题导航")
        expect(html.contains("<label class=\"search-label\" for=\"search\">"), "搜索框应有可访问标签")
        expect(html.contains("aria-live=\"polite\""), "搜索与当前位置变化应通过 aria-live 播报")
        expect(html.contains("id=\"search-prev\""), "HTML 搜索应支持上一条结果")
        expect(html.contains("id=\"search-next\""), "HTML 搜索应支持下一条结果")
        expect(html.contains("id=\"search-clear\""), "HTML 搜索应支持清除")
        expect(html.contains("mark.className = 'search-hit'"), "HTML 搜索应高亮关键词")
        expect(html.contains("个问题 · ${occurrences} 处匹配"), "HTML 搜索应显示结果数量")
    }

    private static func portableBundlePreservesActiveAndArchivedSessions() throws {
        let root = temporaryDirectory("portable-bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let activeURL = root.appendingPathComponent("rollout-active.jsonl")
        let archivedURL = root.appendingPathComponent("rollout-archived.jsonl")
        try writeJSONL([[
            "type": "session_meta",
            "payload": ["id": "active", "cwd": "/tmp/BundleProject", "source": "vscode"],
        ]], to: activeURL)
        try writeJSONL([[
            "type": "session_meta",
            "payload": ["id": "archived", "cwd": "/tmp/BundleProject", "source": "vscode"],
        ]], to: archivedURL)
        let observedOwnership = SessionOwnership(
            accountFingerprint: "must-not-export",
            accountAlias: "账号 2",
            confidence: .observed
        )
        let active = record(
            id: "active",
            path: "/tmp/BundleProject",
            rolloutURL: activeURL,
            ownership: observedOwnership
        )
        let archived = record(
            id: "archived",
            path: "/tmp/BundleProject",
            rolloutURL: archivedURL,
            isArchived: true
        )
        let output = root.appendingPathComponent("project.codexmonitorbundle")
        var portableProgress: [SessionExportProgress] = []
        _ = try SessionExportService(now: { Date(timeIntervalSince1970: 1_800_000_000) }).export(
            threads: [active, archived],
            projectName: "BundleProject",
            format: .portableBundle,
            to: output,
            progress: { portableProgress.append($0) }
        )
        expect(portableProgress.first?.completed == 0, "原始备份应从 0 开始报告进度")
        expect(portableProgress.last?.completed == 2, "原始备份应报告全部会话完成")
        expect(portableProgress.contains { $0.stage == .compressing }, "原始备份应报告压缩阶段")
        expect(portableProgress.last?.stage == .completed, "原始备份应报告完成阶段")

        let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", output.path, unpacked.path]
        try process.run()
        process.waitUntilExit()
        expect(process.terminationStatus == 0, "可恢复备份应是有效 ZIP")

        let manifestData = try Data(contentsOf: unpacked.appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: manifestData) as! [String: Any]
        let sessions = manifest["sessions"] as! [[String: Any]]
        expect(manifest["format"] as? String == "codex-notch-session/v1", "备份包应声明格式版本")
        expect(sessions.count == 2, "项目备份应包含活动与归档会话")
        expect(sessions.contains { $0["archived"] as? Bool == true }, "归档状态必须保留")
        expect(sessions.contains { $0["ownershipAlias"] as? String == "账号 2" }, "可靠账号别名可以作为观察元数据")
        let manifestText = String(data: manifestData, encoding: .utf8) ?? ""
        expect(!manifestText.contains("must-not-export"), "账号指纹不得进入导出包")

        let checksumsData = try Data(contentsOf: unpacked.appendingPathComponent("checksums.json"))
        let checksums = try JSONSerialization.jsonObject(with: checksumsData) as! [String: Any]
        let files = checksums["files"] as! [String: String]
        expect(files["manifest.json"] != nil, "校验清单应包含 manifest")
        expect(files["README.txt"] != nil, "校验清单应覆盖隐私说明")
        expect(files.keys.contains("sessions/active/rollout-active.jsonl"), "校验清单应包含活动会话")
        expect(files.keys.contains("sessions/archived/rollout-archived.jsonl"), "校验清单应包含归档会话")
    }

    private static func sessionImportValidatesMapsSkipsAndRollsBack() throws {
        let root = temporaryDirectory("safe-import")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let mappedProject = root.appendingPathComponent("MappedProject", isDirectory: true)
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mappedProject, withIntermediateDirectories: true)
        let originalPath = root.appendingPathComponent("MissingProject").path
        let bundle = try makePortableBundle(
            root: source,
            projectPath: originalPath,
            sessions: [("existing-thread", false), ("archived-thread", true)]
        )

        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let existingURL = codexHome
            .appendingPathComponent("sessions/2026/08/15", isDirectory: true)
            .appendingPathComponent("existing.jsonl")
        try FileManager.default.createDirectory(
            at: existingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeThreadJSONL(id: "existing-thread", cwd: mappedProject.path, to: existingURL)
        let stateURL = codexHome.appendingPathComponent(".codex-global-state.json")
        let originalState = try JSONSerialization.data(withJSONObject: [
            "local-projects": [
                "mapped": ["id": "mapped", "rootPaths": [mappedProject.path]],
            ],
            "thread-project-assignments": [:],
        ], options: [.prettyPrinted, .sortedKeys])
        try originalState.write(to: stateURL, options: .atomic)

        let service = SessionImportService(
            homeDirectory: home,
            backupRoot: backups,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            codexIsRunning: { false }
        )
        let preview = try service.inspect(bundleURL: bundle, existingThreadIDs: ["existing-thread"])
        expect(preview.sessionCount == 2, "导入预览应统计全部会话")
        expect(preview.activeCount == 1 && preview.archivedCount == 1, "导入预览应区分活动与归档")
        expect(preview.duplicateCount == 1, "导入预览应识别重复 ID")
        expect(preview.requiresPathMapping, "原项目不存在时应要求路径映射")

        let result = try service.importBundle(
            preview: preview,
            mappedProjectURL: mappedProject,
            duplicateStrategy: .skip
        )
        expect(result.importedCount == 1, "默认导入应跳过重复会话")
        expect(result.skippedDuplicateCount == 1, "结果应报告跳过数")
        expect(result.projectBindingsAdded == 1, "精确映射的项目应补充绑定")
        let imported = try findThread(id: "archived-thread", under: codexHome)
        expect(imported?.originalPath == mappedProject.path, "导入会话应改写为新项目路径")

        try service.rollbackImport(at: result.backupURL)
        let archivedAfterRollback = try findThread(id: "archived-thread", under: codexHome)
        let existingAfterRollback = try findThread(id: "existing-thread", under: codexHome)
        let stateAfterRollback = try Data(contentsOf: stateURL)
        expect(archivedAfterRollback == nil, "撤销应移除本次新建会话")
        expect(existingAfterRollback != nil, "撤销不得移除原有会话")
        expect(stateAfterRollback == originalState, "撤销应恢复导入前项目状态")
    }

    private static func duplicateImportGeneratesNewThreadID() throws {
        let root = temporaryDirectory("duplicate-import")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let destinationProject = root.appendingPathComponent("SelectedProject", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationProject, withIntermediateDirectories: true)
        let bundle = try makePortableBundle(
            root: root.appendingPathComponent("source", isDirectory: true),
            projectPath: project.path,
            sessions: [("duplicate-thread", false), ("fresh-thread", false)]
        )
        let existingURL = home.appendingPathComponent(".codex/sessions/existing.jsonl")
        try FileManager.default.createDirectory(at: existingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeThreadJSONL(id: "duplicate-thread", cwd: project.path, to: existingURL)

        let service = SessionImportService(
            homeDirectory: home,
            backupRoot: root.appendingPathComponent("backups"),
            codexIsRunning: { false }
        )
        let preview = try service.inspect(bundleURL: bundle, existingThreadIDs: ["duplicate-thread"])
        let result = try service.importBundle(
            preview: preview,
            mappedProjectURL: destinationProject,
            duplicateStrategy: .duplicate
        )
        expect(result.importedCount == 2 && result.skippedDuplicateCount == 0, "副本策略应导入全部会话")
        expect(!result.importedThreadIDs.contains("duplicate-thread"), "重复会话必须生成新 ID")
        expect(!result.importedThreadIDs.contains("fresh-thread"), "全部作为副本时，非重复会话也必须生成新 ID")
        let allGeneratedThreadsExist = try result.importedThreadIDs.allSatisfy {
            try findThread(id: $0, under: home.appendingPathComponent(".codex")) != nil
        }
        expect(
            allGeneratedThreadsExist,
            "JSONL 中应写入每个新 ID"
        )
        let selectedDestinationWasUsed = try result.importedThreadIDs.allSatisfy {
            try findThread(id: $0, under: home.appendingPathComponent(".codex"))?.originalPath
                == destinationProject.path
        }
        expect(selectedDestinationWasUsed, "用户选择的目标项目必须优先于备份原路径")
    }

    private static func damagedPortableBundleIsRejected() throws {
        let root = temporaryDirectory("damaged-import")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let bundle = try makePortableBundle(
            root: root.appendingPathComponent("source", isDirectory: true),
            projectPath: project.path,
            sessions: [("damaged-thread", false)]
        )
        let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try runProcess("/usr/bin/ditto", ["-x", "-k", bundle.path, unpacked.path])
        let rollout = unpacked.appendingPathComponent("sessions/active/rollout-damaged-thread.jsonl")
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tampered\n".utf8))
        try handle.close()
        let damaged = root.appendingPathComponent("damaged.codexmonitorbundle")
        try runProcess("/usr/bin/ditto", ["-c", "-k", "--norsrc", unpacked.path, damaged.path])
        let service = SessionImportService(
            homeDirectory: root.appendingPathComponent("home"),
            backupRoot: root.appendingPathComponent("backups"),
            codexIsRunning: { false }
        )
        do {
            _ = try service.inspect(bundleURL: damaged, existingThreadIDs: [])
            expect(false, "被篡改的会话备份必须被拒绝")
        } catch {
            expect(error.localizedDescription.contains("校验失败"), "损坏包应给出完整性错误")
        }
    }

    private static func importConflictMatrixIsCompleteAndRollbackRestoresResidue() throws {
        let root = temporaryDirectory("import-conflict-matrix")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let pendingURL = root.appendingPathComponent("support/pending-sidebar-cleanups.json")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let bundle = try makePortableBundle(
            root: root.appendingPathComponent("source", isDirectory: true),
            projectPath: project.path,
            sessions: [
                ("jsonl-thread", false),
                ("state-thread", false),
                ("stale-thread", false),
                ("clean-thread", true),
            ]
        )
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let existingURL = codexHome.appendingPathComponent("sessions/existing.jsonl")
        try FileManager.default.createDirectory(at: existingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeThreadJSONL(id: "jsonl-thread", cwd: project.path, to: existingURL)

        let stateURL = codexHome.appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try runProcess("/usr/bin/sqlite3", [
            stateURL.path,
            "CREATE TABLE threads (id TEXT PRIMARY KEY); INSERT INTO threads VALUES ('state-thread');",
        ])
        let catalogURL = codexHome.appendingPathComponent("sqlite/codex-dev.db")
        try FileManager.default.createDirectory(at: catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try runProcess("/usr/bin/sqlite3", [
            catalogURL.path,
            "CREATE TABLE local_thread_catalog (host_id TEXT NOT NULL, thread_id TEXT NOT NULL, display_title TEXT NOT NULL, PRIMARY KEY (host_id, thread_id)); CREATE TABLE local_thread_catalog_metadata (id INTEGER PRIMARY KEY, catalog_revision INTEGER NOT NULL); INSERT INTO local_thread_catalog VALUES ('local','stale-thread','残留会话'); INSERT INTO local_thread_catalog_metadata VALUES (1,1);",
        ])
        let globalStateURL = codexHome.appendingPathComponent(".codex-global-state.json")
        let globalState: [String: Any] = [
            "local-projects": [
                "project": ["id": "project", "rootPaths": [project.path]],
            ],
            "thread-project-assignments": [
                "stale-thread": ["projectKind": "local", "projectId": "project", "cwd": project.path],
            ],
            "electron-persisted-atom-state": [
                "heartbeat-thread-permissions-by-id": [
                    "stale-thread": ["approvalPolicy": "never"],
                ],
            ],
        ]
        let originalGlobalState = try JSONSerialization.data(withJSONObject: globalState, options: [.sortedKeys])
        try originalGlobalState.write(to: globalStateURL, options: .atomic)
        let pending = [PendingCodexSidebarCleanup(
            threadID: "stale-thread",
            title: "残留会话",
            requestedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )]
        try FileManager.default.createDirectory(at: pendingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pendingEncoder = JSONEncoder()
        pendingEncoder.dateEncodingStrategy = .iso8601
        let originalPending = try pendingEncoder.encode(pending)
        try originalPending.write(to: pendingURL, options: .atomic)

        let service = SessionImportService(
            homeDirectory: home,
            backupRoot: backupRoot,
            pendingCleanupURL: pendingURL,
            codexIsRunning: { false }
        )
        let preview = try service.inspect(bundleURL: bundle, existingThreadIDs: ["jsonl-thread"])
        let byID = Dictionary(uniqueKeysWithValues: preview.conflicts.map { ($0.threadID, $0) })
        expect(byID["jsonl-thread"]?.jsonlExists == true, "冲突矩阵应识别 JSONL 会话")
        expect(byID["state-thread"]?.stateDatabaseExists == true, "冲突矩阵应识别 state_5 会话")
        expect(byID["stale-thread"]?.catalogExists == true, "冲突矩阵应识别本地线程目录残留")
        expect(byID["stale-thread"]?.projectBindingExists == true, "冲突矩阵应识别项目绑定残留")
        expect(byID["stale-thread"]?.permissionPreferenceExists == true, "冲突矩阵应识别权限残留")
        expect(byID["stale-thread"]?.pendingCleanupExists == true, "冲突矩阵应识别待清理队列")
        expect(preview.duplicateCount == 2 && preview.conflictCount == 3, "预览应区分已存在会话与索引残留")

        let result = try service.importBundle(
            preview: preview,
            mappedProjectURL: nil,
            duplicateStrategy: .skip
        )
        expect(result.importedCount == 2 && result.skippedDuplicateCount == 2, "原 ID 策略应跳过真重复并恢复残留 ID")
        let catalogCountAfterImport = try sqliteValue(at: catalogURL, sql: "SELECT COUNT(*) FROM local_thread_catalog WHERE thread_id='stale-thread';")
        expect(catalogCountAfterImport == "0", "恢复原 ID 前应清理目录残留")
        let pendingAfterImport = try Data(contentsOf: pendingURL)
        let decodedPending = try pendingEncoder.encode([PendingCodexSidebarCleanup]())
        let pendingObjects = try JSONSerialization.jsonObject(with: pendingAfterImport) as? [[String: Any]]
        expect(pendingObjects?.isEmpty == true && !decodedPending.isEmpty, "恢复原 ID 应取消待清理墓碑")
        let staleThreadAfterImport = try findThread(id: "stale-thread", under: codexHome)
        expect(staleThreadAfterImport != nil, "残留 ID 应恢复为可读会话")

        try service.rollbackImport(at: result.backupURL)
        let staleThreadAfterRollback = try findThread(id: "stale-thread", under: codexHome)
        let catalogCountAfterRollback = try sqliteValue(at: catalogURL, sql: "SELECT COUNT(*) FROM local_thread_catalog WHERE thread_id='stale-thread';")
        let pendingAfterRollback = try Data(contentsOf: pendingURL)
        let globalStateAfterRollback = try Data(contentsOf: globalStateURL)
        expect(staleThreadAfterRollback == nil, "回滚应移除新恢复的会话文件")
        expect(catalogCountAfterRollback == "1", "回滚应恢复线程目录")
        expect(pendingAfterRollback == originalPending, "回滚应恢复待清理队列")
        expect(globalStateAfterRollback == originalGlobalState, "回滚应恢复全局项目和权限状态")
    }

    private static func cancelledImportRollsBackCreatedSessions() throws {
        let root = temporaryDirectory("cancelled-import")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let bundle = try makePortableBundle(
            root: root.appendingPathComponent("source", isDirectory: true),
            projectPath: project.path,
            sessions: [("cancel-a", false), ("cancel-b", false)]
        )
        let service = SessionImportService(
            homeDirectory: home,
            backupRoot: root.appendingPathComponent("backups"),
            pendingCleanupURL: root.appendingPathComponent("support/pending.json"),
            codexIsRunning: { false }
        )
        let preview = try service.inspect(bundleURL: bundle, existingThreadIDs: [])
        var shouldCancel = false
        do {
            _ = try service.importBundle(
                preview: preview,
                mappedProjectURL: nil,
                duplicateStrategy: .skip,
                progress: { progress in
                    if progress.stage == .importing && progress.completed == 1 { shouldCancel = true }
                },
                isCancelled: { shouldCancel }
            )
            expect(false, "取消导入应返回取消错误")
        } catch {
            expect(error.localizedDescription.contains("已取消"), "取消应给出明确状态")
        }
        let codexHome = home.appendingPathComponent(".codex")
        let firstAfterCancel = try findThread(id: "cancel-a", under: codexHome)
        let secondAfterCancel = try findThread(id: "cancel-b", under: codexHome)
        expect(firstAfterCancel == nil, "取消后不得留下已写入的第一条会话")
        expect(secondAfterCancel == nil, "取消后不得留下未完成会话")
    }

    private static func archiveSafetyLimitsAreEnforcedBeforeExtraction() throws {
        let root = temporaryDirectory("archive-limits")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let bundle = try makePortableBundle(
            root: root.appendingPathComponent("source", isDirectory: true),
            projectPath: project.path,
            sessions: [("limited-thread", false)]
        )
        var limits = SessionImportLimits()
        limits.maximumEntries = 1
        let service = SessionImportService(
            homeDirectory: root.appendingPathComponent("home"),
            backupRoot: root.appendingPathComponent("backups"),
            limits: limits,
            codexIsRunning: { false }
        )
        do {
            _ = try service.inspect(bundleURL: bundle, existingThreadIDs: [])
            expect(false, "超过条目上限的备份包必须在解压前拒绝")
        } catch {
            expect(error.localizedDescription.contains("文件数过多"), "压缩包限制应返回明确原因")
        }
    }

    private static func importedRolloutPathRepairIsRecoverable() throws {
        let root = temporaryDirectory("rollout-path-repair")
        defer { try? FileManager.default.removeItem(at: root) }
        let threadID = "repair-thread"
        let originalURL = root.appendingPathComponent("rollout-import-杂项-\(threadID).jsonl")
        try writeThreadJSONL(id: threadID, cwd: "/tmp/Project", to: originalURL)
        let thread = record(
            id: threadID,
            path: "/tmp/Project",
            rolloutURL: originalURL
        )
        let service = ImportedRolloutPathRepairService(
            backupRoot: root.appendingPathComponent("backups"),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        guard let repair = try service.prepareForDeletion(thread) else {
            expect(false, "旧版 rollout-import 文件必须进入兼容修复")
            return
        }
        expect(!FileManager.default.fileExists(atPath: originalURL.path), "修复后旧文件名应移除")
        expect(FileManager.default.fileExists(atPath: repair.repairedURL.path), "修复后应生成标准 rollout 文件")
        expect(FileManager.default.fileExists(atPath: repair.backupURL.path), "修复文件名前必须备份原 JSONL")
        expect(
            repair.repairedURL.lastPathComponent.hasPrefix("rollout-2026-08-15T01-00-00-"),
            "标准文件名应使用会话时间和线程 ID"
        )
        expect(!repair.repairedURL.lastPathComponent.contains("杂项"), "标准 rollout 文件名不得包含项目名")
        try service.rollback(repair)
        expect(FileManager.default.fileExists(atPath: originalURL.path), "索引修复失败时应能恢复旧路径")
        expect(!FileManager.default.fileExists(atPath: repair.repairedURL.path), "回滚后不得留下双份 rollout")
    }

    private static func projectTransferP0ExportsImportsAndRollsBack() throws {
        let root = temporaryDirectory("project-transfer-p0")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceProject = root.appendingPathComponent("SourceProject", isDirectory: true)
        let targetProject = root.appendingPathComponent("TargetProject", isDirectory: true)
        let nonEmptyTarget = root.appendingPathComponent("ExistingProject", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let rollout = root.appendingPathComponent("rollout-project-thread.jsonl")
        try FileManager.default.createDirectory(
            at: sourceProject.appendingPathComponent("Sources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sourceProject.appendingPathComponent("node_modules/pkg", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sourceProject.appendingPathComponent("uploads", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sourceProject.appendingPathComponent("CoverAI-deployment-package-old", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: targetProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nonEmptyTarget, withIntermediateDirectories: true)
        try Data("print(\"hello\")".utf8).write(
            to: sourceProject.appendingPathComponent("Sources/main.swift")
        )
        try Data("# Project Rules".utf8).write(
            to: sourceProject.appendingPathComponent("AGENTS.md")
        )
        try Data("中文文件名应兼容".utf8).write(
            to: sourceProject.appendingPathComponent("运维修复记录.md")
        )
        try Data("SECRET=value".utf8).write(
            to: sourceProject.appendingPathComponent(".env")
        )
        try Data("database".utf8).write(
            to: sourceProject.appendingPathComponent("data.sqlite")
        )
        try Data("dependency".utf8).write(
            to: sourceProject.appendingPathComponent("node_modules/pkg/index.js")
        )
        try Data("upload".utf8).write(
            to: sourceProject.appendingPathComponent("uploads/private.txt")
        )
        try Data("deployment".utf8).write(
            to: sourceProject.appendingPathComponent("CoverAI-deployment-package-old/file.txt")
        )
        try Data("archive".utf8).write(to: sourceProject.appendingPathComponent("old-release.zip"))
        let largeBinary = sourceProject.appendingPathComponent("server")
        FileManager.default.createFile(atPath: largeBinary.path, contents: nil)
        let largeHandle = try FileHandle(forWritingTo: largeBinary)
        try largeHandle.truncate(atOffset: 26 * 1_024 * 1_024)
        try largeHandle.close()
        try Data("existing".utf8).write(
            to: nonEmptyTarget.appendingPathComponent("keep.txt")
        )
        let globalStateURL = home.appendingPathComponent(".codex/.codex-global-state.json")
        try FileManager.default.createDirectory(
            at: globalStateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let originalGlobalState = try JSONSerialization.data(
            withJSONObject: ["local-projects": [:], "unrelated": "preserve"],
            options: [.sortedKeys]
        )
        try originalGlobalState.write(to: globalStateURL, options: .atomic)
        try writeThreadJSONL(id: "project-thread", cwd: sourceProject.path, to: rollout)
        let thread = record(
            id: "project-thread",
            path: sourceProject.path,
            rolloutURL: rollout,
            isArchived: true
        )
        let sessionExport = SessionExportService(
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let sessionImport = SessionImportService(
            homeDirectory: home,
            backupRoot: root.appendingPathComponent("session-backups"),
            pendingCleanupURL: root.appendingPathComponent("support/pending.json"),
            codexIsRunning: { false }
        )
        let service = ProjectTransferService(
            homeDirectory: home,
            backupRoot: root.appendingPathComponent("project-backups"),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            importedAttachmentsRoot: root.appendingPathComponent("imported-attachments"),
            sessionExportService: sessionExport,
            sessionImportService: sessionImport,
            codexIsRunning: { false }
        )
        let bundle = root.appendingPathComponent("SourceProject.codexprojectbundle")
        let exportResult = try service.export(
            threads: [thread],
            projectName: "SourceProject",
            to: bundle
        )
        expect(exportResult.format == .projectBundle, "P0 应生成独立完整项目迁移格式")
        expect(FileManager.default.fileExists(atPath: bundle.path), "项目迁移包应写入目标路径")

        let preview = try service.inspect(bundleURL: bundle, existingThreadIDs: [])
        let included = Set(preview.manifest.files.map(\.relativePath))
        let excluded = Set(preview.manifest.excluded.map(\.relativePath))
        expect(included.contains("Sources/main.swift"), "项目源码应进入迁移快照")
        expect(included.contains("AGENTS.md"), "项目级 AGENTS.md 应进入迁移快照")
        expect(excluded.contains(".env"), "环境变量凭据必须默认排除")
        expect(excluded.contains("data.sqlite"), "数据库必须默认排除")
        expect(excluded.contains("node_modules"), "依赖目录必须默认排除")
        expect(excluded.contains("uploads"), "真实上传目录必须默认排除")
        expect(excluded.contains("CoverAI-deployment-package-old"), "历史部署目录应默认排除但不删除源文件")
        expect(excluded.contains("old-release.zip"), "已有归档应默认不嵌套打包")
        expect(excluded.contains("server"), "大于等于 25 MB 的其他文件应默认排除")
        expect(included.contains("运维修复记录.md"), "中文文件名应能完整进入迁移包")
        expect(preview.sessionCount == 1 && preview.fileCount == 3, "预览应精确报告项目文件和会话数")
        let allDuplicatePreview = try service.inspect(
            bundleURL: bundle,
            existingThreadIDs: ["project-thread"]
        )
        do {
            _ = try service.importBundle(
                preview: allDuplicatePreview,
                targetProjectURL: root.appendingPathComponent("DuplicateOnlyTarget"),
                duplicateStrategy: .skip
            )
            expect(false, "全部会话冲突时不得静默导入成空项目")
        } catch {
            expect(error.localizedDescription.contains("全部生成新 ID"), "空项目阻止信息应指导生成新 ID")
        }
        let estimate = try service.estimate(threads: [thread])
        expect(estimate.includedFileCount == 3, "导出前预检应报告默认安全文件数")
        expect(estimate.excludedDeploymentCount == 1, "预检应报告历史部署目录")
        expect(estimate.excludedArchiveCount == 1, "预检应报告已有归档")
        expect(estimate.excludedLargeFileCount == 1, "预检应报告大型文件")
        let inclusiveEstimate = try service.estimate(
            threads: [thread],
            options: ProjectTransferExportOptions(
                includeUntrackedFiles: true,
                includeAttachments: true,
                includeDeploymentArtifacts: true,
                includeArchives: true,
                includeLargeFiles: true
            )
        )
        expect(inclusiveEstimate.includedFileCount == 6, "用户显式勾选后应将部署目录、归档和大型文件纳入预计范围")

        let unpacked = root.appendingPathComponent("tampered-project", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try runProcess("/usr/bin/ditto", ["-x", "-k", bundle.path, unpacked.path])
        try Data("unlisted".utf8).write(to: unpacked.appendingPathComponent("extra.txt"))
        let tamperedBundle = root.appendingPathComponent("tampered.codexprojectbundle")
        try runProcess("/usr/bin/ditto", ["-c", "-k", "--norsrc", unpacked.path, tamperedBundle.path])
        do {
            _ = try service.inspect(bundleURL: tamperedBundle, existingThreadIDs: [])
            expect(false, "包内未列入校验清单的额外文件必须被拒绝")
        } catch {
            expect(error.localizedDescription.contains("额外文件"), "额外载荷应给出明确安全错误")
        }

        do {
            _ = try service.importBundle(
                preview: preview,
                targetProjectURL: nonEmptyTarget,
                duplicateStrategy: .skip
            )
            expect(false, "P0 不得导入到非空目录")
        } catch {
            expect(error.localizedDescription.contains("新目录或空目录"), "非空目录应给出明确阻止原因")
        }

        let imported = try service.importBundle(
            preview: preview,
            targetProjectURL: targetProject,
            duplicateStrategy: .skip
        )
        expect(imported.importedFileCount == 3, "导入应恢复全部安全项目文件")
        expect(FileManager.default.fileExists(atPath: targetProject.appendingPathComponent("Sources/main.swift").path), "目标项目应恢复源码")
        expect(!FileManager.default.fileExists(atPath: targetProject.appendingPathComponent(".env").path), "导入后不得出现被排除的凭据")
        let importedThread = try findThread(
            id: "project-thread",
            under: home.appendingPathComponent(".codex")
        )
        expect(importedThread?.originalPath == targetProject.path, "会话 cwd 应改写到目标设备项目路径")
        expect(
            threadFileExists(
                id: "project-thread",
                under: home.appendingPathComponent(".codex/sessions")
            ),
            "完整项目迁移应把归档会话恢复到活动列表，确保目标项目可见对话"
        )
        expect(
            !threadFileExists(
                id: "project-thread",
                under: home.appendingPathComponent(".codex/archived_sessions")
            ),
            "完整项目迁移不应把恢复后的会话继续隐藏在归档列表"
        )
        let importedGlobalState = try JSONSerialization.jsonObject(
            with: Data(contentsOf: globalStateURL)
        ) as! [String: Any]
        let importedProjects = importedGlobalState["local-projects"] as! [String: Any]
        expect(importedProjects.values.contains { value in
            guard let project = value as? [String: Any],
                  let roots = project["rootPaths"] as? [String] else { return false }
            return roots.contains(targetProject.path)
        }, "目标设备应登记新的 Codex 本地项目")
        let assignments = importedGlobalState["thread-project-assignments"] as? [String: Any] ?? [:]
        expect(assignments["project-thread"] != nil, "导入会话应精确绑定到新登记项目")

        try service.rollbackImport(at: imported.backupURL)
        expect(!FileManager.default.fileExists(atPath: targetProject.appendingPathComponent("Sources/main.swift").path), "整体回滚应移除本次恢复的项目文件")
        let threadAfterRollback = try findThread(
            id: "project-thread",
            under: home.appendingPathComponent(".codex")
        )
        expect(threadAfterRollback == nil, "整体回滚应撤销本次会话导入")
        let globalStateAfterRollback = try Data(contentsOf: globalStateURL)
        expect(globalStateAfterRollback == originalGlobalState, "整体回滚应恢复导入前 Codex 项目和绑定状态")
        expect(FileManager.default.fileExists(atPath: nonEmptyTarget.appendingPathComponent("keep.txt").path), "阻止的非空目录不得被改写")

        try Data("existing-project-file".utf8).write(
            to: targetProject.appendingPathComponent("keep.txt")
        )
        try JSONSerialization.data(withJSONObject: [
            "local-projects": [
                "repair-project": [
                    "id": "repair-project",
                    "name": "TargetProject",
                    "rootPaths": [targetProject.path],
                ],
            ],
            "thread-project-assignments": [:],
        ]).write(to: globalStateURL, options: .atomic)
        let repairedSessions = try service.importSessionsOnly(
            bundleURL: bundle,
            targetProjectURL: targetProject
        )
        expect(repairedSessions.importedCount == 1, "会话补导应只恢复迁移包内会话")
        expect(FileManager.default.fileExists(atPath: targetProject.appendingPathComponent("keep.txt").path), "会话补导不得覆盖现有项目文件")
        expect(
            repairedSessions.importedThreadIDs.allSatisfy { id in
                threadFileExists(id: id, under: home.appendingPathComponent(".codex/sessions"))
            },
            "补导会话应生成新 ID 并进入活动列表"
        )
        let repairedState = try JSONSerialization.jsonObject(
            with: Data(contentsOf: globalStateURL)
        ) as! [String: Any]
        let repairedAssignments = repairedState["thread-project-assignments"] as? [String: Any] ?? [:]
        expect(
            repairedSessions.importedThreadIDs.allSatisfy { repairedAssignments[$0] != nil },
            "补导会话应绑定到现有目标项目"
        )
        try sessionImport.rollbackImport(at: repairedSessions.backupURL)
    }

    private static func projectTransferP1PreservesGitAndAttachments() throws {
        let root = temporaryDirectory("project-transfer-p1")
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceProject = root.appendingPathComponent("GitProject", isDirectory: true)
        let targetProject = root.appendingPathComponent("ImportedGitProject", isDirectory: true)
        let targetWithoutOptions = root.appendingPathComponent("OptionsOffTarget", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let attachmentRoot = root.appendingPathComponent("restored-attachments", isDirectory: true)
        let attachment = root.appendingPathComponent("codex-clipboard-existing.png")
        let missingAttachment = root.appendingPathComponent("codex-clipboard-missing.png")
        let rollout = root.appendingPathComponent("rollout-p1-thread.jsonl")
        try FileManager.default.createDirectory(at: sourceProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetProject, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetWithoutOptions, withIntermediateDirectories: true)
        try Data("image-data".utf8).write(to: attachment)
        try Data("let value = 1\n".utf8).write(to: sourceProject.appendingPathComponent("main.swift"))
        try runProcess("/usr/bin/git", ["-C", sourceProject.path, "init", "-b", "main"])
        try runProcess("/usr/bin/git", ["-C", sourceProject.path, "config", "user.email", "test@example.com"])
        try runProcess("/usr/bin/git", ["-C", sourceProject.path, "config", "user.name", "Test User"])
        try runProcess("/usr/bin/git", ["-C", sourceProject.path, "add", "main.swift"])
        try runProcess("/usr/bin/git", ["-C", sourceProject.path, "commit", "-m", "initial"])
        try runProcess("/usr/bin/git", [
            "-C", sourceProject.path, "remote", "add", "origin",
            "https://user:secret@example.com/org/repo.git",
        ])
        try Data("let value = 2\n".utf8).write(to: sourceProject.appendingPathComponent("main.swift"))
        try Data("untracked".utf8).write(to: sourceProject.appendingPathComponent("notes.txt"))
        try writeJSONL([
            [
                "timestamp": "2026-08-15T01:00:00.000Z",
                "type": "session_meta",
                "payload": ["id": "p1-thread", "cwd": sourceProject.path, "source": "vscode"],
            ],
            [
                "type": "event_msg",
                "payload": [
                    "type": "user_message",
                    "message": "attachment: \(attachment.path)\nmissing: \(missingAttachment.path)",
                ],
            ],
        ], to: rollout)
        let globalStateURL = home.appendingPathComponent(".codex/.codex-global-state.json")
        try FileManager.default.createDirectory(
            at: globalStateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONSerialization.data(
            withJSONObject: ["local-projects": [:]],
            options: [.sortedKeys]
        ).write(to: globalStateURL, options: .atomic)
        let thread = record(id: "p1-thread", path: sourceProject.path, rolloutURL: rollout)
        let sessionExport = SessionExportService(
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )
        let sessionImport = SessionImportService(
            homeDirectory: home,
            backupRoot: root.appendingPathComponent("session-backups"),
            pendingCleanupURL: root.appendingPathComponent("support/pending.json"),
            codexIsRunning: { false }
        )
        let service = ProjectTransferService(
            homeDirectory: home,
            backupRoot: root.appendingPathComponent("project-backups"),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            importedAttachmentsRoot: attachmentRoot,
            sessionExportService: sessionExport,
            sessionImportService: sessionImport,
            codexIsRunning: { false }
        )

        let bundle = root.appendingPathComponent("GitProject.codexprojectbundle")
        _ = try service.export(
            threads: [thread],
            projectName: "GitProject",
            to: bundle,
            options: .defaults
        )
        let preview = try service.inspect(bundleURL: bundle, existingThreadIDs: [])
        guard let git = preview.manifest.git else {
            expect(false, "P1 Manifest 应包含 Git 元数据")
            return
        }
        expect(git.isRepository, "Git 项目应被识别")
        expect(git.branch == "main", "P1 应记录当前 Git 分支")
        expect(git.head?.isEmpty == false, "P1 应记录 Git HEAD")
        expect(git.isDirty, "P1 应记录 dirty working tree")
        expect(git.remoteURL == "https://example.com/org/repo.git", "Git 远程 URL 必须移除用户信息和凭据")
        expect(git.workingTreePatchPath == "project/working-tree.patch", "dirty 项目应生成 binary-safe patch")
        expect(git.untracked.contains { $0.relativePath == "notes.txt" && $0.included }, "默认应包含安全的 Git 未跟踪文件")
        expect(preview.manifest.files.contains { $0.relativePath == "notes.txt" }, "选中的未跟踪文件应进入项目快照")
        expect(preview.includedAttachmentCount == 1, "P1 应包含可用附件")
        expect(preview.missingAttachmentCount == 1, "P1 应报告缺失附件")

        let noOptionsBundle = root.appendingPathComponent("GitProject-options-off.codexprojectbundle")
        _ = try service.export(
            threads: [thread],
            projectName: "GitProject",
            to: noOptionsBundle,
            options: ProjectTransferExportOptions(
                includeUntrackedFiles: false,
                includeAttachments: false
            )
        )
        let noOptionsPreview = try service.inspect(
            bundleURL: noOptionsBundle,
            existingThreadIDs: []
        )
        expect(!noOptionsPreview.manifest.files.contains { $0.relativePath == "notes.txt" }, "关闭选项后不得打包 Git 未跟踪文件")
        expect(noOptionsPreview.includedUntrackedFileCount == 0, "Manifest 应记录未跟踪文件未被选中")
        expect(noOptionsPreview.includedAttachmentCount == 0, "关闭选项后不得打包附件本体")
        expect(
            noOptionsPreview.manifest.attachments?.contains { $0.status == .notSelected } == true,
            "Manifest 应区分未选附件和缺失附件"
        )

        let imported = try service.importBundle(
            preview: preview,
            targetProjectURL: targetProject,
            duplicateStrategy: .skip
        )
        expect(imported.importedAttachmentCount == 1, "P1 导入应恢复已打包附件")
        guard let attachmentEnumerator = FileManager.default.enumerator(
            at: attachmentRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ), let restoredAttachment = attachmentEnumerator.compactMap({ $0 as? URL }).first(where: {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }) else {
            expect(false, "P1 应在 Monitor 专用目录恢复附件")
            return
        }
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        guard let rolloutEnumerator = FileManager.default.enumerator(
            at: codexHome,
            includingPropertiesForKeys: [.isRegularFileKey]
        ), let importedRollout = rolloutEnumerator.compactMap({ $0 as? URL }).first(where: {
            $0.pathExtension == "jsonl" && $0.lastPathComponent.contains("p1-thread")
        }) else {
            expect(false, "P1 应导入目标会话 JSONL")
            return
        }
        let importedText = try String(contentsOf: importedRollout, encoding: .utf8)
        let importedMessageText = importedText.split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = object["payload"] as? [String: Any]
                else { return nil }
                return payload["message"] as? String
            }
            .joined(separator: "\n")
        expect(
            importedMessageText.contains("/restored-attachments/")
                && importedMessageText.contains(restoredAttachment.lastPathComponent),
            "导入会话应改写为目标设备附件路径"
        )
        expect(!importedMessageText.contains(attachment.path), "导入会话不得继续引用源设备附件路径")
        expect(importedMessageText.contains(missingAttachment.path), "缺失附件应保留原路径并在 Manifest 中报告")

        try service.rollbackImport(at: imported.backupURL)
        expect(!FileManager.default.fileExists(atPath: restoredAttachment.path), "整体回滚应移除本次恢复的附件")
        expect(
            !FileManager.default.fileExists(atPath: targetProject.appendingPathComponent("main.swift").path),
            "P1 回滚仍应撤销项目文件"
        )
    }

    private static func projectTransferLargeGitOutputDoesNotDeadlock() throws {
        let root = temporaryDirectory("project-transfer-large-git-output")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("LargeGitProject", isDirectory: true)
        let rollout = root.appendingPathComponent("rollout-large-git-thread.jsonl")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let suffix = String(repeating: "x", count: 64)
        for index in 0..<900 {
            let name = String(format: "tracked-%04d-%@.txt", index, suffix)
            try Data("x".utf8).write(to: project.appendingPathComponent(name))
        }
        try runProcess("/usr/bin/git", ["-C", project.path, "init", "-b", "main"])
        try runProcess("/usr/bin/git", ["-C", project.path, "add", "."])
        try writeThreadJSONL(id: "large-git-thread", cwd: project.path, to: rollout)
        let thread = record(
            id: "large-git-thread",
            path: project.path,
            rolloutURL: rollout
        )
        let service = ProjectTransferService(
            backupRoot: root.appendingPathComponent("backups"),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            importedAttachmentsRoot: root.appendingPathComponent("attachments"),
            sessionExportService: SessionExportService(
                now: { Date(timeIntervalSince1970: 1_800_000_000) }
            ),
            codexIsRunning: { false }
        )
        let bundle = root.appendingPathComponent("large.codexprojectbundle")
        let completed = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var exportError: Error?
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try service.export(
                    threads: [thread],
                    projectName: "LargeGitProject",
                    to: bundle,
                    options: ProjectTransferExportOptions(
                        includeUntrackedFiles: true,
                        includeAttachments: false
                    )
                )
            } catch {
                lock.lock()
                exportError = error
                lock.unlock()
            }
            completed.signal()
        }
        let waitResult = completed.wait(timeout: .now() + 15)
        expect(waitResult == .success, "Git ls-files 输出超过 Pipe 缓冲区时导出不得死锁")
        lock.lock()
        let capturedError = exportError
        lock.unlock()
        expect(capturedError == nil, "大 Git 索引项目应能完成导出")
        expect(FileManager.default.fileExists(atPath: bundle.path), "大 Git 输出回归应生成项目迁移包")
    }

    private static func exactProjectBindingIsConservative() throws {
        let fixture: [String: Any] = [
            "local-projects": [
                "unique": ["id": "unique", "name": "唯一项目", "rootPaths": ["/tmp/Unique"]],
                "duplicate-a": ["id": "duplicate-a", "rootPaths": ["/tmp/Duplicate"]],
                "duplicate-b": ["id": "duplicate-b", "rootPaths": ["/tmp/Duplicate"]],
            ],
            "project-order": ["duplicate-a", "unique", "duplicate-b"],
            "pinned-project-ids": ["unique"],
            "selected-project": ["type": "local", "projectId": "unique"],
            "electron-persisted-atom-state": [
                "sidebar-project-expanded-v1-codex:unique": true,
                "unified-sidebar-project-order-v1": ["duplicate-a", "unique", "duplicate-b"],
            ],
            "thread-project-assignments": [
                "existing": ["projectKind": "local", "projectId": "unique", "cwd": "/tmp/Unique"],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture)
        let result = try SessionRecoveryService.addingExactProjectBindings(
            to: data,
            threads: [
                record(id: "unique-thread", path: "/tmp/Unique"),
                record(id: "ambiguous-thread", path: "/tmp/Duplicate"),
                record(id: "missing-thread", path: "/tmp/Missing"),
                record(id: "existing", path: "/tmp/Unique"),
            ]
        )
        let root = try JSONSerialization.jsonObject(with: result.data) as! [String: Any]
        let assignments = root["thread-project-assignments"] as! [String: Any]
        expect(result.added == 1, "只应增加一个唯一精确路径绑定")
        expect(assignments["unique-thread"] != nil, "唯一精确路径应补绑定")
        expect(assignments["ambiguous-thread"] == nil, "同路径多项目时不得猜测")
        expect(assignments["missing-thread"] == nil, "未知路径不得猜测")

        let removal = try CodexProjectCatalog.removingLocalProject(
            atPath: "/tmp/Unique",
            from: result.data
        )
        let removedRoot = try JSONSerialization.jsonObject(with: removal.data) as! [String: Any]
        let remainingProjects = removedRoot["local-projects"] as! [String: Any]
        expect(remainingProjects["unique"] == nil, "删除项目应移除精确路径对应的项目登记")
        expect(remainingProjects["duplicate-a"] != nil, "删除项目不得影响其他路径的同类项目")
        let remainingAssignments = removedRoot["thread-project-assignments"] as! [String: Any]
        expect(remainingAssignments["existing"] == nil, "删除项目应移除该项目的会话绑定")
        expect((removedRoot["project-order"] as! [String]) == ["duplicate-a", "duplicate-b"], "删除项目应同步清理项目排序")
        expect((removedRoot["pinned-project-ids"] as! [String]).isEmpty, "删除项目应同步清理置顶项目")
        expect(removedRoot["selected-project"] == nil, "删除当前项目应清理选中状态")
        let removedAtoms = removedRoot["electron-persisted-atom-state"] as! [String: Any]
        expect(removedAtoms["sidebar-project-expanded-v1-codex:unique"] == nil, "删除项目应清理侧栏展开状态")
    }

    private static func accountStateWatcherTracksOnlyAccountFileMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("account-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("auth.json")
        try Data("first".utf8).write(to: stateURL, options: .atomic)
        let changed = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var callbackCount = 0
        var detectedAt: Date?
        let watcher = CodexAccountStateWatcher(codexHome: root, debounceInterval: 0.08)
        watcher.start { timestamp in
            lock.lock()
            callbackCount += 1
            detectedAt = timestamp
            lock.unlock()
            changed.signal()
        }

        Thread.sleep(forTimeInterval: 0.15)
        try Data("unrelated".utf8).write(
            to: root.appendingPathComponent("state.json"),
            options: .atomic
        )
        Thread.sleep(forTimeInterval: 0.18)
        lock.lock()
        let countAfterUnrelatedWrite = callbackCount
        lock.unlock()
        expect(countAfterUnrelatedWrite == 0, "无关 Codex 状态变化不应触发账号刷新")

        try Data("second-account".utf8).write(to: stateURL, options: .atomic)
        expect(
            changed.wait(timeout: .now() + 2) == .success,
            "账号状态文件变化后应及时触发刷新"
        )
        Thread.sleep(forTimeInterval: 0.15)
        lock.lock()
        let finalCount = callbackCount
        let finalDetectedAt = detectedAt
        lock.unlock()
        expect(finalCount == 1, "一次账号文件替换应防抖为一次刷新")
        let stateModificationDate = CodexAccountStateStamp.read(at: stateURL).modificationDate
        expect(
            finalDetectedAt != nil && stateModificationDate != nil
                && abs(finalDetectedAt!.timeIntervalSince(stateModificationDate!)) < 0.01,
            "账号刷新应携带状态文件变更时间作为切号边界"
        )
        watcher.stop()
    }

    private static func sidebarCleanupIsExactAndRecoverable() throws {
        let root = temporaryDirectory("sidebar-cleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let stateURL = home.appendingPathComponent(".codex/.codex-global-state.json")
        let pendingURL = root.appendingPathComponent("support/pending.json")
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        try writeSidebarState(at: stateURL)
        let catalogURL = home.appendingPathComponent(".codex/sqlite/codex-dev.db")
        try writeSidebarCatalog(at: catalogURL)
        let original = try Data(contentsOf: stateURL)
        let service = CodexSidebarCleanupService(
            homeDirectory: home,
            pendingURL: pendingURL,
            backupRoot: backups,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            codexIsRunning: { false }
        )
        let disposition = try service.registerCleanup(
            threadID: "target-thread",
            title: "目标会话"
        )
        guard case let .completed(result) = disposition else {
            expect(false, "Codex 未运行时应立即清理侧栏残留")
            return
        }
        expect(result.removedProjectAssignment, "应移除目标项目绑定")
        expect(result.removedPermissionPreference, "应移除目标权限偏好")
        expect(result.removedCatalogEntry, "应移除目标本地线程目录记录")
        expect(result.backupURL != nil, "实际清理前必须创建完整备份")
        expect(result.catalogBackupURL != nil, "目录清理前必须创建 SQLite 备份")
        let backupData = try Data(contentsOf: result.backupURL!)
        expect(backupData == original, "备份必须与清理前状态完全一致")

        let cleaned = try JSONSerialization.jsonObject(
            with: Data(contentsOf: stateURL)
        ) as! [String: Any]
        let assignments = cleaned["thread-project-assignments"] as! [String: Any]
        let atoms = cleaned["electron-persisted-atom-state"] as! [String: Any]
        let permissions = atoms["heartbeat-thread-permissions-by-id"] as! [String: Any]
        expect(assignments["target-thread"] == nil, "目标项目绑定必须清理")
        expect(permissions["target-thread"] == nil, "目标权限偏好必须清理")
        expect(assignments["other-thread"] != nil, "不得改动其他项目绑定")
        expect(permissions["other-thread"] != nil, "不得改动其他权限偏好")
        expect(cleaned["unrelated-setting"] as? String == "preserve", "不得改动无关全局状态")
        let targetCatalogCount = try sqliteValue(
            at: catalogURL,
            sql: "SELECT COUNT(*) FROM local_thread_catalog WHERE thread_id='target-thread';"
        )
        let otherCatalogCount = try sqliteValue(
            at: catalogURL,
            sql: "SELECT COUNT(*) FROM local_thread_catalog WHERE thread_id='other-thread';"
        )
        let backupCatalogCount = try sqliteValue(
            at: result.catalogBackupURL!,
            sql: "SELECT COUNT(*) FROM local_thread_catalog WHERE thread_id='target-thread';"
        )
        expect(targetCatalogCount == "0", "目标本地线程目录记录必须清理")
        expect(otherCatalogCount == "1", "不得改动其他本地线程目录记录")
        expect(backupCatalogCount == "1", "SQLite 备份必须包含清理前目标记录")
    }

    private static func sidebarCleanupQueuesWhileCodexRuns() throws {
        let root = temporaryDirectory("sidebar-cleanup-queue")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let stateURL = home.appendingPathComponent(".codex/.codex-global-state.json")
        let pendingURL = root.appendingPathComponent("support/pending.json")
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        try writeSidebarState(at: stateURL)
        let catalogURL = home.appendingPathComponent(".codex/sqlite/codex-dev.db")
        try writeSidebarCatalog(at: catalogURL)
        var isRunning = true
        let service = CodexSidebarCleanupService(
            homeDirectory: home,
            pendingURL: pendingURL,
            backupRoot: backups,
            now: { Date(timeIntervalSince1970: 1_800_000_100) },
            codexIsRunning: { isRunning }
        )
        let disposition = try service.registerCleanup(
            threadID: "target-thread",
            title: "目标会话"
        )
        expect(disposition == .queued, "Codex 运行时应排队而不是竞争写状态文件")
        expect(service.pendingCount() == 1, "待清理队列应持久化目标会话")
        let queuedState = try String(contentsOf: stateURL, encoding: .utf8)
        expect(queuedState.contains("target-thread"), "排队阶段不得提前改写 Codex 状态")

        isRunning = false
        let results = try service.processPendingIfPossible()
        expect(results.count == 1 && results[0].removedAnything, "Codex 退出后应执行待清理任务")
        expect(service.pendingCount() == 0, "成功后应移除待清理记录")
        let cleanedState = try String(contentsOf: stateURL, encoding: .utf8)
        expect(!cleanedState.contains("target-thread"), "退出后目标残留必须消失")
        expect(cleanedState.contains("other-thread"), "退出后不得误删其他会话状态")
        let queuedCatalogCount = try sqliteValue(
            at: catalogURL,
            sql: "SELECT COUNT(*) FROM local_thread_catalog WHERE thread_id='target-thread';"
        )
        expect(queuedCatalogCount == "0", "退出后目标目录缓存必须消失")

        isRunning = true
        let projectPendingURL = root.appendingPathComponent("support/pending-projects.json")
        let projectService = CodexProjectCleanupService(
            homeDirectory: home,
            pendingURL: projectPendingURL,
            backupRoot: backups,
            now: { Date(timeIntervalSince1970: 1_800_000_200) },
            codexIsRunning: { isRunning }
        )
        let projectDisposition = try projectService.registerCleanup(
            projectName: "目标项目",
            projectPath: "/tmp/TargetProject"
        )
        expect(projectDisposition == .queued, "Codex 运行时项目登记清理也必须持久化排队")
        expect(projectService.pendingCount() == 1, "项目清理队列应保留精确路径")
        isRunning = false
        let projectResults = try projectService.processPendingIfPossible()
        expect(projectResults.count == 1, "Codex 退出后应执行项目登记清理")
        expect(projectService.pendingCount() == 0, "项目登记清理完成后应清空队列")
        let cleanedProjects = CodexProjectCatalog.loadState(from: stateURL).namesByPath
        expect(cleanedProjects["/tmp/TargetProject"] == nil, "退出后目标项目登记必须消失")
        expect(cleanedProjects["/tmp/OtherProject"] == "其他项目", "不得误删其他项目登记")
    }

    private static func writeSidebarState(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let state: [String: Any] = [
            "local-projects": [
                "target-project": [
                    "id": "target-project",
                    "name": "目标项目",
                    "rootPaths": ["/tmp/TargetProject"],
                ],
                "other-project": [
                    "id": "other-project",
                    "name": "其他项目",
                    "rootPaths": ["/tmp/OtherProject"],
                ],
            ],
            "thread-project-assignments": [
                "target-thread": ["projectKind": "local", "projectId": "target-project"],
                "other-thread": ["projectKind": "local", "projectId": "other-project"],
            ],
            "electron-persisted-atom-state": [
                "heartbeat-thread-permissions-by-id": [
                    "target-thread": ["approvalPolicy": "never"],
                    "other-thread": ["approvalPolicy": "on-request"],
                ],
                "preserved-atom": true,
            ],
            "unrelated-setting": "preserve",
        ]
        try JSONSerialization.data(
            withJSONObject: state,
            options: [.sortedKeys]
        ).write(to: url, options: .atomic)
    }

    private static func writeSidebarCatalog(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try runProcess("/usr/bin/sqlite3", [
            url.path,
            "CREATE TABLE local_thread_catalog (host_id TEXT NOT NULL, thread_id TEXT NOT NULL, display_title TEXT NOT NULL, PRIMARY KEY (host_id, thread_id)); CREATE TABLE local_thread_catalog_metadata (id INTEGER PRIMARY KEY, catalog_revision INTEGER NOT NULL); INSERT INTO local_thread_catalog VALUES ('local','target-thread','目标会话'); INSERT INTO local_thread_catalog VALUES ('local','other-thread','其他会话'); INSERT INTO local_thread_catalog_metadata VALUES (1,1);",
        ])
    }

    private static func sqliteValue(at url: URL, sql: String) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ContinuityTests.SQLite", code: Int(process.terminationStatus))
        }
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func largeThreadUsesBoundedHeadAndTailParsing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("large-continuity-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        func writeLine(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try handle.write(contentsOf: data)
        }

        try writeLine([
            "timestamp": "2026-08-15T04:00:00.000Z",
            "type": "session_meta",
            "payload": [
                "id": "large-thread",
                "cwd": "/tmp/LargeProject",
                "source": "vscode",
                "git": ["branch": "main"],
            ],
        ])
        try writeLine([
            "type": "event_msg",
            "payload": ["type": "user_message", "message": "第一条用户消息"],
        ])
        try writeLine([
            "type": "event_msg",
            "payload": ["type": "agent_message", "message": String(repeating: "x", count: 2_000_000)],
        ])
        try writeLine([
            "type": "event_msg",
            "payload": ["type": "user_message", "message": "尾部用户消息"],
        ])
        try writeLine([
            "type": "event_msg",
            "payload": ["type": "agent_message", "message": "尾部助手消息"],
        ])
        try handle.synchronize()

        guard let envelope = SessionContinuityService.parseThreadEnvelope(at: url) else {
            expect(false, "大文件应能完成有界解析")
            return
        }
        expect(envelope.id == "large-thread", "应从文件头读取会话 ID")
        expect(envelope.originalPath == "/tmp/LargeProject", "应从文件头读取项目路径")
        expect(envelope.firstUserMessage == "第一条用户消息", "应保留第一条用户消息作为标题回退")
        expect(envelope.kind == .userConversation, "大文件中的用户会话不能误判为内部线程")
        expect(envelope.readableMessages.contains("用户：尾部用户消息"), "应从文件尾读取最近用户消息")
        expect(envelope.readableMessages.contains("助手：尾部助手消息"), "应从文件尾读取最近助手消息")
        expect(envelope.bytesRead <= 1_572_864, "单个大文件读取量必须限制在 1.5 MiB")
    }

    private static func responseItemMessagesAreRecognizedWithoutDuplicates() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("response-item-continuity-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeJSONL([
            [
                "timestamp": "2026-08-24T15:00:00.000Z",
                "type": "session_meta",
                "payload": [
                    "id": "response-item-thread",
                    "cwd": "/tmp/ResponseItemProject",
                    "source": "vscode",
                ],
            ],
            [
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "user",
                    "content": [
                        ["type": "input_text", "text": "新格式用户消息"],
                        ["type": "input_image", "image_url": "data:image/png;base64,ignored"],
                    ],
                ],
            ],
            [
                "type": "event_msg",
                "payload": ["type": "user_message", "message": "新格式用户消息"],
            ],
            [
                "type": "response_item",
                "payload": [
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": "新格式助手消息"]],
                ],
            ],
            [
                "type": "event_msg",
                "payload": ["type": "agent_message", "message": "新格式助手消息"],
            ],
        ], to: url)

        guard let envelope = SessionContinuityService.parseThreadEnvelope(at: url) else {
            expect(false, "response_item 会话应能解析")
            return
        }
        expect(envelope.kind == .userConversation, "response_item role:user 必须识别为用户会话")
        expect(envelope.firstUserMessage == "新格式用户消息", "新格式用户消息应作为标题回退")
        expect(
            envelope.readableMessages.filter { $0 == "用户：新格式用户消息" }.count == 1,
            "新旧格式同时存在时用户消息不得重复"
        )
        expect(
            envelope.readableMessages.filter { $0 == "助手：新格式助手消息" }.count == 1,
            "新旧格式同时存在时助手消息不得重复"
        )
    }

    private static func makePortableBundle(
        root: URL,
        projectPath: String,
        sessions: [(id: String, archived: Bool)]
    ) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let records = try sessions.map { session -> LocalThreadRecord in
            let rollout = root.appendingPathComponent("rollout-\(session.id).jsonl")
            try writeThreadJSONL(id: session.id, cwd: projectPath, to: rollout)
            return record(
                id: session.id,
                path: projectPath,
                rolloutURL: rollout,
                isArchived: session.archived
            )
        }
        let bundle = root.appendingPathComponent("project.codexmonitorbundle")
        _ = try SessionExportService(now: { Date(timeIntervalSince1970: 1_800_000_000) }).export(
            threads: records,
            projectName: URL(fileURLWithPath: projectPath).lastPathComponent,
            format: .portableBundle,
            to: bundle
        )
        return bundle
    }

    private static func writeThreadJSONL(id: String, cwd: String, to url: URL) throws {
        try writeJSONL([
            [
                "timestamp": "2026-08-15T01:00:00.000Z",
                "type": "session_meta",
                "payload": ["id": id, "cwd": cwd, "source": "vscode"],
            ],
            [
                "type": "event_msg",
                "payload": ["type": "user_message", "message": "继续项目"],
            ],
        ], to: url)
    }

    private static func findThread(
        id: String,
        under root: URL
    ) throws -> SessionContinuityService.ThreadEnvelope? {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if let envelope = SessionContinuityService.parseThreadEnvelope(at: url), envelope.id == id {
                return envelope
            }
        }
        return nil
    }

    private static func threadFileExists(id: String, under root: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return false }
        for case let url as URL in enumerator
            where url.pathExtension == "jsonl" && url.lastPathComponent.contains(id) {
            return true
        }
        return false
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ContinuityTests", code: Int(process.terminationStatus))
        }
    }

    private static func makeStore(_ name: String) -> AccountContinuityStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuity-test-\(name)-\(UUID().uuidString).json")
        return AccountContinuityStore(stateURL: url)
    }

    private static func account(_ email: String, at timestamp: TimeInterval) -> CodexAccountInfo {
        CodexAccountInfo(
            type: "chatgpt",
            email: email,
            planType: "pro",
            observedAt: Date(timeIntervalSince1970: timestamp)
        )
    }

    private static func record(
        id: String,
        path: String,
        messages: [String] = ["用户：继续"],
        kind: LocalThreadKind = .userConversation,
        rolloutURL: URL? = nil,
        isArchived: Bool = false,
        ownership: SessionOwnership = .unknown
    ) -> LocalThreadRecord {
        LocalThreadRecord(
            id: id,
            title: "测试会话",
            projectName: URL(fileURLWithPath: path).lastPathComponent,
            projectPath: path,
            rolloutURL: rolloutURL ?? URL(fileURLWithPath: "/tmp/\(id).jsonl"),
            isArchived: isArchived,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            gitBranch: "main",
            readableMessages: messages,
            kind: kind,
            ownership: ownership,
            visibility: .localOnly
        )
    }

    private static func temporaryDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("continuity-test-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeJSONL(_ objects: [[String: Any]], to url: URL) throws {
        let lines = try objects.map { object in
            String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("Continuity test failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
