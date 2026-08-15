import Foundation

enum ThreadVisibility: String, Equatable {
    case visible
    case localOnly
    case projectPathMissing
    case internalThread

    var title: String {
        switch self {
        case .visible: return "当前可见"
        case .localOnly: return "待恢复"
        case .projectPathMissing: return "项目路径缺失"
        case .internalThread: return "内部线程"
        }
    }
}

enum LocalThreadKind: String, Equatable {
    case userConversation
    case subagent
    case system
}

struct LocalThreadRecord: Identifiable, Equatable {
    let id: String
    let title: String
    let projectName: String
    let projectPath: String
    let rolloutURL: URL
    let isArchived: Bool
    let updatedAt: Date
    let gitBranch: String?
    let readableMessages: [String]
    let kind: LocalThreadKind
    var ownership: SessionOwnership
    var visibility: ThreadVisibility

    var canRecover: Bool { kind == .userConversation && visibility == .localOnly }
    var canExportSummary: Bool {
        kind == .userConversation && visibility != .projectPathMissing && !readableMessages.isEmpty
    }
}

struct ContinuityProjectGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let threads: [LocalThreadRecord]
}

struct SessionContinuitySnapshot: Equatable {
    var threads: [LocalThreadRecord]
    var unreadableFileCount: Int
    var checkedAt: Date

    static let empty = SessionContinuitySnapshot(threads: [], unreadableFileCount: 0, checkedAt: .distantPast)

    var userThreads: [LocalThreadRecord] { threads.filter { $0.kind == .userConversation } }
    var sessionCount: Int { userThreads.count }
    var archivedCount: Int { userThreads.filter(\.isArchived).count }
    var visibleCount: Int { userThreads.filter { $0.visibility == .visible }.count }
    var recoverableThreads: [LocalThreadRecord] { threads.filter(\.canRecover) }
    var missingPathCount: Int { userThreads.filter { $0.visibility == .projectPathMissing }.count }
    var baselineOwnershipCount: Int {
        userThreads.filter { $0.ownership.confidence == .baseline }.count
    }
    var unknownOwnershipCount: Int {
        userThreads.filter { $0.ownership.confidence == .unknown }.count
    }
    var projectCount: Int { Set(userThreads.map(\.projectPath).filter { !$0.isEmpty }).count }
    var projectGroups: [ContinuityProjectGroup] {
        Dictionary(grouping: userThreads, by: \.projectPath)
            .map { path, threads in
                ContinuityProjectGroup(
                    id: path,
                    name: threads.first?.projectName ?? "未命名项目",
                    threads: threads.sorted { $0.updatedAt > $1.updatedAt }
                )
            }
            .sorted {
                ($0.threads.first?.updatedAt ?? .distantPast)
                    > ($1.threads.first?.updatedAt ?? .distantPast)
            }
    }

    func applyingOwnership(_ ownership: [String: SessionOwnership]) -> SessionContinuitySnapshot {
        var copy = self
        copy.threads = threads.map { thread in
            var value = thread
            value.ownership = ownership[thread.id] ?? .unknown
            return value
        }
        return copy
    }
}

final class CodexThreadService {
    static let continuitySourceKinds = ["vscode", "subAgent"]

    func listThreadIDs(
        useStateDBOnly: Bool,
        completion: @escaping (Result<Set<String>, Error>) -> Void
    ) {
        listThreadIDs(archived: false, useStateDBOnly: useStateDBOnly) { liveResult in
            switch liveResult {
            case let .failure(error): completion(.failure(error))
            case let .success(live):
                self.listThreadIDs(archived: true, useStateDBOnly: useStateDBOnly) { archiveResult in
                    completion(archiveResult.map { live.union($0) })
                }
            }
        }
    }

    func rebuildThreadIndex(completion: @escaping (Result<Set<String>, Error>) -> Void) {
        listThreadIDs(useStateDBOnly: false, completion: completion)
    }

