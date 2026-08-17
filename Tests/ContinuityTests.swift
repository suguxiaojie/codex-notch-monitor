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
        try emailSummaryIsRedactedAndBackwardCompatible()
        threadKindsFollowAppServerSourceSemantics()
        continuityCountsOnlyUserConversations()
        projectGroupsContainTheirConversations()
        handoffRedactsSecrets()
        try exactProjectBindingIsConservative()
        try accountStateWatcherTracksOnlyAccountFileMetadata()
        try largeThreadUsesBoundedHeadAndTailParsing()
        try readableSessionExportIsCompleteAndRedacted()
        try portableBundlePreservesActiveAndArchivedSessions()
        try sessionImportValidatesMapsSkipsAndRollsBack()
        try duplicateImportGeneratesNewThreadID()
        try damagedPortableBundleIsRejected()
        print("Continuity tests: 16/16 passed")
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
    }

    private static func handoffRedactsSecrets() {
        let thread = record(
            id: "thread-redaction",
            path: "/tmp/Project",
            messages: [
                "用户：请使用 api_key=super-secret-value",
                "助手：token 是 sk-abcdefghijklmnop1234",
                "用户：请求头 Authorization: Bearer abcdefghijklmnop",
                "用户：继续完成公开的 README",
            ]
        )
        let context = SessionContinuityService.handoffContext(for: thread)
        expect(context.hasPrefix("# Codex 会话交接摘要"), "交接文本应标明是摘要")
        expect(context.contains("[REDACTED]"), "交接文本应标记脱敏内容")
        expect(!context.contains("super-secret-value"), "交接文本不能保留键值密钥")
        expect(!context.contains("sk-abcdefghijklmnop1234"), "交接文本不能保留 OpenAI 风格密钥")
        expect(!context.contains("abcdefghijklmnop"), "交接文本不能保留 Bearer Token")
        expect(context.contains("继续完成公开的 README"), "普通可读上下文应保留")
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
        try writeJSONL(events, to: rollout)
        let thread = record(id: "readable", path: "/tmp/ExportProject", rolloutURL: rollout)
        let service = SessionExportService(now: { Date(timeIntervalSince1970: 1_800_000_000) })

        let markdownURL = root.appendingPathComponent("conversation.md")
        _ = try service.export(
            threads: [thread],
            projectName: "ExportProject",
            format: .markdown,
            to: markdownURL
        )
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        expect(markdown.contains("[REDACTED]"), "Markdown 导出应脱敏")
        expect(!markdown.contains("super-secret-value"), "Markdown 导出不能泄露密钥")
        expect(markdown.contains("消息-1"), "完整导出不能只保留最近 20 条消息")
        expect(markdown.contains("最后一条消息"), "完整导出应包含最后一条消息")

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
        _ = try SessionExportService(now: { Date(timeIntervalSince1970: 1_800_000_000) }).export(
            threads: [active, archived],
            projectName: "BundleProject",
            format: .portableBundle,
            to: output
        )

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
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let bundle = try makePortableBundle(
            root: root.appendingPathComponent("source", isDirectory: true),
            projectPath: project.path,
            sessions: [("duplicate-thread", false)]
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
            mappedProjectURL: nil,
            duplicateStrategy: .duplicate
        )
        expect(result.importedCount == 1 && result.skippedDuplicateCount == 0, "副本策略应导入重复会话")
        guard let generatedID = result.importedThreadIDs.first else {
            expect(false, "副本导入应返回新 ID")
            return
        }
        expect(generatedID != "duplicate-thread", "副本导入必须生成新 ID")
        let generated = try findThread(id: generatedID, under: home.appendingPathComponent(".codex"))
        expect(generated != nil, "JSONL 中应写入新 ID")
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

    private static func exactProjectBindingIsConservative() throws {
        let fixture: [String: Any] = [
            "local-projects": [
                "unique": ["id": "unique", "name": "唯一项目", "rootPaths": ["/tmp/Unique"]],
                "duplicate-a": ["id": "duplicate-a", "rootPaths": ["/tmp/Duplicate"]],
                "duplicate-b": ["id": "duplicate-b", "rootPaths": ["/tmp/Duplicate"]],
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
        let watcher = CodexAccountStateWatcher(codexHome: root, debounceInterval: 0.08)
        watcher.start {
            lock.lock()
            callbackCount += 1
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
        lock.unlock()
        expect(finalCount == 1, "一次账号文件替换应防抖为一次刷新")
        watcher.stop()
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
