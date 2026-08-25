import CryptoKit
import Foundation

enum SessionImportDuplicateStrategy: String, CaseIterable, Equatable {
    case skip
    case duplicate

    var title: String {
        switch self {
        case .skip: return "恢复原 ID，跳过已存在会话（推荐）"
        case .duplicate: return "全部生成新 ID 并作为副本导入"
        }
    }
}

struct SessionImportConflict: Equatable, Identifiable {
    let threadID: String
    let jsonlExists: Bool
    let stateDatabaseExists: Bool
    let catalogExists: Bool
    let projectBindingExists: Bool
    let permissionPreferenceExists: Bool
    let pendingCleanupExists: Bool

    var id: String { threadID }
    var isExistingSession: Bool { jsonlExists || stateDatabaseExists }
    var hasResidue: Bool {
        catalogExists || projectBindingExists || permissionPreferenceExists || pendingCleanupExists
    }
    var hasAnyConflict: Bool { isExistingSession || hasResidue }
}

struct SessionImportArchiveStatistics: Equatable {
    let archiveBytes: Int64
    let entryCount: Int
    let expandedBytes: Int64
    let largestEntryBytes: Int64
}

enum SessionImportStage: String, Equatable {
    case validating
    case backingUp
    case cleaningConflicts
    case importing
    case binding
    case rebuilding
    case checkingVisibility
    case completed
    case cancelling

    var title: String {
        switch self {
        case .validating: return "正在重新校验备份"
        case .backingUp: return "正在备份当前状态"
        case .cleaningConflicts: return "正在清理原 ID 残留"
        case .importing: return "正在导入会话"
        case .binding: return "正在写入项目绑定"
        case .rebuilding: return "正在重建 Codex 索引"
        case .checkingVisibility: return "正在确认 App Server 可见性"
        case .completed: return "导入完成"
        case .cancelling: return "正在取消并回滚"
        }
    }
}

struct SessionImportProgress: Equatable {
    let stage: SessionImportStage
    let completed: Int
    let total: Int
    let currentItem: String?