    private func listThreadIDs(
        archived: Bool,
        useStateDBOnly: Bool,
        completion: @escaping (Result<Set<String>, Error>) -> Void
    ) {
        CodexAppServerClient.request(
            method: "thread/list",
            params: [
                "archived": archived,
                "limit": 1_000,
                "modelProviders": [],
                "sourceKinds": Self.continuitySourceKinds,
                "useStateDbOnly": useStateDBOnly,
            ],
            timeout: useStateDBOnly ? 20 : 60
        ) { result in
            completion(result.map { payload in
                let data = payload["data"] as? [[String: Any]] ?? []
                return Set(data.compactMap { $0["id"] as? String })
            })
        }
    }
}

final class SessionContinuityService {
    struct ThreadEnvelope {
        let id: String
        let originalPath: String
        let timestamp: Date?
        let gitBranch: String?
        let firstUserMessage: String?
        let readableMessages: [String]
        let kind: LocalThreadKind
        let bytesRead: Int
    }

    private struct FileSignature: Equatable {
        let size: Int
        let modifiedAt: Date?
    }

    private struct CachedEnvelope {
        let signature: FileSignature
        let envelope: ThreadEnvelope
    }

    private struct EnvelopeAccumulator {
        var sessionID: String?
        var cwd: String?
        var timestamp: Date?
        var gitBranch: String?
        var firstUserMessage: String?
        var messages: [String] = []
        var hasUserMessage = false
        var sessionSource: Any?

        mutating func appendMessage(_ message: String) {
            messages.append(message)
            if messages.count > 20 {
                messages.removeFirst(messages.count - 20)
            }
        }
    }

