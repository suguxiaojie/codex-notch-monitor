import Foundation
import SQLite3

struct LocalSessionSnapshot: Equatable {
    let sessionID: String
    let turnID: String?
    let cwd: String
    let model: String?
    let isActive: Bool
    let updatedAt: Date
    let activities: [SessionActivityItem]
    var turnTokenUsage: TurnTokenUsage? = nil
}

enum SessionActivityFreshnessPolicy {
    static let quietTurnGrace: TimeInterval = 10 * 60
    static let runningToolGrace: TimeInterval = 2 * 60 * 60
    static let discoveryGrace: TimeInterval = 15

    static func isActive(
        lifecycleState: Bool?,
        hasRunningTool: Bool,
        updatedAt: Date,
        fileModifiedAt: Date,
        now: Date = Date()
    ) -> Bool {
        switch lifecycleState {
        case false:
            return false
        case true:
            let grace = hasRunningTool ? runningToolGrace : quietTurnGrace
            return now.timeIntervalSince(updatedAt) < grace
        case nil:
            return now.timeIntervalSince(fileModifiedAt) < discoveryGrace
        }
    }
}

/// Reads only structural fields from Codex's local JSONL transcript. Prompt,
/// response, reasoning, and tool payloads are intentionally never retained.
final class SessionActivityService {
    private let queue = DispatchQueue(label: "CodexNotchMonitor.SessionActivity", qos: .utility)
    private let decoder = JSONDecoder()
    /// Recent activity and completion markers live at the transcript tail.
    /// Keeping this bounded prevents one growing Codex thread from producing a
    /// large JSON parse spike on every fallback refresh; lifecycle Hooks remain
    /// the primary real-time state source.
    private let maximumTailBytes: UInt64 = 8 * 1_024 * 1_024
    private let maximumCandidateFiles = 24
    private let activeRecencyInterval: TimeInterval = 24 * 60 * 60
    private let discoveryInterval: TimeInterval = 5
    private var cache: [URL: CachedSnapshot] = [:]
    private var discoveredURLs: [URL] = []
    private var lastDiscoveryAt = Date.distantPast

    private struct CachedSnapshot {
        let modificationDate: Date
        let fileSize: UInt64
        let snapshot: LocalSessionSnapshot?
    }

    func fetch(completion: @escaping ([LocalSessionSnapshot], [String: String]) -> Void) {
        queue.async { [self] in
            let urls = recentSessionFiles()
            let now = Date()
            let snapshots = urls.compactMap(cachedSnapshot).filter {
                now.timeIntervalSince($0.updatedAt) < activeRecencyInterval
            }
            let threadNames = CodexThreadNameCatalog.loadNames()
            let retained = Set(urls)
            cache = cache.filter { retained.contains($0.key) }
            DispatchQueue.main.async { completion(snapshots, threadNames) }
        }
    }

