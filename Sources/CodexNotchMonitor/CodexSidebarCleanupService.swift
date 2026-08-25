import AppKit
import CryptoKit
import Foundation

struct PendingCodexSidebarCleanup: Codable, Equatable, Identifiable {
    let threadID: String
    let title: String
    let requestedAt: Date

    var id: String { threadID }
}

struct CodexSidebarCleanupResult: Equatable {
    let threadID: String
    let removedProjectAssignment: Bool
    let removedPermissionPreference: Bool
    let removedCatalogEntry: Bool
    let backupURL: URL?
    let catalogBackupURL: URL?

    var removedAnything: Bool {
        removedProjectAssignment || removedPermissionPreference || removedCatalogEntry
    }
}

enum CodexSidebarCleanupDisposition: Equatable {
    case noResidue
    case queued
    case completed(CodexSidebarCleanupResult)
}

final class CodexSidebarCleanupService {
    struct CleanupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let fileManager: FileManager
    private let stateURL: URL
    private let catalogURL: URL
    private let pendingURL: URL
    private let backupRoot: URL
    private let now: () -> Date
    private let codexIsRunning: () -> Bool
    private let lock = NSLock()

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        pendingURL: URL = AppPaths.pendingSidebarCleanups,
        backupRoot: URL = AppPaths.sidebarCleanupBackups,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        codexIsRunning: @escaping () -> Bool = CodexSidebarCleanupService.isCodexDesktopRunning
    ) {
        self.fileManager = fileManager
        stateURL = homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent(".codex-global-state.json")
        catalogURL = homeDirectory
            .appendingPathComponent(".codex/sqlite", isDirectory: true)
            .appendingPathComponent("codex-dev.db")
        self.pendingURL = pendingURL
        self.backupRoot = backupRoot
        self.now = now
        self.codexIsRunning = codexIsRunning
    }

    func registerCleanup(
        threadID: String,
        title: String
    ) throws -> CodexSidebarCleanupDisposition {
        try lock.withLock {
            guard try containsResidue(threadID: threadID) else {
                removePending(threadID: threadID)
                return .noResidue
            }
            if codexIsRunning() {
                try upsertPending(threadID: threadID, title: title)
                return .queued
            }
            let result = try cleanupState(threadID: threadID, title: title)
            removePending(threadID: threadID)
            return .completed(result)
        }
    }

    func processPendingIfPossible() throws -> [CodexSidebarCleanupResult] {
        try lock.withLock {
            guard !codexIsRunning() else { return [] }
            var pending = try loadPending()
            var results: [CodexSidebarCleanupResult] = []
            var completedIDs = Set<String>()
            for item in pending {
                let result = try cleanupState(
                    threadID: item.threadID,
                    title: item.title
                )
                results.append(result)
                completedIDs.insert(item.threadID)
            }
            pending.removeAll { completedIDs.contains($0.threadID) }
            try savePending(pending)
            return results
        }
    }

    func pendingCount() -> Int {
        lock.withLock { (try? loadPending().count) ?? 0 }
    }

    func cleanupForValidation(
        threadID: String,
        title: String,
        allowWhileCodexIsRunning: Bool
    ) throws -> CodexSidebarCleanupResult {
        try lock.withLock {
            if codexIsRunning(), !allowWhileCodexIsRunning {
                throw CleanupError(message: "请先使用 Cmd + Q 完全退出 Codex／ChatGPT Desktop")
            }
            let result = try cleanupState(threadID: threadID, title: title)
            if !result.removedAnything || !codexIsRunning() {
                removePending(threadID: threadID)
            }
            return result
        }
    }

    private func cleanupState(
        threadID: String,
        title: String
    ) throws -> CodexSidebarCleanupResult {
        let originalData = fileManager.fileExists(atPath: stateURL.path)
            ? try Data(contentsOf: stateURL)
            : nil
        var root: [String: Any] = [:]
        if let originalData {
            guard let decoded = try JSONSerialization.jsonObject(with: originalData)
                as? [String: Any] else {
                throw CleanupError(message: "Codex 全局状态不是有效 JSON 对象")
            }
            root = decoded
        }

        var removedProjectAssignment = false
        if var assignments = root["thread-project-assignments"] as? [String: Any],
           assignments.removeValue(forKey: threadID) != nil {
            root["thread-project-assignments"] = assignments
            removedProjectAssignment = true
        }

        var removedPermissionPreference = false
        if var atoms = root["electron-persisted-atom-state"] as? [String: Any],
           var permissions = atoms["heartbeat-thread-permissions-by-id"] as? [String: Any],
           permissions.removeValue(forKey: threadID) != nil {
            atoms["heartbeat-thread-permissions-by-id"] = permissions
            root["electron-persisted-atom-state"] = atoms
            removedPermissionPreference = true
        }

        let removedCatalogEntry = try catalogContains(threadID: threadID)
        guard removedProjectAssignment
            || removedPermissionPreference
            || removedCatalogEntry else {
            return CodexSidebarCleanupResult(
                threadID: threadID,
                removedProjectAssignment: false,
                removedPermissionPreference: false,
                removedCatalogEntry: false,
                backupURL: nil,
                catalogBackupURL: nil
            )
        }

        let backupDirectory = try createBackupDirectory(
            threadID: threadID
        )
        let backupURL = try originalData.map {
            try backupState($0, in: backupDirectory)
        }
        let catalogBackupURL = removedCatalogEntry
            ? try backupCatalog(in: backupDirectory)
            : nil
        try writeManifest(
            in: backupDirectory,
            threadID: threadID,
            title: title,
            stateBackupURL: backupURL,
            catalogBackupURL: catalogBackupURL
        )

        do {
            if removedProjectAssignment || removedPermissionPreference {
                let updatedData = try JSONSerialization.data(
                    withJSONObject: root,
                    options: [.withoutEscapingSlashes]
                )
                let originalAttributes = try? fileManager.attributesOfItem(
                    atPath: stateURL.path
                )
                try updatedData.write(to: stateURL, options: .atomic)
                if let permissions = originalAttributes?[.posixPermissions] {
                    try? fileManager.setAttributes(
                        [.posixPermissions: permissions],
                        ofItemAtPath: stateURL.path
                    )
                }
            }
            if removedCatalogEntry {
                try deleteCatalogEntry(threadID: threadID)
            }
            guard !(try containsResidue(threadID: threadID)) else {
                throw CleanupError(message: "写入后仍检测到目标会话残留")
            }
        } catch {
            if let originalData {
                try? originalData.write(to: stateURL, options: .atomic)
            }
            if removedCatalogEntry, let catalogBackupURL {
                try? restoreCatalog(from: catalogBackupURL)
            }
            throw CleanupError(
                message: "侧栏状态清理失败，原文件已恢复：\(error.localizedDescription)"
            )
        }
        return CodexSidebarCleanupResult(
            threadID: threadID,
            removedProjectAssignment: removedProjectAssignment,
            removedPermissionPreference: removedPermissionPreference,
            removedCatalogEntry: removedCatalogEntry,
            backupURL: backupURL,
            catalogBackupURL: catalogBackupURL
        )
    }

    private func containsResidue(threadID: String) throws -> Bool {
        var globalResidue = false
        if fileManager.fileExists(atPath: stateURL.path) {
            let data = try Data(contentsOf: stateURL)
            guard let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
                throw CleanupError(message: "Codex 全局状态不是有效 JSON 对象")
            }
            let assignments = root["thread-project-assignments"] as? [String: Any]
            let atoms = root["electron-persisted-atom-state"] as? [String: Any]
            let permissions = atoms?["heartbeat-thread-permissions-by-id"]
                as? [String: Any]
            globalResidue = assignments?[threadID] != nil
                || permissions?[threadID] != nil
        }
        if globalResidue { return true }
        return try catalogContains(threadID: threadID)
    }

    private func createBackupDirectory(
        threadID: String
    ) throws -> URL {
        let directory = backupRoot.appendingPathComponent(
            "\(Self.timestamp(now()))-\(threadID)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func backupState(_ originalData: Data, in directory: URL) throws -> URL {
        let backupURL = directory.appendingPathComponent(
            ".codex-global-state.json"
        )
        try originalData.write(to: backupURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: backupURL.path
        )
        return backupURL
    }

    private func backupCatalog(in directory: URL) throws -> URL {
        guard fileManager.fileExists(atPath: catalogURL.path) else {
            throw CleanupError(message: "找不到 Codex 本地线程目录数据库")
        }
        let backupURL = directory.appendingPathComponent("codex-dev.db")
        _ = try runSQLite(
            database: catalogURL,
            command: ".backup '\(Self.sqlQuoted(backupURL.path))'"
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: backupURL.path
        )
        return backupURL
    }

    private func writeManifest(
        in directory: URL,
        threadID: String,
        title: String,
        stateBackupURL: URL?,
        catalogBackupURL: URL?
    ) throws {
        let manifest: [String: Any] = [
            "version": 1,
            "threadId": threadID,
            "title": title,
            "createdAt": ISO8601DateFormatter().string(from: now()),
            "globalState": stateBackupURL.map {
                ["sourcePath": stateURL.path, "backupName": $0.lastPathComponent,
                 "sha256": Self.sha256((try? Data(contentsOf: $0)) ?? Data())]
            } ?? NSNull(),
            "threadCatalog": catalogBackupURL.map {
                ["sourcePath": catalogURL.path, "backupName": $0.lastPathComponent,
                 "sha256": Self.sha256((try? Data(contentsOf: $0)) ?? Data())]
            } ?? NSNull(),
        ]
        let manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let manifestURL = directory.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifestURL.path
        )
    }

    private func catalogContains(threadID: String) throws -> Bool {
        guard fileManager.fileExists(atPath: catalogURL.path) else { return false }
        try Self.validateThreadID(threadID)
        let output = try runSQLite(
            database: catalogURL,
            command: "PRAGMA query_only=ON; SELECT EXISTS(SELECT 1 FROM local_thread_catalog WHERE host_id='local' AND thread_id='\(threadID)');"
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private func deleteCatalogEntry(threadID: String) throws {
        try Self.validateThreadID(threadID)
        _ = try runSQLite(
            database: catalogURL,
            command: "PRAGMA busy_timeout=5000; BEGIN IMMEDIATE; DELETE FROM local_thread_catalog WHERE host_id='local' AND thread_id='\(threadID)'; UPDATE local_thread_catalog_metadata SET catalog_revision = catalog_revision + 1 WHERE id = 1; COMMIT;"
        )
    }

    private func restoreCatalog(from backupURL: URL) throws {
        _ = try runSQLite(
            database: catalogURL,
            command: ".restore '\(Self.sqlQuoted(backupURL.path))'"
        )
    }

    private func runSQLite(database: URL, command: String) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, command]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CleanupError(
                message: detail?.isEmpty == false ? detail! : "SQLite 操作失败"
            )
        }
        return String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
    }

    private func upsertPending(threadID: String, title: String) throws {
        var pending = try loadPending()
        pending.removeAll { $0.threadID == threadID }
        pending.append(PendingCodexSidebarCleanup(
            threadID: threadID,
            title: title,
            requestedAt: now()
        ))
        try savePending(pending)
    }

    private func removePending(threadID: String) {
        guard var pending = try? loadPending() else { return }
        pending.removeAll { $0.threadID == threadID }
        try? savePending(pending)
    }

    private func loadPending() throws -> [PendingCodexSidebarCleanup] {
        guard fileManager.fileExists(atPath: pendingURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            [PendingCodexSidebarCleanup].self,
            from: Data(contentsOf: pendingURL)
        )
    }

    private func savePending(_ pending: [PendingCodexSidebarCleanup]) throws {
        try fileManager.createDirectory(
            at: pendingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(pending).write(to: pendingURL, options: .atomic)
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: pendingURL.path
        )
    }

    private static func isCodexDesktopRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            let name = app.localizedName?.lowercased() ?? ""
            let identifier = app.bundleIdentifier?.lowercased() ?? ""
            return name == "codex"
                || name == "chatgpt"
                || identifier == "com.openai.codex"
                || identifier == "com.openai.chat"
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func validateThreadID(_ threadID: String) throws {
        guard !threadID.isEmpty,
              threadID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else {
            throw CleanupError(message: "会话 ID 格式无效")
        }
    }

    private static func sqlQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct PendingCodexProjectCleanup: Codable, Equatable, Identifiable {
    let projectName: String
    let projectPath: String
    let requestedAt: Date

    var id: String { projectPath }
}

