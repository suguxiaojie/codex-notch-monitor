import CryptoKit
import Foundation

enum SessionImportDuplicateStrategy: String, CaseIterable, Equatable {
    case skip
    case duplicate

    var title: String {
        switch self {
        case .skip: return "跳过已存在会话（推荐）"
        case .duplicate: return "生成新 ID 并作为副本导入"
        }
    }
}

struct SessionImportPreview: Equatable {
    let bundleURL: URL
    let manifest: SessionPortableManifest
    let duplicateThreadIDs: Set<String>
    let missingOriginalPath: Bool

    var sessionCount: Int { manifest.sessions.count }
    var activeCount: Int { manifest.sessions.filter { !$0.archived }.count }
    var archivedCount: Int { manifest.sessions.filter(\.archived).count }
    var duplicateCount: Int { duplicateThreadIDs.count }
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

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupRoot: URL = AppPaths.continuityBackups,
        now: @escaping () -> Date = Date.init,
        codexIsRunning: @escaping () -> Bool = SessionRecoveryService.isCodexDesktopRunning
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.backupRoot = backupRoot
        self.now = now
        self.codexIsRunning = codexIsRunning
    }

    func inspect(bundleURL: URL, existingThreadIDs: Set<String>) throws -> SessionImportPreview {
        guard bundleURL.pathExtension.lowercased() == "codexmonitorbundle" else {
            throw ImportError(message: "请选择 .codexmonitorbundle 会话备份")
        }
        let extracted = try extractAndValidateArchive(at: bundleURL)
        defer { try? fileManager.removeItem(at: extracted.root) }
        return SessionImportPreview(
            bundleURL: bundleURL,
            manifest: extracted.manifest,
            duplicateThreadIDs: Set(extracted.manifest.sessions.map(\.threadID)).intersection(existingThreadIDs),
            missingOriginalPath: !isExistingDirectory(extracted.manifest.project.originalPath)
        )
    }

    func importBundle(
        preview: SessionImportPreview,
        mappedProjectURL: URL?,
        duplicateStrategy: SessionImportDuplicateStrategy
    ) throws -> SessionImportResult {
        guard !codexIsRunning() else {
            throw ImportError(message: "请先使用 Cmd + Q 完全退出 Codex／ChatGPT Desktop，再导入会话")
        }

        let existingIDs = try localThreadIDs()
        let currentPreview = try inspect(bundleURL: preview.bundleURL, existingThreadIDs: existingIDs)
        let destinationProjectURL: URL
        if currentPreview.requiresPathMapping {
            guard let mappedProjectURL else {
                throw ImportError(message: "原项目路径不存在，请先选择新的项目目录")
            }
            let values = try mappedProjectURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw ImportError(message: "重新映射的项目路径必须是已存在的文件夹")
            }
            destinationProjectURL = mappedProjectURL.standardizedFileURL
        } else {
            destinationProjectURL = URL(fileURLWithPath: currentPreview.manifest.project.originalPath)
                .standardizedFileURL
        }

        let extracted = try extractAndValidateArchive(at: preview.bundleURL)
        defer { try? fileManager.removeItem(at: extracted.root) }
        let backupURL = try createTransactionBackup(sourceBundle: preview.bundleURL)
        var createdFiles: [URL] = []
        var importedRecords: [LocalThreadRecord] = []
        var skipped = 0

        do {
            for session in extracted.manifest.sessions {
                let isDuplicate = existingIDs.contains(session.threadID)
                if isDuplicate, duplicateStrategy == .skip {
                    skipped += 1
                    continue
                }
                let importedID = isDuplicate ? UUID().uuidString.lowercased() : session.threadID
                let source = extracted.root.appendingPathComponent(session.rolloutPath)
                let destination = destinationURL(
                    for: session,
                    importedID: importedID,
                    projectURL: destinationProjectURL
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
                if needsRewrite {
                    try rewriteJSONL(
                        source: source,
                        destination: destination,
                        originalID: session.threadID,
                        importedID: importedID,
                        originalCwd: session.originalCwd,
                        importedCwd: destinationProjectURL.path
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
                    isArchived: session.archived,
                    updatedAt: Self.parseDate(session.updatedAt) ?? now(),
                    gitBranch: session.gitBranch,
                    readableMessages: [],
                    kind: .userConversation,
                    ownership: .unknown,
                    visibility: .localOnly
                ))
            }

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
    ) throws -> (root: URL, manifest: SessionPortableManifest) {
        let entries = try archiveEntries(at: bundleURL)
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
            return (root, manifest)
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
        projectURL: URL
    ) -> URL {
        let codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let root: URL
        if session.archived {
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
        let projectSlug = SessionExportService.safeFilenameStem(projectURL.lastPathComponent)
        return root.appendingPathComponent("rollout-import-\(projectSlug)-\(importedID).jsonl")
    }

    private func rewriteJSONL(
        source: URL,
        destination: URL,
        originalID: String,
        importedID: String,
        originalCwd: String,
        importedCwd: String
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
                    importedCwd: importedCwd
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
                importedCwd: importedCwd
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
        importedCwd: String
    ) throws {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line)
        else { throw ImportError(message: "会话 JSONL 包含无法解析的记录") }
        let rewritten = Self.rewriteValue(
            object,
            originalID: originalID,
            importedID: importedID,
            originalCwd: originalCwd,
            importedCwd: importedCwd
        )
        var data = try JSONSerialization.data(withJSONObject: rewritten)
        data.append(0x0A)
        try output.write(contentsOf: data)
    }

    private func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func rewriteValue(
        _ value: Any,
        originalID: String,
        importedID: String,
        originalCwd: String,
        importedCwd: String,
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
                    importedCwd: importedCwd
                )
            }
        }
        if let string = value as? String {
            if (key == "id" || key == "session_id"), string == originalID { return importedID }
            if key == "cwd", URL(fileURLWithPath: string).standardizedFileURL.path
                == URL(fileURLWithPath: originalCwd).standardizedFileURL.path { return importedCwd }
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
        let candidates = Self.managedStateFiles(codexHome: codexHome)
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

    private func archiveEntries(at url: URL) throws -> [String] {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", url.path]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ImportError(message: detail.isEmpty ? "无法读取备份包" : detail)
        }
        return (String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .split(whereSeparator: \.isNewline)
            .map(String.init)
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

    private static func managedStateFiles(codexHome: URL) -> [URL] {
        [
            codexHome.appendingPathComponent("state_5.sqlite"),
            codexHome.appendingPathComponent("state_5.sqlite-wal"),
            codexHome.appendingPathComponent("state_5.sqlite-shm"),
            codexHome.appendingPathComponent("session_index.jsonl"),
            codexHome.appendingPathComponent(".codex-global-state.json"),
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