    private func recentSessionFiles() -> [URL] {
        let now = Date()
        if now.timeIntervalSince(lastDiscoveryAt) < discoveryInterval {
            return discoveredURLs
        }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return discoveredURLs }
        let candidates = enumerator.compactMap { item -> (URL, Date)? in
            guard let url = item as? URL, url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) < activeRecencyInterval
            else { return nil }
            return (url, modified)
        }
        discoveredURLs = candidates.sorted { $0.1 > $1.1 }
            .prefix(maximumCandidateFiles)
            .map(\.0)
        lastDiscoveryAt = now
        return discoveredURLs
    }

    private func cachedSnapshot(for url: URL) -> LocalSessionSnapshot? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate ?? .distantPast
        let size = UInt64(max(0, values?.fileSize ?? 0))
        if let cached = cache[url], cached.modificationDate == modified, cached.fileSize == size {
            return cached.snapshot
        }
        let snapshot = readSnapshot(from: url)
        cache[url] = CachedSnapshot(
            modificationDate: modified,
            fileSize: size,
            snapshot: snapshot
        )
        return snapshot
    }

    private func modificationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    func readSnapshot(from url: URL) -> LocalSessionSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > maximumTailBytes ? end - maximumTailBytes : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        // A bounded tail can begin in the middle of one JSON object.
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(data.startIndex...newline)
        }

        var sessionID = Self.sessionIDFromFilename(url)
        var turnID: String?
        var cwd = ""
        var model: String?
        var isActive: Bool?
        var latestTimestamp = modificationDate(of: url)
        var activities: [SessionActivityItem] = []
        var activityIndices: [String: Int] = [:]
        var tokenState = TurnTokenState()

        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any]
            else { continue }

            tokenState.consume(type: type, payload: payload)

            var eventTimestamp = latestTimestamp
            if let timestamp = object["timestamp"] as? String,
               let parsed = Self.parseDate(timestamp) {
                eventTimestamp = parsed
                latestTimestamp = max(latestTimestamp, parsed)
            }

            switch type {
            case "session_meta":
                sessionID = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? sessionID
                if let value = payload["cwd"] as? String { cwd = value }
            case "turn_context":
                if let value = payload["turn_id"] as? String { turnID = value }
                if let value = payload["cwd"] as? String { cwd = value }
                if let value = payload["model"] as? String { model = value }
            case "event_msg":
                switch payload["type"] as? String {
                case "task_started":
                    isActive = true
                    if let value = payload["turn_id"] as? String { turnID = value }
                case "task_complete", "turn_aborted":
                    let completedTurn = payload["turn_id"] as? String
                    if turnID == nil || completedTurn == nil || completedTurn == turnID {
                        isActive = false
                    }
                case "agent_message":
                    guard payload["phase"] as? String == "commentary",
                          let message = payload["message"] as? String,
                          let summary = Self.progressSummary(message)
                    else { break }
                    for index in activities.indices where activities[index].kind == .progress {
                        activities[index].isRunning = false
                    }
                    activities.append(SessionActivityItem(
                        id: "progress-\(eventTimestamp.timeIntervalSince1970)",
                        kind: .progress,
                        title: summary,
                        isRunning: true,
                        updatedAt: eventTimestamp
                    ))
                default: break
                }
            case "response_item":
                switch payload["type"] as? String {
                case "custom_tool_call":
                    let callID = (payload["call_id"] as? String) ?? "tool-\(eventTimestamp.timeIntervalSince1970)"
                    let name = payload["name"] as? String ?? "tool"
                    let input = payload["input"] as? String ?? ""
                    if let last = activities.indices.last, activities[last].kind == .progress {
                        activities[last].isRunning = false
                    }
                    activities.append(SessionActivityItem(
                        id: callID,
                        kind: Self.activityKind(for: name, input: input),
                        title: Self.toolSummary(name: name, input: input),
                        isRunning: true,
                        updatedAt: eventTimestamp
                    ))
                    activityIndices[callID] = activities.count - 1
                case "custom_tool_call_output":
                    guard let callID = payload["call_id"] as? String,
                          let index = activityIndices[callID],
                          activities.indices.contains(index)
                    else { break }
                    activities[index].isRunning = false
                    activities[index].updatedAt = eventTimestamp
                default:
                    break
                }
            default:
                break
            }
        }

        // If a very large transcript tail no longer contains task_started, recent
        // writes are still a useful startup fallback. An explicit completion marker
        // always wins and prevents a recently completed turn appearing active.
        let fileModifiedAt = modificationDate(of: url)
        let hasRunningTool = activities.contains { $0.kind != .progress && $0.isRunning }
        let active = SessionActivityFreshnessPolicy.isActive(
            lifecycleState: isActive,
            hasRunningTool: hasRunningTool,
            updatedAt: latestTimestamp,
            fileModifiedAt: fileModifiedAt
        )
        guard !sessionID.isEmpty else { return nil }
        return LocalSessionSnapshot(
            sessionID: sessionID,
            turnID: turnID,
            cwd: cwd,
            model: model,
            isActive: active,
            updatedAt: latestTimestamp,
            activities: Array(activities.suffix(6)).sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.isRunning && !$1.isRunning
            },
            turnTokenUsage: tokenState.turnID.map {
                TurnTokenUsage(sessionID: sessionID, turnID: $0, total: tokenState.total,
                               isCompleted: tokenState.isCompleted)
            }
        )
    }

    static func sessionIDFromFilename(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let pattern = #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#
        if let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = expression.firstMatch(
                in: stem,
                range: NSRange(stem.startIndex..., in: stem)
           ),
           let range = Range(match.range, in: stem) {
            return String(stem[range])
        }
        return stem.split(separator: "-").suffix(5).joined(separator: "-")
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func progressSummary(_ message: String) -> String? {
        let cleaned = message
            .replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && !$0.hasPrefix("-") })
        return cleaned.map { truncate($0, limit: 92) }
    }

    private static func activityKind(for toolName: String, input: String) -> SessionActivityKind {
        switch toolName {
        case "exec":
            if input.contains("tools.apply_patch") { return .fileChange }
            if input.contains("tools.view_image") { return .read }
            guard extractTitle(from: input) == nil, let command = extractCommand(from: input) else { return .tool }
            if isReadCommand(command) { return .read }
            if isSearchCommand(command) { return .search }
            return .command
        case "apply_patch": return .fileChange
        default: return .tool
        }
    }

    static func toolSummary(name: String, input: String) -> String {
        switch name {
        case "exec":
            if let title = extractTitle(from: input) {
                return sanitize(title)
            }
            if input.contains("tools.apply_patch") {
                return "修改 · \(extractPatchedFileLabel(from: input) ?? "项目文件")"
            }
            if input.contains("tools.view_image") {
                return "检查图片 · \(fileLabel(from: input) ?? "本地图片")"
            }
            if input.contains("tools.web__run") {
                return "查询网页资料"
            }
            if input.contains("tools.update_plan") {
                return "更新任务计划"
            }
            if input.contains("tools.write_stdin") {
                return "等待构建或测试结果"
            }
            if let command = extractCommand(from: input) {
                if isReadCommand(command) {
                    return "读取 \(fileLabel(from: command) ?? "项目文件")"
                }
                if isSearchCommand(command) {
                    return "搜索 \(fileLabel(from: command) ?? "项目内容")"
                }
                return "运行命令 · \(sanitize(command))"
            }
            return "运行命令"
        case "apply_patch": return "修改项目文件"
        case "view_image": return "检查图片"
        case "web__run": return "查询网页资料"
        default:
            let readable = name.replacingOccurrences(of: "_", with: " ")
            return "调用工具 · \(truncate(readable, limit: 64))"
        }
    }

    private static func extractTitle(from input: String) -> String? {
        extractJSONString(after: #"(?:[\"']?title[\"']?)\s*:"#, from: input)
    }

    private static func extractCommand(from input: String) -> String? {
        extractJSONString(after: #"(?:[\"']?cmd[\"']?)\s*:"#, from: input)
    }

    private static func extractPatchedFileLabel(from input: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"\*\*\*\s+(?:Update|Add)\s+File:\s+([^\r\n]+)"#,
            options: .caseInsensitive
        ) else { return nil }
        let range = NSRange(input.startIndex..., in: input)
        guard let match = expression.firstMatch(in: input, range: range),
              let valueRange = Range(match.range(at: 1), in: input)
        else { return nil }
        let rawPath = String(input[valueRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: rawPath).lastPathComponent
    }

    private static func extractJSONString(after labelPattern: String, from input: String) -> String? {
        guard let label = input.range(of: labelPattern, options: .regularExpression) else { return nil }
        let remainder = input[label.upperBound...]
        guard let openingQuote = remainder.firstIndex(of: "\"") else { return nil }
        var index = remainder.index(after: openingQuote)
        var escaped = false
        while index < remainder.endIndex {
            let character = remainder[index]
            if character == "\"", !escaped {
                let literal = String(remainder[openingQuote...index])
                guard let data = literal.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String
            }
            if character == "\\" {
                escaped.toggle()
            } else {
                escaped = false
            }
            index = remainder.index(after: index)
        }
        return nil
    }

    private static func isReadCommand(_ command: String) -> Bool {
        command.range(
            of: #"(^|[;&|]\s*)(sed\s+-n|cat\s|head\s|tail\s|less\s|bat\s)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isSearchCommand(_ command: String) -> Bool {
        command.range(
            of: #"(^|[;&|]\s*)(rg|grep|find)\s"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func fileLabel(from command: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?:^|[\s\"'])([^\s\"']+\.(?:swift|jsonl|json|md|plist|py|sh|js|ts|tsx|jsx|html|css|yml|yaml|toml|txt))(?=$|[\s\"';|])"#,
            options: .caseInsensitive
        ) else { return nil }
        let range = NSRange(command.startIndex..., in: command)
        let matches = expression.matches(in: command, range: range)
        guard let match = matches.last,
              let valueRange = Range(match.range(at: 1), in: command)
        else { return nil }
        return URL(fileURLWithPath: String(command[valueRange])).lastPathComponent
    }

    private static func sanitize(_ value: String) -> String {
        var output = value
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if let secretPattern = try? NSRegularExpression(
            pattern: #"(?i)(token|api[_-]?key|password|secret)\s*[=:]\s*[^\s,;]+"#
        ) {
            let range = NSRange(output.startIndex..., in: output)
            output = secretPattern.stringByReplacingMatches(in: output, range: range, withTemplate: "$1=••••")
        }
        output = output.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return truncate(output.trimmingCharacters(in: .whitespacesAndNewlines), limit: 88)
    }

    private static func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit - 1)) + "…"
    }
}