    var fraction: Double {
        guard total > 0 else { return stage == .completed ? 1 : 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

final class SessionImportCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

enum SessionImportVisibilityStatus: Equatable {
    case notChecked
    case visible(Int, expected: Int)
    case rebuildFailed(String)
}

struct SessionImportOutcome: Equatable {
    let result: SessionImportResult
    let visibility: SessionImportVisibilityStatus

    var requiresRetry: Bool {
        switch visibility {
        case .notChecked, .rebuildFailed: return true
        case let .visible(count, expected): return count < expected
        }
    }
}

struct SessionImportLimits: Equatable {
    var maximumArchiveBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    var maximumEntries = 1_000
    var maximumExpandedBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
    var maximumSingleEntryBytes: Int64 = 1 * 1_024 * 1_024 * 1_024
    var maximumCompressionRatio = 200.0
}

struct SessionImportPreview: Equatable {
    let bundleURL: URL
    let manifest: SessionPortableManifest
    let duplicateThreadIDs: Set<String>
    let missingOriginalPath: Bool
    let conflicts: [SessionImportConflict]
    let archiveStatistics: SessionImportArchiveStatistics
    let destinationIsWritable: Bool
    let codexIsRunning: Bool

    var sessionCount: Int { manifest.sessions.count }
    var activeCount: Int { manifest.sessions.filter { !$0.archived }.count }
    var archivedCount: Int { manifest.sessions.filter(\.archived).count }
    var duplicateCount: Int { duplicateThreadIDs.count }
    var conflictCount: Int { conflicts.filter(\.hasAnyConflict).count }
    var requiresPathMapping: Bool { missingOriginalPath }
}

struct SessionImportResult: Equatable {
    let requestedCount: Int
    let importedCount: Int
    let skippedDuplicateCount: Int
    let importedThreadIDs: Set<String>
    let backupURL: URL
    let projectBindingsAdded: Int
}

final class SessionImportService: @unchecked Sendable {
    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct TransactionFile: Codable, Equatable {
        let originalPath: String
        let existed: Bool
        let backupName: String?
        let size: Int?
        let sha256: String?
    }

    private struct TransactionManifest: Codable, Equatable {
        let version: Int
        let createdAt: Date
        let sourceBundle: String
        let createdFiles: [String]
        let managedFiles: [TransactionFile]
    }

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let backupRoot: URL
    private let now: () -> Date
    private let codexIsRunning: () -> Bool
    private let pendingCleanupURL: URL
    private let limits: SessionImportLimits

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupRoot: URL = AppPaths.continuityBackups,
        pendingCleanupURL: URL = AppPaths.pendingSidebarCleanups,
        limits: SessionImportLimits = SessionImportLimits(),
        now: @escaping () -> Date = Date.init,
        codexIsRunning: @escaping () -> Bool = SessionRecoveryService.isCodexDesktopRunning
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.backupRoot = backupRoot
        self.now = now
        self.codexIsRunning = codexIsRunning
        self.pendingCleanupURL = pendingCleanupURL
        self.limits = limits
    }

    func inspect(bundleURL: URL, existingThreadIDs: Set<String>) throws -> SessionImportPreview {
        guard bundleURL.pathExtension.lowercased() == "codexmonitorbundle" else {
            throw ImportError(message: "请选择 .codexmonitorbundle 会话备份")
        }
        let extracted = try extractAndValidateArchive(at: bundleURL)
        defer { try? fileManager.removeItem(at: extracted.root) }
        let localIDs = (try? localThreadIDs()) ?? []
        let allJSONLIDs = existingThreadIDs.union(localIDs)
        let conflicts = try extracted.manifest.sessions.map { session in
            try conflict(threadID: session.threadID, jsonlExists: allJSONLIDs.contains(session.threadID))
        }
        let originalProject = URL(fileURLWithPath: extracted.manifest.project.originalPath, isDirectory: true)
        let projectExists = isExistingDirectory(originalProject.path)
        return SessionImportPreview(
            bundleURL: bundleURL,
            manifest: extracted.manifest,
            duplicateThreadIDs: Set(conflicts.filter { $0.isExistingSession }.map { $0.threadID }),
            missingOriginalPath: !projectExists,
            conflicts: conflicts,
            archiveStatistics: extracted.statistics,
            destinationIsWritable: projectExists && isWritableDirectory(originalProject),
            codexIsRunning: codexIsRunning()
        )
    }

    func importBundle(
        preview: SessionImportPreview,
        mappedProjectURL: URL?,
        duplicateStrategy: SessionImportDuplicateStrategy,
        pathReplacements: [String: String] = [:],
        restoreArchivedAsActive: Bool = false,
        progress: ((SessionImportProgress) -> Void)? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> SessionImportResult {
        guard !codexIsRunning() else {
            throw ImportError(message: "请先使用 Cmd + Q 完全退出 Codex／ChatGPT Desktop，再导入会话")
        }

        try checkCancellation(isCancelled)
        progress?(SessionImportProgress(stage: .validating, completed: 0, total: preview.sessionCount, currentItem: nil))
        let existingIDs = try localThreadIDs()
        let currentPreview = try inspect(bundleURL: preview.bundleURL, existingThreadIDs: existingIDs)
        let destinationProjectURL: URL
        if let mappedProjectURL {
            let values = try mappedProjectURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw ImportError(message: "导入目标必须是已存在的项目文件夹")
            }
            destinationProjectURL = mappedProjectURL.standardizedFileURL
        } else if !currentPreview.requiresPathMapping {
            destinationProjectURL = URL(fileURLWithPath: currentPreview.manifest.project.originalPath)
                .standardizedFileURL
        } else {
            throw ImportError(message: "请先选择要导入到的 Codex 项目")
        }
        guard isWritableDirectory(destinationProjectURL) else {
            throw ImportError(message: "目标项目目录不可写：\(destinationProjectURL.path)")
        }

        try checkCancellation(isCancelled)
        let extracted = try extractAndValidateArchive(at: preview.bundleURL)
        defer { try? fileManager.removeItem(at: extracted.root) }
        progress?(SessionImportProgress(stage: .backingUp, completed: 0, total: preview.sessionCount, currentItem: nil))
        let backupURL = try createTransactionBackup(sourceBundle: preview.bundleURL)
        var createdFiles: [URL] = []
        var importedRecords: [LocalThreadRecord] = []
        var skipped = 0

        do {
            for (index, session) in extracted.manifest.sessions.enumerated() {
                try checkCancellation(isCancelled)
                let conflict = try conflict(
                    threadID: session.threadID,
                    jsonlExists: existingIDs.contains(session.threadID)
                )
                let isDuplicate = conflict.isExistingSession
                if isDuplicate, duplicateStrategy == .skip {
                    skipped += 1
                    progress?(SessionImportProgress(
                        stage: .importing,
                        completed: index + 1,
                        total: extracted.manifest.sessions.count,
                        currentItem: "已跳过：\(session.title)"
                    ))
                    continue
                }
                if duplicateStrategy == .skip, conflict.hasResidue {
                    progress?(SessionImportProgress(
                        stage: .cleaningConflicts,
                        completed: index,
                        total: extracted.manifest.sessions.count,
                        currentItem: session.title
                    ))
                    try cleanupResidue(for: session)
                }
                let importedID = duplicateStrategy == .duplicate
                    ? UUID().uuidString.lowercased()
                    : session.threadID
                let source = extracted.root.appendingPathComponent(session.rolloutPath)
                let importsAsArchived = session.archived && !restoreArchivedAsActive
                let destination = destinationURL(
                    for: session,
                    importedID: importedID,
                    archived: importsAsArchived
                )
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw ImportError(message: "目标会话文件已存在：\(destination.lastPathComponent)")
                }
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let needsRewrite = importedID != session.threadID
                    || destinationProjectURL.path != URL(fileURLWithPath: session.originalCwd).standardizedFileURL.path
                    || !pathReplacements.isEmpty
                if needsRewrite {
                    try rewriteJSONL(
                        source: source,
                        destination: destination,
                        originalID: session.threadID,
                        importedID: importedID,
                        originalCwd: session.originalCwd,
                        importedCwd: destinationProjectURL.path,
                        pathReplacements: pathReplacements,
                        isCancelled: isCancelled
                    )
                } else {
                    try fileManager.copyItem(at: source, to: destination)
                }
                createdFiles.append(destination)
                importedRecords.append(LocalThreadRecord(
                    id: importedID,
                    title: session.title,
                    projectName: destinationProjectURL.lastPathComponent,
                    projectPath: destinationProjectURL.path,
                    rolloutURL: destination,
                    isArchived: importsAsArchived,
                    updatedAt: Self.parseDate(session.updatedAt) ?? now(),
                    gitBranch: session.gitBranch,
                    readableMessages: [],
                    kind: .userConversation,
                    ownership: .unknown,
                    visibility: .localOnly
                ))
                progress?(SessionImportProgress(
                    stage: .importing,
                    completed: index + 1,
                    total: extracted.manifest.sessions.count,
                    currentItem: session.title
                ))
            }

            try checkCancellation(isCancelled)
            progress?(SessionImportProgress(
                stage: .binding,
                completed: importedRecords.count,
                total: extracted.manifest.sessions.count,
                currentItem: destinationProjectURL.lastPathComponent
            ))
            let bindings = try addProjectBindings(for: importedRecords)
            try finishTransactionBackup(at: backupURL, createdFiles: createdFiles)
            return SessionImportResult(
                requestedCount: extracted.manifest.sessions.count,
                importedCount: importedRecords.count,
                skippedDuplicateCount: skipped,
                importedThreadIDs: Set(importedRecords.map(\.id)),
                backupURL: backupURL,
                projectBindingsAdded: bindings
            )
        } catch {
            try? rollbackTransaction(at: backupURL, createdFilesOverride: createdFiles)
            throw error
        }
    }

    func rollbackImport(at backupURL: URL) throws {
        guard !codexIsRunning() else {
            throw ImportError(message: "请先完全退出 Codex／ChatGPT Desktop，再撤销导入")
        }
        try rollbackTransaction(at: backupURL, createdFilesOverride: nil)
    }

    private func extractAndValidateArchive(
        at bundleURL: URL
    ) throws -> (root: URL, manifest: SessionPortableManifest, statistics: SessionImportArchiveStatistics) {
        let inspection = try inspectArchive(at: bundleURL)
        let entries = inspection.entries
        guard !entries.isEmpty else { throw ImportError(message: "备份包为空") }
        for entry in entries {
            let normalized = entry.replacingOccurrences(of: "\\", with: "/")
            let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
            guard !normalized.hasPrefix("/"), !components.contains(".."), !components.contains(".") else {
                throw ImportError(message: "备份包包含不安全路径：\(entry)")
            }
        }

        let root = fileManager.temporaryDirectory
            .appendingPathComponent("codex-monitor-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try runDittoExtract(bundleURL, to: root)
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey]
            ) else { throw ImportError(message: "无法读取备份包") }
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    throw ImportError(message: "备份包不允许包含符号链接")
                }
            }

            let decoder = JSONDecoder()
            let manifestURL = root.appendingPathComponent("manifest.json")
            let checksumURL = root.appendingPathComponent("checksums.json")
            let manifestData = try Data(contentsOf: manifestURL)
            let manifest = try decoder.decode(SessionPortableManifest.self, from: manifestData)
            guard manifest.format == SessionPortableManifest.supportedFormat else {
                throw ImportError(message: "不支持的备份格式：\(manifest.format)")
            }
            guard !manifest.sessions.isEmpty else { throw ImportError(message: "备份中没有用户会话") }
            let checksums = try decoder.decode(
                SessionPortableChecksums.self,
                from: Data(contentsOf: checksumURL)
            )
            guard checksums.algorithm.uppercased() == "SHA-256" else {
                throw ImportError(message: "备份包使用了不支持的校验算法")
            }
            for (relativePath, expectedDigest) in checksums.files {
                guard Self.isSafeRelativePath(relativePath) else {
                    throw ImportError(message: "校验清单包含不安全路径")
                }
                let file = root.appendingPathComponent(relativePath)
                guard fileManager.fileExists(atPath: file.path),
                      try Self.sha256(of: file) == expectedDigest
                else { throw ImportError(message: "\(relativePath) 完整性校验失败") }
            }

            var ids = Set<String>()
            var paths = Set<String>()
            for session in manifest.sessions {
                guard ids.insert(session.threadID).inserted else {
                    throw ImportError(message: "备份中存在重复会话 ID：\(session.threadID)")
                }
                guard Self.isValidThreadID(session.threadID) else {
                    throw ImportError(message: "备份中的会话 ID 无效")
                }
                guard paths.insert(session.rolloutPath).inserted,
                      Self.isAllowedRolloutPath(session.rolloutPath, archived: session.archived)
                else { throw ImportError(message: "备份中的会话路径无效") }
                let rollout = root.appendingPathComponent(session.rolloutPath)
                guard fileManager.fileExists(atPath: rollout.path) else {
                    throw ImportError(message: "备份缺少会话文件：\(session.rolloutPath)")
                }
                let digest = try Self.sha256(of: rollout)
                guard digest == session.sha256,
                      checksums.files[session.rolloutPath] == digest
                else { throw ImportError(message: "会话文件校验失败：\(session.title)") }
                guard let envelope = SessionContinuityService.parseThreadEnvelope(at: rollout),
                      envelope.id == session.threadID
                else {
                    throw ImportError(message: "会话文件与 Manifest ID 不一致：\(session.title)")
                }
                guard URL(fileURLWithPath: envelope.originalPath).standardizedFileURL.path
                    == URL(fileURLWithPath: session.originalCwd).standardizedFileURL.path
                else { throw ImportError(message: "会话文件与 Manifest 项目路径不一致：\(session.title)") }
            }
            return (root, manifest, inspection.statistics)
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    private func localThreadIDs() throws -> Set<String> {
        let codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let roots = [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
        var ids = Set<String>()
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                if let id = SessionContinuityService.parseThreadEnvelope(at: url)?.id { ids.insert(id) }
            }
        }
        return ids
    }

    private func destinationURL(
        for session: SessionPortableManifest.Session,
        importedID: String,
        archived: Bool
    ) -> URL {
        let codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let root: URL
        if archived {
            root = codexHome.appendingPathComponent("archived_sessions", isDirectory: true)
        } else {
            let date = Self.parseDate(session.updatedAt) ?? now()
            let calendar = Calendar(identifier: .gregorian)
            let parts = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
            root = codexHome
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(String(format: "%04d", parts.year ?? 1970), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", parts.month ?? 1), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", parts.day ?? 1), isDirectory: true)
        }
        let date = Self.parseDate(session.updatedAt) ?? now()
        return root.appendingPathComponent(
            Self.canonicalRolloutFilename(threadID: importedID, date: date)
        )
    }

    static func canonicalRolloutFilename(threadID: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return "rollout-\(formatter.string(from: date))-\(threadID).jsonl"
    }

    private func rewriteJSONL(
        source: URL,
        destination: URL,
        originalID: String,
        importedID: String,
        originalCwd: String,
        importedCwd: String,
        pathReplacements: [String: String],
        isCancelled: () -> Bool
    ) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw ImportError(message: "无法创建导入临时文件")
        }
        defer { try? fileManager.removeItem(at: temporary) }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: temporary)
        defer {
            try? input.close()
            try? output.close()
        }
        var buffer = Data()
        while true {
            try checkCancellation(isCancelled)
            let chunk = try input.read(upToCount: 256 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                try writeRewrittenLine(
                    Data(buffer[..<newline]),
                    to: output,
                    originalID: originalID,
                    importedID: importedID,
                    originalCwd: originalCwd,
                    importedCwd: importedCwd,
                    pathReplacements: pathReplacements
                )
                buffer.removeSubrange(...newline)
            }
        }
        if !buffer.isEmpty {
            try writeRewrittenLine(
                buffer,
                to: output,
                originalID: originalID,
                importedID: importedID,
                originalCwd: originalCwd,
                importedCwd: importedCwd,
                pathReplacements: pathReplacements
            )
        }
        try output.synchronize()
        try output.close()
        try fileManager.moveItem(at: temporary, to: destination)
    }

    private func writeRewrittenLine(
        _ line: Data,
        to output: FileHandle,
        originalID: String,
        importedID: String,
        originalCwd: String,
        importedCwd: String,
        pathReplacements: [String: String]
    ) throws {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line)
        else { throw ImportError(message: "会话 JSONL 包含无法解析的记录") }
        let rewritten = Self.rewriteValue(
            object,
            originalID: originalID,
            importedID: importedID,
            originalCwd: originalCwd,
            importedCwd: importedCwd,
            pathReplacements: pathReplacements
        )
        var data = try JSONSerialization.data(withJSONObject: rewritten)
        data.append(0x0A)
        try output.write(contentsOf: data)
    }

    private func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func isWritableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && fileManager.isWritableFile(atPath: url.path)
    }

    private func checkCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() { throw ImportError(message: "导入已取消，已回滚本次写入") }
    }

    private func cleanupResidue(for session: SessionPortableManifest.Session) throws {
        let cleanup = CodexSidebarCleanupService(
            homeDirectory: homeDirectory,
            pendingURL: pendingCleanupURL,
            backupRoot: backupRoot.appendingPathComponent("sidebar-cleanups", isDirectory: true),
            fileManager: fileManager,
            now: now,
            codexIsRunning: codexIsRunning
        )
        _ = try cleanup.cleanupForValidation(
            threadID: session.threadID,
            title: session.title,
            allowWhileCodexIsRunning: false
        )
    }

    private func conflict(threadID: String, jsonlExists: Bool) throws -> SessionImportConflict {
        let codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let stateURL = codexHome.appendingPathComponent("state_5.sqlite")
        let catalogURL = codexHome.appendingPathComponent("sqlite/codex-dev.db")
        let globalStateURL = codexHome.appendingPathComponent(".codex-global-state.json")
        let stateDatabaseExists = try sqliteContainsThread(
            database: stateURL,
            tables: ["threads", "thread"],
            threadID: threadID
        )
        let catalogExists = try sqliteContainsThread(
            database: catalogURL,
            tables: ["local_thread_catalog"],
            threadID: threadID
        )
        var projectBindingExists = false
        var permissionPreferenceExists = false
        if fileManager.fileExists(atPath: globalStateURL.path) {
            let data = try Data(contentsOf: globalStateURL)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ImportError(message: "Codex 全局状态不是有效 JSON 对象")
            }
            projectBindingExists = (root["thread-project-assignments"] as? [String: Any])?[threadID] != nil
            let atoms = root["electron-persisted-atom-state"] as? [String: Any]
            permissionPreferenceExists = (atoms?["heartbeat-thread-permissions-by-id"] as? [String: Any])?[threadID] != nil
        }
        let pendingCleanupExists = try loadPendingCleanupIDs().contains(threadID)
        return SessionImportConflict(
            threadID: threadID,
            jsonlExists: jsonlExists,
            stateDatabaseExists: stateDatabaseExists,
            catalogExists: catalogExists,
            projectBindingExists: projectBindingExists,
            permissionPreferenceExists: permissionPreferenceExists,
            pendingCleanupExists: pendingCleanupExists
        )
    }

    private func loadPendingCleanupIDs() throws -> Set<String> {
        guard fileManager.fileExists(atPath: pendingCleanupURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pending = try decoder.decode(
            [PendingCodexSidebarCleanup].self,
            from: Data(contentsOf: pendingCleanupURL)
        )
        return Set(pending.map(\.threadID))
    }

    private func sqliteContainsThread(
        database: URL,
        tables: [String],
        threadID: String
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: database.path) else { return false }
        let availableTables = try sqliteOutput(
            database: database,
            sql: "SELECT name FROM sqlite_master WHERE type='table';"
        ).split(whereSeparator: \.isNewline).map(String.init)
        for table in tables where availableTables.contains(table) {
            let columns = try sqliteOutput(
                database: database,
                sql: "SELECT name FROM pragma_table_info('\(table)');"
            ).split(whereSeparator: \.isNewline).map(String.init)
            guard let idColumn = ["thread_id", "id"].first(where: columns.contains) else { continue }
            let safeID = threadID.replacingOccurrences(of: "'", with: "''")
            let value = try sqliteOutput(
                database: database,
                sql: "PRAGMA query_only=ON; SELECT EXISTS(SELECT 1 FROM \(table) WHERE \(idColumn)='\(safeID)');"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if value == "1" { return true }
        }
        return false
    }

    private func sqliteOutput(database: URL, sql: String) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ImportError(message: detail?.isEmpty == false ? detail! : "无法读取 Codex 本地索引")
        }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private static func rewriteValue(
        _ value: Any,
        originalID: String,
        importedID: String,
        originalCwd: String,
        importedCwd: String,
        pathReplacements: [String: String],
        key: String? = nil
    ) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                let currentKey = entry.key
                result[currentKey] = rewriteValue(
                    entry.value,
                    originalID: originalID,
                    importedID: importedID,
                    originalCwd: originalCwd,
                    importedCwd: importedCwd,
                    pathReplacements: pathReplacements,
                    key: currentKey
                )
            }
        }
        if let array = value as? [Any] {
            return array.map {
                rewriteValue(
                    $0,
                    originalID: originalID,
                    importedID: importedID,
                    originalCwd: originalCwd,
                    importedCwd: importedCwd,
                    pathReplacements: pathReplacements
                )
            }
        }
        if let string = value as? String {
            if (key == "id" || key == "session_id"), string == originalID { return importedID }
            if key == "cwd", URL(fileURLWithPath: string).standardizedFileURL.path
                == URL(fileURLWithPath: originalCwd).standardizedFileURL.path { return importedCwd }
            var replaced = string
            for (source, destination) in pathReplacements where replaced.contains(source) {
                replaced = replaced.replacingOccurrences(of: source, with: destination)
            }
            if replaced != string { return replaced }
        }
        return value
    }

    private func createTransactionBackup(sourceBundle: URL) throws -> URL {
        let directory = backupRoot.appendingPathComponent("import-\(Self.timestamp(now()))", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let candidates = managedStateFiles(codexHome: codexHome)
        var managed: [TransactionFile] = []
        for (index, source) in candidates.enumerated() {
            guard fileManager.fileExists(atPath: source.path) else {
                managed.append(TransactionFile(
                    originalPath: source.path,
                    existed: false,
                    backupName: nil,
                    size: nil,
                    sha256: nil
                ))
                continue
            }
            let backupName = "state-\(index)-\(source.lastPathComponent)"
            let target = directory.appendingPathComponent(backupName)
            try fileManager.copyItem(at: source, to: target)
            let attributes = try fileManager.attributesOfItem(atPath: target.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            managed.append(TransactionFile(
                originalPath: source.path,
                existed: true,
                backupName: backupName,
                size: size,
                sha256: try Self.sha256(of: target)
            ))
        }
        let manifest = TransactionManifest(
            version: 1,
            createdAt: now(),
            sourceBundle: sourceBundle.lastPathComponent,
            createdFiles: [],
            managedFiles: managed
        )
        try Self.encoder.encode(manifest).write(
            to: directory.appendingPathComponent("import-manifest.json"),
            options: .atomic
        )
        return directory
    }

    private func finishTransactionBackup(at backupURL: URL, createdFiles: [URL]) throws {
        let url = backupURL.appendingPathComponent("import-manifest.json")
        let current = try Self.decoder.decode(TransactionManifest.self, from: Data(contentsOf: url))
        let finished = TransactionManifest(
            version: current.version,
            createdAt: current.createdAt,
            sourceBundle: current.sourceBundle,
            createdFiles: createdFiles.map(\.path),
            managedFiles: current.managedFiles
        )
        try Self.encoder.encode(finished).write(to: url, options: .atomic)
    }

    private func rollbackTransaction(at backupURL: URL, createdFilesOverride: [URL]?) throws {
        let manifest = try Self.decoder.decode(
            TransactionManifest.self,
            from: Data(contentsOf: backupURL.appendingPathComponent("import-manifest.json"))
        )
        guard manifest.version == 1 else { throw ImportError(message: "不支持的导入回滚格式") }
        for file in manifest.managedFiles where file.existed {
            guard let backupName = file.backupName,
                  let size = file.size,
                  let digest = file.sha256
            else { throw ImportError(message: "回滚备份清单不完整") }
            let source = backupURL.appendingPathComponent(backupName)
            let attributes = try fileManager.attributesOfItem(atPath: source.path)
            guard (attributes[.size] as? NSNumber)?.intValue == size,
                  try Self.sha256(of: source) == digest
            else { throw ImportError(message: "回滚备份校验失败：\(backupName)") }
        }
        let created = createdFilesOverride?.map(\.path) ?? manifest.createdFiles
        for path in created where fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
        for file in manifest.managedFiles {
            let destination = URL(fileURLWithPath: file.originalPath)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            guard file.existed,
                  let backupName = file.backupName,
                  file.size != nil,
                  file.sha256 != nil
            else { continue }
            let source = backupURL.appendingPathComponent(backupName)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    private func addProjectBindings(for threads: [LocalThreadRecord]) throws -> Int {
        guard !threads.isEmpty else { return 0 }
        let stateURL = homeDirectory.appendingPathComponent(".codex/.codex-global-state.json")
        guard let data = try? Data(contentsOf: stateURL) else { return 0 }
        let result = try SessionRecoveryService.addingExactProjectBindings(to: data, threads: threads)
        guard result.added > 0 else { return 0 }
        try result.data.write(to: stateURL, options: .atomic)
        return result.added
    }

    private func inspectArchive(
        at url: URL
    ) throws -> (entries: [String], statistics: SessionImportArchiveStatistics) {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let archiveBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard archiveBytes <= limits.maximumArchiveBytes else {
            throw ImportError(message: "备份包超过允许的压缩文件大小")
        }
        let entries = try archiveEntries(at: url)
        guard entries.count <= limits.maximumEntries else {
            throw ImportError(message: "备份包文件数过多（\(entries.count) / \(limits.maximumEntries)）")
        }
        let listing = try runUnzip(arguments: ["-Z", "-l", url.path])
        var expandedBytes: Int64 = 0
        var compressedBytes: Int64 = 0
        var largestEntryBytes: Int64 = 0
        for line in listing.split(whereSeparator: \.isNewline) {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 10,
                  let mode = columns.first,
                  mode.first == "-" || mode.first == "d" || mode.first == "l",
                  let expanded = Int64(columns[3]),
                  let compressed = Int64(columns[5])
            else { continue }
            expandedBytes += expanded
            compressedBytes += compressed
            largestEntryBytes = max(largestEntryBytes, expanded)
        }
        guard expandedBytes <= limits.maximumExpandedBytes else {
            throw ImportError(message: "备份包解压后超过允许的总大小")
        }
        guard largestEntryBytes <= limits.maximumSingleEntryBytes else {
            throw ImportError(message: "备份包包含过大的单个文件")
        }
        let ratio = compressedBytes > 0
            ? Double(expandedBytes) / Double(compressedBytes)
            : (expandedBytes > 0 ? .infinity : 1)
        guard ratio <= limits.maximumCompressionRatio else {
            throw ImportError(message: "备份包压缩比异常，已拒绝解压")
        }
        return (
            entries,
            SessionImportArchiveStatistics(
                archiveBytes: archiveBytes,
                entryCount: entries.count,
                expandedBytes: expandedBytes,
                largestEntryBytes: largestEntryBytes
            )
        )
    }

    private func archiveEntries(at url: URL) throws -> [String] {
        try runUnzip(arguments: ["-Z1", url.path])
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func runUnzip(arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ImportError(message: "无法读取备份包")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func runDittoExtract(_ source: URL, to destination: URL) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", "--noqtn", source.path, destination.path]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ImportError(message: detail.isEmpty ? "无法解压备份包" : detail)
        }
    }

    private func managedStateFiles(codexHome: URL) -> [URL] {
        [
            codexHome.appendingPathComponent("state_5.sqlite"),
            codexHome.appendingPathComponent("state_5.sqlite-wal"),
            codexHome.appendingPathComponent("state_5.sqlite-shm"),
            codexHome.appendingPathComponent("session_index.jsonl"),
            codexHome.appendingPathComponent(".codex-global-state.json"),
            codexHome.appendingPathComponent("sqlite/codex-dev.db"),
            codexHome.appendingPathComponent("sqlite/codex-dev.db-wal"),
            codexHome.appendingPathComponent("sqlite/codex-dev.db-shm"),
            pendingCleanupURL,
        ]
    }

    private static func isAllowedRolloutPath(_ value: String, archived: Bool) -> Bool {
        let prefix = archived ? "sessions/archived/" : "sessions/active/"
        guard value.hasPrefix(prefix), value.hasSuffix(".jsonl") else { return false }
        let remainder = value.dropFirst(prefix.count)
        return !remainder.isEmpty && !remainder.contains("/") && !remainder.contains("\\")
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return !normalized.hasPrefix("/")
            && !components.contains("..")
            && !components.contains(".")
            && !components.contains("")
    }

    private static func isValidThreadID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_" )).contains($0)
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct ImportedRolloutPathRepair: Equatable {
    let thread: LocalThreadRecord
    let originalURL: URL
    let repairedURL: URL
    let backupURL: URL
}

final class ImportedRolloutPathRepairService {
    struct RepairError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let fileManager: FileManager
    private let backupRoot: URL
    private let now: () -> Date

    init(
        fileManager: FileManager = .default,
        backupRoot: URL = AppPaths.continuityBackups
            .appendingPathComponent("rollout-path-repairs", isDirectory: true),
        now: @escaping () -> Date = Date.init
    ) {
        self.fileManager = fileManager
        self.backupRoot = backupRoot
        self.now = now
    }

    func prepareForDeletion(_ thread: LocalThreadRecord) throws -> ImportedRolloutPathRepair? {
        let originalURL = thread.rolloutURL
        guard originalURL.lastPathComponent.hasPrefix("rollout-import-") else { return nil }
        guard fileManager.fileExists(atPath: originalURL.path) else {
            throw RepairError(message: "找不到待删除的导入会话文件")
        }
        let envelopeDate = SessionContinuityService.parseThreadEnvelope(at: originalURL)?.timestamp
        let repairedURL = originalURL.deletingLastPathComponent().appendingPathComponent(
            SessionImportService.canonicalRolloutFilename(
                threadID: thread.id,
                date: envelopeDate ?? thread.updatedAt
            )
        )
        guard !fileManager.fileExists(atPath: repairedURL.path) else {
            throw RepairError(message: "标准 rollout 文件已存在，为避免覆盖已停止删除")
        }

        let directory = backupRoot.appendingPathComponent(
            "\(Self.timestamp(now()))-\(thread.id)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let backupURL = directory.appendingPathComponent(originalURL.lastPathComponent)
        try fileManager.copyItem(at: originalURL, to: backupURL)
        let manifest: [String: Any] = [
            "version": 1,
            "threadId": thread.id,
            "originalPath": originalURL.path,
            "repairedPath": repairedURL.path,
            "createdAt": ISO8601DateFormatter().string(from: now()),
        ]
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        do {
            try fileManager.moveItem(at: originalURL, to: repairedURL)
        } catch {
            throw RepairError(message: "导入会话文件名修复失败：\(error.localizedDescription)")
        }
        return ImportedRolloutPathRepair(
            thread: thread.withRolloutURL(repairedURL),
            originalURL: originalURL,
            repairedURL: repairedURL,
            backupURL: backupURL
        )
    }

    func rollback(_ repair: ImportedRolloutPathRepair) throws {
        guard fileManager.fileExists(atPath: repair.repairedURL.path),
              !fileManager.fileExists(atPath: repair.originalURL.path)
        else { return }
        try fileManager.moveItem(at: repair.repairedURL, to: repair.originalURL)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }
}

private extension LocalThreadRecord {
    func withRolloutURL(_ url: URL) -> LocalThreadRecord {
        LocalThreadRecord(
            id: id,
            title: title,
            projectName: projectName,
            projectPath: projectPath,
            rolloutURL: url,
            isArchived: isArchived,
            updatedAt: updatedAt,
            gitBranch: gitBranch,
            readableMessages: readableMessages,
            kind: kind,
            ownership: ownership,
            visibility: visibility
        )
    }
}
