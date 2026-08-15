import CryptoKit
import Foundation

enum SessionExportFormat: String, CaseIterable {
    case markdown
    case html
    case portableBundle

    var title: String {
        switch self {
        case .markdown: return "可读 Markdown（脱敏）"
        case .html: return "可读 HTML（脱敏）"
        case .portableBundle: return "可恢复备份（原始记录）"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .html: return "html"
        case .portableBundle: return "codexmonitorbundle"
        }
    }
}

struct SessionExportResult: Equatable {
    let outputURL: URL
    let sessionCount: Int
    let format: SessionExportFormat
}

struct SessionPortableManifest: Codable, Equatable {
    static let supportedFormat = "codex-notch-session/v1"

    let format: String
    let createdAt: String
    let source: Source
    let project: Project
    let sessions: [Session]

    struct Source: Codable, Equatable {
        let application: String
        let version: String
        let platform: String
    }

    struct Project: Codable, Equatable {
        let displayName: String
        let originalPath: String
    }

    struct Session: Codable, Equatable {
        let threadID: String
        let title: String
        let archived: Bool
        let updatedAt: String
        let originalCwd: String
        let gitBranch: String?
        let ownershipAlias: String?
        let ownershipConfidence: String
        let rolloutPath: String
        let sha256: String

        enum CodingKeys: String, CodingKey {
            case threadID = "threadId"
            case title
            case archived
            case updatedAt
            case originalCwd
            case gitBranch
            case ownershipAlias
            case ownershipConfidence
            case rolloutPath
            case sha256
        }
    }
}

struct SessionPortableChecksums: Codable, Equatable {
    let algorithm: String
    let files: [String: String]
}

final class SessionExportService {
    struct ExportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct TranscriptEntry {
        let role: Role
        let message: String

        enum Role: String {
            case user = "用户"
            case assistant = "Codex"
        }
    }

    private let fileManager: FileManager
    private let now: () -> Date

    init(fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.now = now
    }

    func export(
        threads: [LocalThreadRecord],
        projectName: String,
        format: SessionExportFormat,
        to outputURL: URL
    ) throws -> SessionExportResult {
        let userThreads = threads.filter { $0.kind == .userConversation }
        guard !userThreads.isEmpty else {
            throw ExportError(message: "没有可导出的用户会话")
        }

        switch format {
        case .markdown:
            try markdown(for: userThreads, projectName: projectName).write(
                to: outputURL,
                atomically: true,
                encoding: .utf8
            )
        case .html:
            try html(for: userThreads, projectName: projectName).write(
                to: outputURL,
                atomically: true,
                encoding: .utf8
            )
        case .portableBundle:
            try writePortableBundle(
                threads: userThreads,
                projectName: projectName,
                to: outputURL
            )
        }

        return SessionExportResult(
            outputURL: outputURL,
            sessionCount: userThreads.count,
            format: format
        )
    }

    static func safeFilenameStem(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let components = value.components(separatedBy: invalid)
        let collapsed = components.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return String((collapsed.isEmpty ? "Codex-会话" : collapsed).prefix(80))
    }