/// Reads user-assigned Codex task names from the local state database. The
/// query is read-only and intentionally ignores prompt-derived fallback titles.
enum CodexThreadNameCatalog {
    private static var defaultDatabaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/state_5.sqlite")
    }

    static func loadNames(from databaseURL: URL? = nil) -> [String: String] {
        let url = databaseURL ?? defaultDatabaseURL
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database else {
            if database != nil { sqlite3_close(database) }
            return [:]
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)

        var statement: OpaquePointer?
        let sql = "SELECT id, name FROM threads WHERE name IS NOT NULL AND trim(name) <> ''"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [:] }
        defer { sqlite3_finalize(statement) }

        var names: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idText = sqlite3_column_text(statement, 0),
                  let nameText = sqlite3_column_text(statement, 1)
            else { continue }
            let id = String(cString: idText)
            let name = String(cString: nameText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !id.isEmpty, !name.isEmpty { names[id] = name }
        }
        return names
    }
}

enum ProjectActivityAggregator {
    static func projects(
        snapshots: [LocalSessionSnapshot],
        hookTasks: [MonitoredTask],
        now: Date = Date(),
        catalog: CodexProjectCatalog.State? = nil,
        threadNames: [String: String] = [:]
    ) -> [ActiveProjectState] {
        let catalog = catalog ?? CodexProjectCatalog.loadState()
        let projectNames = catalog.namesByPath
        let latestHooks = Dictionary(grouping: hookTasks, by: \.id).compactMapValues {
            $0.max(by: { $0.updatedAt < $1.updatedAt })
        }
        var sessions: [String: ActiveSessionState] = [:]

        for snapshot in snapshots where snapshot.isActive {
            let runningTool = snapshot.activities
                .filter { $0.kind != .progress }
                .max(by: { $0.updatedAt < $1.updatedAt })?
                .isRunning == true
            var phase: TaskPhase = runningTool ? .usingTool : .working
            if let hook = latestHooks[snapshot.sessionID], hook.phase.isActive,
               hook.phase.attentionPriority < phase.attentionPriority {
                phase = hook.phase
            }
            let assigned = catalog.assignmentsByThread[snapshot.sessionID]
            let path = normalizedPath(assigned?.path ?? snapshot.cwd, sessionID: snapshot.sessionID)
            let name = assigned?.projectName ?? projectName(path: path, projectNames: projectNames)
            let task = MonitoredTask(
                id: snapshot.sessionID,
                turnID: snapshot.turnID,
                threadName: threadNames[snapshot.sessionID],
                projectName: name,
                projectPath: path,
                model: snapshot.model,
                toolName: latestHooks[snapshot.sessionID]?.toolName,
                phase: phase,
                updatedAt: snapshot.updatedAt
            )
            sessions[snapshot.sessionID] = ActiveSessionState(task: task, activities: snapshot.activities)
        }

        // Hooks bridge the short interval before a new transcript is visible.
        for hook in latestHooks.values where hook.phase.isActive && now.timeIntervalSince(hook.updatedAt) < 120 {
            if snapshots.contains(where: {
                $0.sessionID == hook.id && !$0.isActive && $0.turnID != nil
                    && $0.turnID == hook.turnID && $0.updatedAt >= hook.updatedAt
            }) { continue }
            if let existing = sessions[hook.id] {
                var task = existing.task
                // session_meta.cwd is immutable history. A lifecycle hook can
                // report the same live session after its project directory was
                // renamed, so prefer the hook's current normalized path.
                let assigned = catalog.assignmentsByThread[hook.id]
                let hookPath = normalizedPath(assigned?.path ?? hook.projectPath, sessionID: hook.id)
                if hookPath != task.projectPath {
                    task.projectPath = hookPath
                    task.projectName = assigned?.projectName
                        ?? projectName(path: hookPath, projectNames: projectNames)
                }
                if hook.phase.attentionPriority <= existing.task.phase.attentionPriority {
                    task.phase = hook.phase
                    task.toolName = hook.toolName ?? task.toolName
                    task.updatedAt = max(task.updatedAt, hook.updatedAt)
                }
                sessions[hook.id] = ActiveSessionState(task: task, activities: existing.activities)
            } else {
                var assignedTask = hook
                assignedTask.threadName = threadNames[hook.id]
                if let assigned = catalog.assignmentsByThread[hook.id] {
                    assignedTask.projectPath = normalizedPath(assigned.path, sessionID: hook.id)
                    assignedTask.projectName = assigned.projectName
                }
                sessions[hook.id] = ActiveSessionState(task: assignedTask, activities: [])
            }
        }

        let grouped = Dictionary(grouping: sessions.values) { session in
            normalizedPath(session.task.projectPath, sessionID: session.id)
        }
        return grouped.map { path, group in
            let orderedSessions = group.sorted(by: sessionComesFirst)
            var representative = orderedSessions[0].task
            representative.projectName = projectName(path: path, projectNames: projectNames)
            let mergedActivities = orderedSessions.flatMap { session in
                session.activities.map { activity in
                    SessionActivityItem(
                        id: "\(session.id)-\(activity.id)",
                        kind: activity.kind,
                        title: activity.title,
                        isRunning: activity.isRunning,
                        updatedAt: activity.updatedAt
                    )
                }
            }.sorted { $0.updatedAt > $1.updatedAt }
            let projectTask = MonitoredTask(
                id: path,
                turnID: representative.turnID,
                threadName: representative.threadName,
                projectName: representative.projectName,
                projectPath: path,
                model: representative.model,
                toolName: representative.toolName,
                phase: representative.phase,
                updatedAt: orderedSessions.map(\.task.updatedAt).max() ?? representative.updatedAt
            )
            return ActiveProjectState(
                id: path,
                name: representative.projectName,
                path: path,
                sessions: orderedSessions,
                task: projectTask,
                activities: mergedActivities
            )
        }.sorted(by: projectComesFirst)
    }

    private static func sessionComesFirst(_ lhs: ActiveSessionState, _ rhs: ActiveSessionState) -> Bool {
        if lhs.task.phase.attentionPriority != rhs.task.phase.attentionPriority {
            return lhs.task.phase.attentionPriority < rhs.task.phase.attentionPriority
        }
        return lhs.task.updatedAt > rhs.task.updatedAt
    }

    private static func projectComesFirst(_ lhs: ActiveProjectState, _ rhs: ActiveProjectState) -> Bool {
        if lhs.task.phase.attentionPriority != rhs.task.phase.attentionPriority {
            return lhs.task.phase.attentionPriority < rhs.task.phase.attentionPriority
        }
        if lhs.task.updatedAt != rhs.task.updatedAt { return lhs.task.updatedAt > rhs.task.updatedAt }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func normalizedPath(_ raw: String, sessionID: String) -> String {
        guard !raw.isEmpty else { return "session://\(sessionID)" }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }

    private static func projectName(path: String, projectNames: [String: String]) -> String {
        if let savedName = CodexProjectCatalog.displayName(for: path, namesByPath: projectNames) {
            return savedName
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? "Codex 任务" : name
    }
}