struct CodexProjectCleanupResult: Equatable {
    let projectPath: String
    let removedProjectCount: Int
    let backupURL: URL?
}

enum CodexProjectCleanupDisposition: Equatable {
    case queued
    case completed(CodexProjectCleanupResult)
}

final class CodexProjectCleanupService {
    struct CleanupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let fileManager: FileManager
    private let stateURL: URL
    private let pendingURL: URL
    private let backupRoot: URL
    private let now: () -> Date
    private let codexIsRunning: () -> Bool
    private let lock = NSLock()

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        pendingURL: URL = AppPaths.pendingProjectCleanups,
        backupRoot: URL = AppPaths.sidebarCleanupBackups,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        codexIsRunning: @escaping () -> Bool = SessionRecoveryService.isCodexDesktopRunning
    ) {
        self.fileManager = fileManager
        stateURL = homeDirectory.appendingPathComponent(".codex/.codex-global-state.json")
        self.pendingURL = pendingURL
        self.backupRoot = backupRoot
        self.now = now
        self.codexIsRunning = codexIsRunning
    }

    func registerCleanup(
        projectName: String,
        projectPath: String
    ) throws -> CodexProjectCleanupDisposition {
        try lock.withLock {
            var pending = try loadPending()
            pending.removeAll { $0.projectPath == projectPath }
            pending.append(PendingCodexProjectCleanup(
                projectName: projectName,
                projectPath: projectPath,
                requestedAt: now()
            ))
            try savePending(pending)
            guard !codexIsRunning() else { return .queued }
            let result = try cleanupState(projectName: projectName, projectPath: projectPath)
            pending.removeAll { $0.projectPath == projectPath }
            try savePending(pending)
            return .completed(result)
        }
    }

    func processPendingIfPossible() throws -> [CodexProjectCleanupResult] {
        try lock.withLock {
            guard !codexIsRunning() else { return [] }
            var pending = try loadPending()
            var results: [CodexProjectCleanupResult] = []
            var completedPaths = Set<String>()
            for item in pending {
                results.append(try cleanupState(
                    projectName: item.projectName,
                    projectPath: item.projectPath
                ))
                completedPaths.insert(item.projectPath)
            }
            pending.removeAll { completedPaths.contains($0.projectPath) }
            try savePending(pending)
            return results
        }
    }

    func pendingCount() -> Int {
        lock.withLock { (try? loadPending().count) ?? 0 }
    }

    private func cleanupState(
        projectName: String,
        projectPath: String
    ) throws -> CodexProjectCleanupResult {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return CodexProjectCleanupResult(
                projectPath: projectPath,
                removedProjectCount: 0,
                backupURL: nil
            )
        }
        let originalData = try Data(contentsOf: stateURL)
        let removal = try CodexProjectCatalog.removingLocalProject(
            atPath: projectPath,
            from: originalData
        )
        guard !removal.removedProjectIDs.isEmpty else {
            return CodexProjectCleanupResult(
                projectPath: projectPath,
                removedProjectCount: 0,
                backupURL: nil
            )
        }
        let directory = backupRoot.appendingPathComponent(
            "project-cleanup-\(Self.timestamp(now()))-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let backupURL = directory.appendingPathComponent(".codex-global-state.json")
        try originalData.write(to: backupURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        let attributes = try? fileManager.attributesOfItem(atPath: stateURL.path)
        do {
            try removal.data.write(to: stateURL, options: .atomic)
            if let permissions = attributes?[.posixPermissions] {
                try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: stateURL.path)
            }
            let verification = try CodexProjectCatalog.removingLocalProject(
                atPath: projectPath,
                from: Data(contentsOf: stateURL)
            )
            guard verification.removedProjectIDs.isEmpty else {
                throw CleanupError(message: "写入后仍检测到项目登记")
            }
        } catch {
            try? originalData.write(to: stateURL, options: .atomic)
            throw CleanupError(
                message: "项目登记清理失败，原状态已恢复：\(error.localizedDescription)"
            )
        }
        return CodexProjectCleanupResult(
            projectPath: projectPath,
            removedProjectCount: removal.removedProjectIDs.count,
            backupURL: backupURL
        )
    }

    private func loadPending() throws -> [PendingCodexProjectCleanup] {
        guard fileManager.fileExists(atPath: pendingURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            [PendingCodexProjectCleanup].self,
            from: Data(contentsOf: pendingURL)
        )
    }

    private func savePending(_ pending: [PendingCodexProjectCleanup]) throws {
        try fileManager.createDirectory(
            at: pendingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(pending).write(to: pendingURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingURL.path)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
