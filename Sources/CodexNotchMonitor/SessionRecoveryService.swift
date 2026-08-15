import AppKit
import CryptoKit
import Foundation

struct SessionRecoveryResult: Equatable {
    let requestedCount: Int
    let recoveredCount: Int
    let projectBindingsAdded: Int
    let backupURL: URL
}

final class SessionRecoveryService {
    struct RecoveryError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct BackupFile: Codable {
        let originalPath: String
        let backupName: String
        let size: Int
        let sha256: String
    }

    private struct BackupManifest: Codable {
        let version: Int
        let createdAt: Date
        let selectedThreadIDs: [String]
        let files: [BackupFile]
    }

    private let homeDirectory: URL
    private let backupRoot: URL
    private let threadService: CodexThreadService

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupRoot: URL = AppPaths.continuityBackups,
        threadService: CodexThreadService
    ) {
        self.homeDirectory = homeDirectory
        self.backupRoot = backupRoot
        self.threadService = threadService
    }

    func recover(
        threads: [LocalThreadRecord],
        completion: @escaping (Result<SessionRecoveryResult, Error>) -> Void
    ) {
        guard !threads.isEmpty else {
            completion(.failure(RecoveryError(message: "没有可恢复的会话")))
            return
        }
        guard !Self.isCodexDesktopRunning() else {
            completion(.failure(RecoveryError(
                message: "请先使用 Cmd + Q 完全退出 Codex／ChatGPT Desktop，再执行恢复"
            )))
            return
        }

        let selectedIDs = Set(threads.map(\.id))
        let backupURL: URL
        do {
            backupURL = try createBackup(selectedThreadIDs: selectedIDs)
        } catch {
            completion(.failure(RecoveryError(message: "恢复前备份失败：\(error.localizedDescription)")))
            return
        }

        threadService.rebuildThreadIndex { result in
            switch result {
            case let .failure(error):
                completion(.failure(RecoveryError(
                    message: "已创建备份，但 Codex 线程回填失败：\(error.localizedDescription)"
                )))
            case let .success(visibleIDs):
                do {
                    let bindings = try self.addExactProjectBindings(for: threads)
                    completion(.success(SessionRecoveryResult(
                        requestedCount: selectedIDs.count,
                        recoveredCount: selectedIDs.intersection(visibleIDs).count,
                        projectBindingsAdded: bindings,
                        backupURL: backupURL
                    )))
                } catch {
                    completion(.failure(RecoveryError(
                        message: "线程已回填，但项目绑定更新失败：\(error.localizedDescription)"
                    )))
                }
            }
        }
    }

    func restoreBackup(
        at backupURL: URL,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !Self.isCodexDesktopRunning() else {
            completion(.failure(RecoveryError(
                message: "请先使用 Cmd + Q 完全退出 Codex／ChatGPT Desktop，再回滚"
            )))
            return
        }
        do {
            let manifestURL = backupURL.appendingPathComponent("manifest.json")
            let manifest = try JSONDecoder.backupDecoder.decode(
                BackupManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            guard manifest.version == 1 else {
                throw RecoveryError(message: "不支持的备份格式")
            }
            for file in manifest.files {
                let source = backupURL.appendingPathComponent(file.backupName)
                let data = try Data(contentsOf: source)
                guard data.count == file.size, Self.sha256(data) == file.sha256 else {
                    throw RecoveryError(message: "备份校验失败：\(file.backupName)")
                }
            }

            let preserved = backupURL.appendingPathComponent(
                "pre-rollback-current-\(Self.timestamp())",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: preserved,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
            let currentCandidates = [
                codexHome.appendingPathComponent("state_5.sqlite"),
                codexHome.appendingPathComponent("state_5.sqlite-wal"),
                codexHome.appendingPathComponent("state_5.sqlite-shm"),
                codexHome.appendingPathComponent("session_index.jsonl"),
                codexHome.appendingPathComponent(".codex-global-state.json"),
            ]
            for destination in currentCandidates {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.moveItem(
                        at: destination,
                        to: preserved.appendingPathComponent(destination.lastPathComponent)
                    )
                }
            }
            for file in manifest.files {
                let destination = URL(fileURLWithPath: file.originalPath)
                let data = try Data(contentsOf: backupURL.appendingPathComponent(file.backupName))
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destination, options: .atomic)
            }
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    static func isCodexDesktopRunning() -> Bool {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.contains { app in
            guard app.processIdentifier != ownPID else { return false }
            let name = app.localizedName?.lowercased() ?? ""
            let identifier = app.bundleIdentifier?.lowercased() ?? ""
            if name == "codex" || name == "chatgpt" { return true }
            return identifier == "com.openai.codex" || identifier == "com.openai.chat"
        }
    }

    private func createBackup(selectedThreadIDs: Set<String>) throws -> URL {
        let directory = backupRoot.appendingPathComponent(Self.timestamp(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let codexHome = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let candidates = [
            codexHome.appendingPathComponent("state_5.sqlite"),
            codexHome.appendingPathComponent("state_5.sqlite-wal"),
            codexHome.appendingPathComponent("state_5.sqlite-shm"),
            codexHome.appendingPathComponent("session_index.jsonl"),
            codexHome.appendingPathComponent(".codex-global-state.json"),
        ]
        var files: [BackupFile] = []
        for source in candidates where FileManager.default.fileExists(atPath: source.path) {
            let data = try Data(contentsOf: source)
            let backupName = source.lastPathComponent
            try data.write(to: directory.appendingPathComponent(backupName), options: .atomic)
            files.append(BackupFile(
                originalPath: source.path,
                backupName: backupName,
                size: data.count,
                sha256: Self.sha256(data)
            ))
        }
        guard !files.isEmpty else { throw RecoveryError(message: "未找到 Codex 本地状态文件") }
        let manifest = BackupManifest(
            version: 1,
            createdAt: Date(),
            selectedThreadIDs: selectedThreadIDs.sorted(),
            files: files
        )
        let data = try JSONEncoder.backupEncoder.encode(manifest)
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        return directory
    }

    private func addExactProjectBindings(for threads: [LocalThreadRecord]) throws -> Int {
        let stateURL = homeDirectory.appendingPathComponent(".codex/.codex-global-state.json")
        guard let data = try? Data(contentsOf: stateURL) else { return 0 }
        let result = try Self.addingExactProjectBindings(to: data, threads: threads)
        guard result.added > 0 else { return 0 }
        try result.data.write(to: stateURL, options: .atomic)
        return result.added
    }

    static func addingExactProjectBindings(
        to data: Data,
        threads: [LocalThreadRecord]
    ) throws -> (data: Data, added: Int) {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["local-projects"] as? [String: Any]
        else { return (data, 0) }

        var projectsByPath: [String: [(id: String, path: String)]] = [:]
        for (key, value) in projects {
            guard let project = value as? [String: Any] else { continue }
            let projectID = project["id"] as? String ?? key
            for rawPath in project["rootPaths"] as? [String] ?? [] {
                let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
                projectsByPath[path, default: []].append((projectID, path))
            }
        }

        var assignments = root["thread-project-assignments"] as? [String: Any] ?? [:]
        var added = 0
        for thread in threads where assignments[thread.id] == nil {
            let path = URL(fileURLWithPath: thread.projectPath).standardizedFileURL.path
            guard let matches = projectsByPath[path], matches.count == 1, let match = matches.first else { continue }
            assignments[thread.id] = [
                "projectKind": "local",
                "projectId": match.id,
                "cwd": match.path,
                "pendingCoreUpdate": true,
            ]
            added += 1
        }
        guard added > 0 else { return (data, 0) }
        root["thread-project-assignments"] = assignments
        let updated = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        return (updated, added)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var backupEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var backupDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