    private static let headReadLimit = 512 * 1_024
    private static let tailReadLimit = 1_024 * 1_024
    private let queue = DispatchQueue(label: "com.coverai.codex-notch-monitor.continuity", qos: .utility)
    private let homeDirectory: URL
    private let threadService: CodexThreadService
    private var envelopeCache: [String: CachedEnvelope] = [:]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        threadService: CodexThreadService
    ) {
        self.homeDirectory = homeDirectory
        self.threadService = threadService
    }

    func fetch(
        progress: ((Int, Int) -> Void)? = nil,
        completion: @escaping (Result<SessionContinuitySnapshot, Error>) -> Void
    ) {
        let group = DispatchGroup()
        let lock = NSLock()
        var local: (threads: [LocalThreadRecord], unreadable: Int)?
        var visibleResult: Result<Set<String>, Error>?

        group.enter()
        queue.async {
            let scanned = self.scanLocalThreads(progress: progress)
            lock.lock()
            local = scanned
            lock.unlock()
            group.leave()
        }

        group.enter()
        threadService.listThreadIDs(useStateDBOnly: true) { result in
            lock.lock()
            visibleResult = result
            lock.unlock()
            group.leave()
        }

        group.notify(queue: .main) {
            lock.lock()
            let scanned = local
            let visibility = visibleResult
            lock.unlock()
            guard let scanned, let visibility else {
                completion(.failure(CodexAppServerClient.ProtocolError(
                    message: "会话盘点结果不完整"
                )))
                return
            }
            completion(visibility.map { visibleIDs in
                let threads = scanned.threads.map { thread -> LocalThreadRecord in
                    var value = thread
                    if thread.kind != .userConversation {
                        value.visibility = .internalThread
                    } else if !FileManager.default.fileExists(atPath: thread.projectPath) {
                        value.visibility = .projectPathMissing
                    } else {
                        value.visibility = visibleIDs.contains(thread.id) ? .visible : .localOnly
                    }
                    return value
                }.sorted { $0.updatedAt > $1.updatedAt }
                return SessionContinuitySnapshot(
                    threads: threads,
                    unreadableFileCount: scanned.unreadable,
                    checkedAt: Date()
                )
            })
        }
    }

    static func parseThreadEnvelope(at url: URL) -> ThreadEnvelope? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }

        do {
            var accumulator = EnvelopeAccumulator()
            var bytesRead = 0
            let combinedLimit = headReadLimit + tailReadLimit
            if size <= combinedLimit {
                let data = try handle.read(upToCount: size) ?? Data()
                bytesRead = data.count
                parseEnvelopeLines(data, droppingLeadingPartialLine: false, into: &accumulator)
            } else {
                let head = try handle.read(upToCount: headReadLimit) ?? Data()
                bytesRead += head.count
                parseEnvelopeLines(head, droppingLeadingPartialLine: false, into: &accumulator)

                try handle.seek(toOffset: UInt64(size - tailReadLimit))
                let tail = try handle.read(upToCount: tailReadLimit) ?? Data()
                bytesRead += tail.count
                parseEnvelopeLines(tail, droppingLeadingPartialLine: true, into: &accumulator)
            }

            guard let id = accumulator.sessionID,
                  let path = accumulator.cwd,
                  !path.isEmpty
            else { return nil }
            return ThreadEnvelope(
                id: id,
                originalPath: path,
                timestamp: accumulator.timestamp,
                gitBranch: accumulator.gitBranch,
                firstUserMessage: accumulator.firstUserMessage,
                readableMessages: accumulator.messages,
                kind: threadKind(
                    source: accumulator.sessionSource,
                    hasUserMessage: accumulator.hasUserMessage
                ),
                bytesRead: bytesRead
            )
        } catch {
            return nil
        }
    }

    private static func parseEnvelopeLines(
        _ source: Data,
        droppingLeadingPartialLine: Bool,
        into accumulator: inout EnvelopeAccumulator
    ) {
        var data = source
        if droppingLeadingPartialLine, let newline = data.firstIndex(of: 0x0A) {
            data.removeSubrange(...newline)
        }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any]
            else { continue }

            if type == "session_meta", accumulator.sessionID == nil {
                accumulator.sessionID = (payload["id"] as? String) ?? (payload["session_id"] as? String)
                accumulator.cwd = payload["cwd"] as? String
                if let raw = object["timestamp"] as? String {
                    accumulator.timestamp = parseDate(raw)
                }
                if let git = payload["git"] as? [String: Any] {
                    accumulator.gitBranch = git["branch"] as? String
                }
                accumulator.sessionSource = payload["source"]
            } else if type == "event_msg", let eventType = payload["type"] as? String {
                if eventType == "user_message", let message = payload["message"] as? String {
                    accumulator.hasUserMessage = true
                    if accumulator.firstUserMessage == nil { accumulator.firstUserMessage = message }
                    accumulator.appendMessage("用户：\(message)")
                } else if eventType == "agent_message", let message = payload["message"] as? String {
                    accumulator.appendMessage("助手：\(message)")
                }
            }
        }
    }

    static func handoffContext(for thread: LocalThreadRecord) -> String {
        let recent = thread.readableMessages.suffix(10)
        var sections = [
            "# Codex 会话交接摘要",
            "",
            "来源会话：\(thread.title)",
            "来源线程：\(thread.id)",
            "项目：\(thread.projectName)",
            "目录：\(thread.projectPath)",
        ]
        if let branch = thread.gitBranch, !branch.isEmpty {
            sections.append("分支：\(branch)")
        }
        sections.append(contentsOf: [
            "",
            "## 最近可读上下文",
            "",
        ])
        for message in recent {
            sections.append("- \(redactSensitiveText(message))")
        }
        sections.append(contentsOf: [
            "",
            "## 继续前检查",
            "",
            "请先检查当前项目和 Git 状态，再根据上述本地上下文继续。不要假设旧会话的工作已在当前工作区生效。",
        ])
        return sections.joined(separator: "\n")
    }

    static func redactSensitiveText(_ text: String, limit: Int? = 700) -> String {
        var result = text.replacingOccurrences(
            of: #"(?i)(api[_-]?key|access[_-]?token|refresh[_-]?token|authorization|cookie|password)\s*[:=]\s*(?:Bearer\s+)?[^\s,;]+"#,
            with: "$1=[REDACTED]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\b(sk-[A-Za-z0-9_-]{12,}|gh[opusr]_[A-Za-z0-9]{12,})\b"#,
            with: "[REDACTED]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{12,}"#,
            with: "Bearer [REDACTED]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\bAKIA[A-Z0-9]{16}\b"#,
            with: "[REDACTED]",
            options: .regularExpression
        )
        if let limit, result.count > limit { result = String(result.prefix(limit)) + "…" }
        return result
    }

    static func threadKind(source: Any?, hasUserMessage: Bool) -> LocalThreadKind {
        if let source = source as? [String: Any], source["subagent"] != nil {
            return .subagent
        }
        return hasUserMessage ? .userConversation : .system
    }

    private func scanLocalThreads(
        progress: ((Int, Int) -> Void)?
    ) -> (threads: [LocalThreadRecord], unreadable: Int) {
        let codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let liveRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
        let archivedRoot = codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
        let indexNames = loadThreadNames(from: codexHome.appendingPathComponent("session_index.jsonl"))
        let catalog = CodexProjectCatalog.loadState(
            from: codexHome.appendingPathComponent(".codex-global-state.json")
        )
        let liveFiles = jsonlFiles(in: liveRoot)
        let archivedFiles = jsonlFiles(in: archivedRoot)
        var unreadable = 0
        var byID: [String: LocalThreadRecord] = [:]

        let files = liveFiles.map({ ($0, false) }) + archivedFiles.map({ ($0, true) })
        var activeCacheKeys = Set<String>()
        for (index, item) in files.enumerated() {
            let (file, archived) = item
            defer { DispatchQueue.main.async { progress?(index + 1, files.count) } }
            activeCacheKeys.insert(file.path)
            guard let record = parseThread(
                file,
                archived: archived,
                title: indexNames,
                catalog: catalog
            ) else {
                unreadable += 1
                continue
            }
            if let existing = byID[record.id], existing.updatedAt >= record.updatedAt { continue }
            byID[record.id] = record
        }
        envelopeCache = envelopeCache.filter { activeCacheKeys.contains($0.key) }
        return (Array(byID.values), unreadable)
    }

    private func parseThread(
        _ url: URL,
        archived: Bool,
        title names: [String: String],
        catalog: CodexProjectCatalog.State
    ) -> LocalThreadRecord? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize
        else { return nil }
        let signature = FileSignature(size: size, modifiedAt: values.contentModificationDate)
        let envelope: ThreadEnvelope
        if let cached = envelopeCache[url.path], cached.signature == signature {
            envelope = cached.envelope
        } else {
            guard let parsed = Self.parseThreadEnvelope(at: url) else { return nil }
            envelopeCache[url.path] = CachedEnvelope(signature: signature, envelope: parsed)
            envelope = parsed
        }

        let id = envelope.id
        let originalPath = envelope.originalPath
        let assignment = catalog.assignmentsByThread[id]
        let projectPath = assignment?.path ?? URL(fileURLWithPath: originalPath).standardizedFileURL.path
        let projectName = assignment?.projectName
            ?? CodexProjectCatalog.displayName(for: projectPath, namesByPath: catalog.namesByPath)
            ?? URL(fileURLWithPath: projectPath).lastPathComponent
        let fallbackTitle = envelope.firstUserMessage.map { String($0.prefix(60)) }
            ?? "Codex 会话"
        let updatedAt = values.contentModificationDate
            ?? envelope.timestamp
            ?? .distantPast
        return LocalThreadRecord(
            id: id,
            title: names[id] ?? fallbackTitle,
            projectName: projectName.isEmpty ? "未命名项目" : projectName,
            projectPath: projectPath,
            rolloutURL: url,
            isArchived: archived,
            updatedAt: updatedAt,
            gitBranch: envelope.gitBranch,
            readableMessages: envelope.readableMessages,
            kind: envelope.kind,
            ownership: .unknown,
            visibility: .localOnly
        )
    }

    private func loadThreadNames(from url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return text.split(separator: "\n").reduce(into: [:]) { result, line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  let name = object["thread_name"] as? String,
                  !name.isEmpty
            else { return }
            result[id] = name
        }
    }

    private func jsonlFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { value -> URL? in
            guard let url = value as? URL, url.pathExtension == "jsonl" else { return nil }
            return url
        }
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}