    private func markdown(for threads: [LocalThreadRecord], projectName: String) throws -> String {
        var sections = [
            "# Codex 会话导出",
            "",
            "- 项目：\(projectName)",
            "- 导出时间：\(Self.iso8601(now()))",
            "- 会话数量：\(threads.count)",
            "- 内容范围：用户与 Codex 可读消息（已脱敏）",
            "",
        ]

        for (index, thread) in sorted(threads).enumerated() {
            let entries = try transcriptEntries(at: thread.rolloutURL)
            sections.append(contentsOf: [
                index == 0 ? "## \(thread.title)" : "---\n\n## \(thread.title)",
                "",
                "- 会话 ID：`\(thread.id)`",
                "- 状态：\(thread.isArchived ? "已归档" : "活动")",
                "- 更新时间：\(Self.iso8601(thread.updatedAt))",
                "",
            ])
            for entry in entries {
                sections.append("### \(entry.role.rawValue)")
                sections.append("")
                sections.append(SessionContinuityService.redactSensitiveText(entry.message, limit: nil))
                sections.append("")
            }
        }
        return sections.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func html(for threads: [LocalThreadRecord], projectName: String) throws -> String {
        var conversations = ""
        for thread in sorted(threads) {
            let entries = try transcriptEntries(at: thread.rolloutURL)
            let messages = entries.map { entry in
                let redacted = SessionContinuityService.redactSensitiveText(entry.message, limit: nil)
                return """
                <article class="message \(entry.role == .user ? "user" : "assistant")">
                  <div class="role">\(entry.role.rawValue)</div>
                  <pre>\(Self.escapeHTML(redacted))</pre>
                </article>
                """
            }.joined(separator: "\n")
            conversations += """
            <section class="session">
              <header>
                <h2>\(Self.escapeHTML(thread.title))</h2>
                <div class="meta">\(thread.isArchived ? "已归档" : "活动") · \(Self.iso8601(thread.updatedAt)) · \(Self.escapeHTML(thread.id))</div>
              </header>
              \(messages)
            </section>
            """
        }

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(Self.escapeHTML(projectName)) · Codex 会话导出</title>
          <style>
            :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
            body { margin: 0; background: #080a0c; color: #f5f7fa; }
            main { width: min(900px, calc(100% - 32px)); margin: 36px auto 72px; }
            .summary, .session { border: 1px solid #26313a; border-radius: 18px; background: #11161a; padding: 22px; margin-bottom: 18px; }
            h1, h2 { margin: 0 0 8px; }
            .meta { color: #8d9aa5; font-size: 13px; overflow-wrap: anywhere; }
            .message { margin-top: 16px; border-radius: 14px; padding: 15px; background: #171d22; }
            .message.user { border-left: 3px solid #21c7f3; }
            .message.assistant { border-left: 3px solid #647481; }
            .role { color: #4bd9ff; font-size: 12px; font-weight: 700; margin-bottom: 8px; }
            pre { margin: 0; white-space: pre-wrap; overflow-wrap: anywhere; font: 14px/1.65 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
          </style>
        </head>
        <body>
          <main>
            <section class="summary">
              <h1>Codex 会话导出</h1>
              <div class="meta">项目：\(Self.escapeHTML(projectName)) · \(threads.count) 条会话 · \(Self.iso8601(now())) · 已脱敏</div>
            </section>
            \(conversations)
          </main>
        </body>
        </html>
        """
    }

    private func writePortableBundle(
        threads: [LocalThreadRecord],
        projectName: String,
        to outputURL: URL
    ) throws {
        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("codex-monitor-export-\(UUID().uuidString)", isDirectory: true)
        let archiveTemp = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: stagingRoot)
            try? fileManager.removeItem(at: archiveTemp)
        }

        var manifestSessions: [SessionPortableManifest.Session] = []
        var checksums: [String: String] = [:]
        for thread in sorted(threads) {
            guard fileManager.fileExists(atPath: thread.rolloutURL.path) else {
                throw ExportError(message: "会话原始记录不存在：\(thread.title)")
            }
            let stateFolder = thread.isArchived ? "archived" : "active"
            let relativePath = "sessions/\(stateFolder)/\(thread.rolloutURL.lastPathComponent)"
            let target = stagingRoot.appendingPathComponent(relativePath)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: thread.rolloutURL, to: target)
            let digest = try Self.sha256(of: target)
            checksums[relativePath] = digest
            manifestSessions.append(SessionPortableManifest.Session(
                threadID: thread.id,
                title: thread.title,
                archived: thread.isArchived,
                updatedAt: Self.iso8601(thread.updatedAt),
                originalCwd: thread.projectPath,
                gitBranch: thread.gitBranch,
                ownershipAlias: thread.ownership.confidence == .observed
                    ? thread.ownership.accountAlias
                    : nil,
                ownershipConfidence: thread.ownership.confidence.rawValue,
                rolloutPath: relativePath,
                sha256: digest
            ))
        }

        let projectPath = threads.first?.projectPath ?? ""
        let manifest = SessionPortableManifest(
            format: SessionPortableManifest.supportedFormat,
            createdAt: Self.iso8601(now()),
            source: SessionPortableManifest.Source(
                application: "Codex Notch Monitor",
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                platform: "macOS"
            ),
            project: SessionPortableManifest.Project(displayName: projectName, originalPath: projectPath),
            sessions: manifestSessions
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)
        let manifestURL = stagingRoot.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL, options: .atomic)
        checksums["manifest.json"] = Self.sha256(manifestData)

        let notice = """
        Codex Notch Monitor 可恢复会话备份

        此文件包含原始 Codex 会话 JSONL，可能包含提示词、源码、终端输出、绝对路径、图片以及意外输出的凭据。
        请勿公开上传或发送给不可信的第三方。此备份不包含 auth.json、Cookie、Token 或其他独立账号凭据文件。
        格式：codex-notch-session/v1
        """
        let noticeData = Data(notice.utf8)
        try noticeData.write(
            to: stagingRoot.appendingPathComponent("README.txt"),
            options: .atomic
        )
        checksums["README.txt"] = Self.sha256(noticeData)
        let checksumData = try encoder.encode(SessionPortableChecksums(algorithm: "SHA-256", files: checksums))
        try checksumData.write(
            to: stagingRoot.appendingPathComponent("checksums.json"),
            options: .atomic
        )

        try createZipArchive(from: stagingRoot, to: archiveTemp)
        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: archiveTemp)
        } else {
            try fileManager.moveItem(at: archiveTemp, to: outputURL)
        }
    }

    private func transcriptEntries(at url: URL) throws -> [TranscriptEntry] {
        guard fileManager.fileExists(atPath: url.path) else {
            throw ExportError(message: "找不到会话原始记录：\(url.lastPathComponent)")
        }
        var entries: [TranscriptEntry] = []
        try forEachJSONLine(at: url) { object in
            guard object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String,
                  let message = payload["message"] as? String
            else { return }
            if eventType == "user_message" {
                entries.append(TranscriptEntry(role: .user, message: message))
            } else if eventType == "agent_message" {
                entries.append(TranscriptEntry(role: .assistant, message: message))
            }
        }
        return entries
    }

    private func forEachJSONLine(
        at url: URL,
        handleObject: ([String: Any]) -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var buffer = Data()
        while true {
            let chunk = try handle.read(upToCount: 256 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                if !line.isEmpty,
                   let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                    handleObject(object)
                }
                buffer.removeSubrange(...newline)
            }
        }
        if !buffer.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] {
            handleObject(object)
        }
    }

    private func createZipArchive(from directory: URL, to outputURL: URL) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", directory.path, outputURL.path]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                throw ExportError(message: detail)
            }
            throw ExportError(message: "创建会话备份包失败")
        }
    }

    private func sorted(_ threads: [LocalThreadRecord]) -> [LocalThreadRecord] {
        threads.sorted { $0.updatedAt > $1.updatedAt }
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

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
