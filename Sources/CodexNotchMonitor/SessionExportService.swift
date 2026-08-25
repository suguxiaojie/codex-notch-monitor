import CryptoKit
import Foundation

enum SessionExportFormat: String, CaseIterable {
    case markdown
    case html
    case portableBundle
    case projectBundle

    var title: String {
        switch self {
        case .markdown: return "可读 Markdown（脱敏）"
        case .html: return "可读 HTML（脱敏）"
        case .portableBundle: return "可恢复备份（原始记录）"
        case .projectBundle: return "完整项目迁移包（P1）"
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .html: return "html"
        case .portableBundle: return "codexmonitorbundle"
        case .projectBundle: return "codexprojectbundle"
        }
    }
}

struct SessionExportResult: Equatable {
    let outputURL: URL
    let sessionCount: Int
    let format: SessionExportFormat
}

enum SessionExportStage: String, Equatable {
    case preparing = "准备导出"
    case reading = "读取会话"
    case processing = "清理与脱敏"
    case rendering = "生成文档"
    case writing = "写入文件"
    case compressing = "生成压缩包"
    case completed = "导出完成"
}

struct SessionExportProgress: Equatable {
    let completed: Int
    let total: Int
    let currentItem: String
    let stage: SessionExportStage
    let processedBytes: Int64?
    let totalBytes: Int64?
    let fraction: Double

    init(
        completed: Int,
        total: Int,
        currentItem: String,
        stage: SessionExportStage = .preparing,
        processedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        fraction: Double? = nil
    ) {
        self.completed = completed
        self.total = total
        self.currentItem = currentItem
        self.stage = stage
        self.processedBytes = processedBytes
        self.totalBytes = totalBytes
        self.fraction = min(1, max(
            0,
            fraction ?? (total > 0 ? Double(completed) / Double(total) : 0)
        ))
    }
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

    private struct ReadableTurn {
        let question: String
        var responses: [String]
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
        to outputURL: URL,
        projectTransferOptions: ProjectTransferExportOptions = .defaults,
        progress: ((SessionExportProgress) -> Void)? = nil
    ) throws -> SessionExportResult {
        let userThreads = threads.filter { $0.kind == .userConversation }
        guard !userThreads.isEmpty else {
            throw ExportError(message: "没有可导出的用户会话")
        }
        progress?(SessionExportProgress(
            completed: 0,
            total: userThreads.count,
            currentItem: userThreads.count == 1 ? userThreads[0].title : "准备导出",
            stage: .preparing,
            fraction: 0
        ))

        switch format {
        case .markdown:
            let document = try markdown(
                for: userThreads,
                projectName: projectName,
                progress: progress
            )
            progress?(SessionExportProgress(
                completed: userThreads.count,
                total: userThreads.count,
                currentItem: outputURL.lastPathComponent,
                stage: .writing,
                fraction: 0.96
            ))
            try document.write(
                to: outputURL,
                atomically: true,
                encoding: .utf8
            )
        case .html:
            let document = try html(
                for: userThreads,
                projectName: projectName,
                progress: progress
            )
            progress?(SessionExportProgress(
                completed: userThreads.count,
                total: userThreads.count,
                currentItem: outputURL.lastPathComponent,
                stage: .writing,
                fraction: 0.96
            ))
            try document.write(
                to: outputURL,
                atomically: true,
                encoding: .utf8
            )
        case .portableBundle:
            try writePortableBundle(
                threads: userThreads,
                projectName: projectName,
                to: outputURL,
                progress: progress
            )
        case .projectBundle:
            return try ProjectTransferService(
                fileManager: fileManager,
                now: now,
                sessionExportService: self
            ).export(
                threads: userThreads,
                projectName: projectName,
                to: outputURL,
                options: projectTransferOptions,
                progress: progress
            )
        }
        progress?(SessionExportProgress(
            completed: userThreads.count,
            total: userThreads.count,
            currentItem: outputURL.lastPathComponent,
            stage: .completed,
            fraction: 1
        ))

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

    private func markdown(
        for threads: [LocalThreadRecord],
        projectName: String,
        progress: ((SessionExportProgress) -> Void)?
    ) throws -> String {
        var sections = [
            "# Codex 会话导出",
            "",
            "> 可读脱敏版本。平台注入配置、运行环境、插件清单、附件临时路径和内部引用元数据已隐藏；完整原始记录请使用 `.codexmonitorbundle`。",
            "",
            "| 项目 | 内容 |",
            "|---|---|",
            "| 项目 | \(Self.markdownTableCell(projectName)) |",
            "| 导出时间 | \(Self.iso8601(now())) |",
            "| 会话数量 | \(threads.count) |",
            "| 内容范围 | 用户与 Codex 可读消息（已脱敏） |",
            "",
        ]

        let orderedThreads = sorted(threads)
        for (index, thread) in orderedThreads.enumerated() {
            let entries = try transcriptEntries(
                at: thread.rolloutURL,
                progress: { processed, total in
                    let byteFraction = total > 0 ? Double(processed) / Double(total) : 1
                    let overall = 0.92 * (
                        Double(index) + min(1, max(0, byteFraction)) * 0.76
                    ) / Double(orderedThreads.count)
                    progress?(SessionExportProgress(
                        completed: index,
                        total: orderedThreads.count,
                        currentItem: thread.title,
                        stage: .reading,
                        processedBytes: processed,
                        totalBytes: total,
                        fraction: overall
                    ))
                }
            )
            progress?(SessionExportProgress(
                completed: index,
                total: orderedThreads.count,
                currentItem: thread.title,
                stage: .processing,
                fraction: 0.92 * (Double(index) + 0.82) / Double(orderedThreads.count)
            ))
            let readableEntries = Self.readableTranscriptEntries(entries)
            let turns = Self.conversationTurns(readableEntries)
            progress?(SessionExportProgress(
                completed: index,
                total: orderedThreads.count,
                currentItem: thread.title,
                stage: .rendering,
                fraction: 0.92 * (Double(index) + 0.90) / Double(orderedThreads.count)
            ))
            let sessionAnchor = "session-\(index + 1)"
            let directoryAnchor = "\(sessionAnchor)-question-index"
            sections.append(contentsOf: [
                index == 0 ? "<a id=\"\(sessionAnchor)\"></a>\n\n## \(thread.title)" : "---\n\n<a id=\"\(sessionAnchor)\"></a>\n\n## \(thread.title)",
                "",
                "> 本节为可读脱敏版本。已隐藏平台注入配置、运行环境、插件清单、附件临时路径和内部引用元数据；完整原始记录请使用 `.codexmonitorbundle`。",
                "",
                "| 项目 | 内容 |",
                "|---|---|",
                "| 会话 ID | `\(thread.id)` |",
                "| 状态 | \(thread.isArchived ? "已归档" : "活动") |",
                "| 更新时间 | \(Self.iso8601(thread.updatedAt)) |",
                "| 用户问题 | \(turns.count) |",
                "| 可读消息 | \(readableEntries.count) |",
                "",
                "<a id=\"\(directoryAnchor)\"></a>",
                "",
                "### 用户问题目录",
                "",
            ])
            if turns.isEmpty {
                sections.append("_此会话没有可读的用户问题。_")
                sections.append("")
            } else {
                for (turnIndex, turn) in turns.enumerated() {
                    let title = Self.questionNavigationTitle(
                        turn.question,
                        fallbackIndex: turnIndex + 1
                    ).short
                    sections.append(
                        "\(turnIndex + 1). [\(title)](#\(sessionAnchor)-question-\(turnIndex + 1))"
                    )
                }
                sections.append("")
            }
            for (turnIndex, turn) in turns.enumerated() {
                let questionNumber = turnIndex + 1
                let title = Self.questionNavigationTitle(
                    turn.question,
                    fallbackIndex: questionNumber
                ).short
                sections.append(contentsOf: [
                    "---",
                    "",
                    "<a id=\"\(sessionAnchor)-question-\(questionNumber)\"></a>",
                    "",
                    "### 问题 \(questionNumber)：\(title)",
                    "",
                    "#### 用户",
                    "",
                    turn.question,
                    "",
                ])

                if turn.responses.isEmpty {
                    sections.append("_此问题没有可读的 Codex 回复。_")
                    sections.append("")
                } else if turn.responses.count == 1 {
                    sections.append("#### Codex 回复")
                    sections.append("")
                    sections.append(turn.responses[0])
                    sections.append("")
                } else {
                    for (responseIndex, response) in turn.responses.enumerated() {
                        let isLast = responseIndex == turn.responses.count - 1
                        sections.append(
                            isLast
                                ? "#### Codex 最终回复"
                                : "#### Codex 过程更新 \(responseIndex + 1)"
                        )
                        sections.append("")
                        sections.append(response)
                        sections.append("")
                    }
                }
                sections.append("[返回问题目录](#\(directoryAnchor))")
                sections.append("")
            }
            progress?(SessionExportProgress(
                completed: index + 1,
                total: orderedThreads.count,
                currentItem: thread.title,
                stage: .rendering,
                fraction: 0.92 * Double(index + 1) / Double(orderedThreads.count)
            ))
        }
        return sections.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func html(
        for threads: [LocalThreadRecord],
        projectName: String,
        progress: ((SessionExportProgress) -> Void)?
    ) throws -> String {
        let orderedThreads = sorted(threads)
        var conversations = ""
        var tocItems = ""
        for (sessionIndex, thread) in orderedThreads.enumerated() {
            let entries = try transcriptEntries(
                at: thread.rolloutURL,
                progress: { processed, total in
                    let byteFraction = total > 0 ? Double(processed) / Double(total) : 1
                    let overall = 0.92 * (
                        Double(sessionIndex) + min(1, max(0, byteFraction)) * 0.76
                    ) / Double(orderedThreads.count)
                    progress?(SessionExportProgress(
                        completed: sessionIndex,
                        total: orderedThreads.count,
                        currentItem: thread.title,
                        stage: .reading,
                        processedBytes: processed,
                        totalBytes: total,
                        fraction: overall
                    ))
                }
            )
            progress?(SessionExportProgress(
                completed: sessionIndex,
                total: orderedThreads.count,
                currentItem: thread.title,
                stage: .processing,
                fraction: 0.92 * (Double(sessionIndex) + 0.82) / Double(orderedThreads.count)
            ))
            let readableEntries = Self.readableTranscriptEntries(entries)
            progress?(SessionExportProgress(
                completed: sessionIndex,
                total: orderedThreads.count,
                currentItem: thread.title,
                stage: .rendering,
                fraction: 0.92 * (Double(sessionIndex) + 0.90) / Double(orderedThreads.count)
            ))
            let sessionID = "session-\(sessionIndex + 1)"
            let turns = Self.conversationTurns(readableEntries)
            var questionSections = ""
            var navigationGroups = ""
            for groupStart in stride(from: 0, to: turns.count, by: 20) {
                let groupEnd = min(groupStart + 20, turns.count)
                let links = (groupStart..<groupEnd).map { turnIndex in
                    let questionNumber = turnIndex + 1
                    let questionID = "\(sessionID)-question-\(questionNumber)"
                    let title = Self.questionNavigationTitle(
                        turns[turnIndex].question,
                        fallbackIndex: questionNumber
                    )
                    return """
                    <a class="question-link" href="#\(questionID)" data-target="\(questionID)" title="\(Self.escapeHTML(title.full))"><b>\(questionNumber)</b><span>\(Self.escapeHTML(title.short))</span></a>
                    """
                }.joined(separator: "\n")
                navigationGroups += """
                <details class="question-group" \(groupStart == 0 ? "open" : "")>
                  <summary>问题 \(groupStart + 1)–\(groupEnd)</summary>
                  <div class="question-list">\(links)</div>
                </details>
                """
            }

            for (turnIndex, turn) in turns.enumerated() {
                let questionNumber = turnIndex + 1
                let questionID = "\(sessionID)-question-\(questionNumber)"
                let title = Self.questionNavigationTitle(
                    turn.question,
                    fallbackIndex: questionNumber
                )
                let processUpdates = Array(turn.responses.dropLast())
                let finalResponse = turn.responses.last
                let processHTML: String
                if processUpdates.isEmpty {
                    processHTML = ""
                } else {
                    let updates = processUpdates.enumerated().map { updateIndex, response in
                        """
                        <section class="process-update">
                          <h4>过程更新 \(updateIndex + 1)</h4>
                          <div class="message-body">\(Self.markdownHTML(response))</div>
                        </section>
                        """
                    }.joined(separator: "\n")
                    processHTML = """
                    <details class="process-group">
                      <summary><span>Codex 过程更新</span><small>\(processUpdates.count) 条</small></summary>
                      <div class="process-list">\(updates)</div>
                    </details>
                    """
                }
                let finalHTML = finalResponse.map {
                    """
                    <section class="final-response">
                      <h4>Codex 最终回复</h4>
                      <div class="message-body">\(Self.markdownHTML($0))</div>
                    </section>
                    """
                } ?? "<div class=\"empty\">此问题没有可读的 Codex 回复。</div>"
                questionSections += """
                <article class="question-section" id="\(questionID)" data-question-number="\(questionNumber)" data-question-total="\(turns.count)">
                  <header class="question-header"><span>问题 \(questionNumber)</span><h3>\(Self.escapeHTML(title.short))</h3></header>
                  <section class="user-prompt">
                    <h4>用户问题</h4>
                    <div class="message-body">\(Self.markdownHTML(turn.question))</div>
                  </section>
                  \(processHTML)
                  \(finalHTML)
                </article>
                """
            }
            tocItems += """
            <section class="toc-session" data-session="\(sessionID)">
              <a class="session-link" href="#\(sessionID)"><span>\(Self.escapeHTML(thread.title))</span><small>\(thread.isArchived ? "已归档" : "活动")</small></a>
              <div class="question-groups">\(navigationGroups)</div>
            </section>
            """
            conversations += """
            <section class="session" id="\(sessionID)">
              <header class="session-header">
                <div>
                  <h2>\(Self.escapeHTML(thread.title))</h2>
                  <div class="meta">\(Self.iso8601(thread.updatedAt)) · \(Self.escapeHTML(thread.id))</div>
                </div>
                <span class="status \(thread.isArchived ? "archived" : "active")">\(thread.isArchived ? "已归档" : "活动")</span>
              </header>
              \(questionSections.isEmpty ? "<div class=\"empty\">此会话没有可读的用户问题。</div>" : questionSections)
            </section>
            """
            progress?(SessionExportProgress(
                completed: sessionIndex + 1,
                total: orderedThreads.count,
                currentItem: thread.title,
                stage: .rendering,
                fraction: 0.92 * Double(sessionIndex + 1) / Double(orderedThreads.count)
            ))
        }

        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(Self.escapeHTML(projectName)) · Codex 会话导出</title>
          <style>
            :root { color-scheme: dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif; }
            * { box-sizing: border-box; }
            html { scroll-behavior: smooth; }
            body { margin: 0; background: #090c0f; color: #eef3f6; font-size: 15px; line-height: 1.75; }
            .layout { width: min(1160px, calc(100% - 40px)); margin: 28px auto 80px; display: grid; grid-template-columns: 260px minmax(0, 780px); gap: 24px; justify-content: center; }
            .toc { position: sticky; top: 24px; align-self: start; max-height: calc(100vh - 48px); display: flex; flex-direction: column; overflow: hidden; border: 1px solid #25313a; border-radius: 16px; background: #10151a; }
            .toc-tools { flex: none; padding: 14px; border-bottom: 1px solid #202a31; background: #10151a; }
            .toc-title { color: #dce5ea; font-size: 13px; font-weight: 750; margin-bottom: 10px; }
            .search-label { display: block; color: #95a3ac; font-size: 11px; font-weight: 650; margin-bottom: 5px; }
            .search { width: 100%; padding: 9px 10px; border: 1px solid #2a3943; border-radius: 9px; background: #0a0f13; color: #eef3f6; font: inherit; font-size: 12px; line-height: 1.4; outline: none; }
            .search:focus { border-color: #24bfe9; box-shadow: 0 0 0 3px rgba(36,191,233,.12); }
            .search-status { min-height: 18px; margin-top: 7px; color: #7f8d96; font-size: 10px; }
            .search-actions { display: grid; grid-template-columns: 1fr 1fr auto; gap: 5px; margin-top: 7px; }
            .search-actions button { min-height: 30px; border: 1px solid #293740; border-radius: 7px; background: #151d22; color: #aebac1; font: inherit; font-size: 11px; cursor: pointer; }
            .search-actions button:hover:not(:disabled) { border-color: #3cbfe3; color: #67ddff; }
            .search-actions button:disabled { opacity: .38; cursor: default; }
            .current-position { margin-top: 8px; color: #56d5f8; font-size: 11px; font-weight: 700; }
            .toc-scroll { min-height: 0; overflow: auto; padding: 10px 12px 13px; }
            .toc-session + .toc-session { margin-top: 8px; padding-top: 8px; border-top: 1px solid #202a31; }
            .session-link { display: flex; gap: 8px; align-items: center; justify-content: space-between; color: #dbe4e9; text-decoration: none; padding: 9px 10px; border-radius: 10px; font-size: 13px; font-weight: 700; line-height: 1.35; }
            .session-link:hover { background: #182129; color: #55d9ff; }
            .session-link span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
            .session-link small { color: #76858f; flex: none; font-size: 10px; font-weight: 500; }
            .question-groups { margin: 3px 0 5px 7px; padding-left: 8px; border-left: 1px solid #26343d; }
            .question-group { margin: 3px 0; }
            .question-group > summary { list-style: none; cursor: pointer; padding: 6px 8px; border-radius: 7px; color: #87959e; font-size: 11px; font-weight: 700; }
            .question-group > summary::-webkit-details-marker { display: none; }
            .question-group > summary::before { content: "›"; display: inline-block; margin-right: 6px; color: #52626c; transform: rotate(0); transition: transform .15s ease; }
            .question-group[open] > summary::before { transform: rotate(90deg); }
            .question-group > summary:hover { color: #c8d5dc; background: rgba(255,255,255,.035); }
            .question-list { margin: 2px 0 5px; }
            .question-link { position: relative; display: grid; grid-template-columns: 23px minmax(0, 1fr); gap: 6px; align-items: center; min-height: 32px; color: #98a6ae; text-decoration: none; padding: 6px 8px; border-radius: 8px; font-size: 12px; line-height: 1.35; transition: color .15s ease, background .15s ease; }
            .question-link b { color: #53636d; font-size: 10px; font-weight: 700; text-align: right; padding-top: 1px; }
            .question-link span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
            .question-link:hover { color: #cfeef7; background: rgba(52,193,231,.08); }
            .question-link.active { color: #61ddff; background: rgba(52,193,231,.12); }
            .question-link.active::before { content: ""; position: absolute; left: -10px; top: 7px; bottom: 7px; width: 2px; border-radius: 2px; background: #39cbed; }
            .question-link.active b { color: #42c9ee; }
            .reader { min-width: 0; }
            .summary, .session { border: 1px solid #25313a; border-radius: 18px; background: #10151a; padding: 22px; margin-bottom: 18px; box-shadow: 0 16px 50px rgba(0,0,0,.18); }
            .summary h1, .session h2 { margin: 0; letter-spacing: -.02em; }
            .summary h1 { font-size: 26px; }
            .session h2 { font-size: 20px; overflow-wrap: anywhere; }
            .summary .meta { margin-top: 6px; }
            .session { scroll-margin-top: 24px; }
            .session-header { display: flex; align-items: flex-start; justify-content: space-between; gap: 16px; margin-bottom: 14px; }
            .meta { color: #8d9ba4; font-size: 12px; overflow-wrap: anywhere; }
            .status { flex: none; border-radius: 999px; padding: 3px 9px; font-size: 11px; font-weight: 700; }
            .status.active { color: #7ce8a1; background: rgba(43,206,103,.12); }
            .status.archived { color: #a9b4bb; background: rgba(255,255,255,.07); }
            .question-section { scroll-margin-top: 24px; margin-top: 16px; border: 1px solid #293740; border-radius: 15px; background: #141a20; overflow: clip; }
            .question-section.flash { animation: message-flash 1.1s ease-out; }
            @keyframes message-flash { 0% { box-shadow: 0 0 0 3px rgba(47,207,245,.48); } 100% { box-shadow: 0 0 0 0 rgba(47,207,245,0); } }
            .question-header { display: flex; align-items: baseline; gap: 10px; padding: 13px 15px; border-bottom: 1px solid #26323a; background: #11171c; }
            .question-header > span { flex: none; color: #45d2f7; font-size: 11px; font-weight: 800; }
            .question-header h3 { min-width: 0; margin: 0; color: #f0f5f7; font-size: 15px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
            .user-prompt, .final-response { padding: 15px 16px; }
            .user-prompt { background: rgba(18,61,75,.26); border-bottom: 1px solid rgba(42,176,211,.15); }
            .final-response { background: #151b21; }
            .user-prompt h4, .final-response h4, .process-update h4 { margin: 0 0 9px; font-size: 12px; }
            .user-prompt h4 { color: #54d9fb; }
            .final-response h4 { color: #d9e3e8; }
            .process-group { border-bottom: 1px solid #26323a; background: #11171c; }
            .process-group > summary { display: flex; align-items: center; justify-content: space-between; list-style: none; cursor: pointer; padding: 10px 16px; color: #8f9da6; font-size: 11px; font-weight: 700; }
            .process-group > summary::-webkit-details-marker { display: none; }
            .process-group > summary::after { content: "展开"; margin-left: auto; color: #64737c; font-size: 10px; }
            .process-group[open] > summary::after { content: "收起"; }
            .process-group > summary small { margin-left: 8px; color: #64737c; font-weight: 500; }
            .process-list { padding: 0 16px 13px; }
            .process-update { padding: 12px 0; border-top: 1px solid rgba(255,255,255,.05); }
            .process-update h4 { color: #77868f; }
            .message-body { border-top: 1px solid rgba(255,255,255,.055); padding: 14px 16px 16px; overflow-wrap: anywhere; }
            .user-prompt .message-body, .final-response .message-body, .process-update .message-body { border-top: 0; padding: 0; }
            .message-body > :first-child { margin-top: 0; }
            .message-body > :last-child { margin-bottom: 0; }
            .message-body p { margin: 0 0 12px; }
            .message-body h1, .message-body h2, .message-body h3, .message-body h4, .message-body h5, .message-body h6 { margin: 20px 0 9px; line-height: 1.35; color: #f6fafc; }
            .message-body h1 { font-size: 21px; } .message-body h2 { font-size: 19px; } .message-body h3 { font-size: 17px; } .message-body h4, .message-body h5, .message-body h6 { font-size: 15px; }
            .message-body ul, .message-body ol { margin: 8px 0 14px; padding-left: 24px; }
            .message-body li { margin: 4px 0; }
            .message-body blockquote { margin: 12px 0; padding: 7px 13px; border-left: 3px solid #28c5ed; color: #b4c0c7; background: rgba(40,197,237,.055); border-radius: 0 8px 8px 0; }
            .message-body hr { border: 0; border-top: 1px solid #2a363f; margin: 20px 0; }
            code { padding: 2px 5px; border-radius: 5px; background: #0b1115; color: #d8eef7; font: .88em/1.5 ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
            .code-block { margin: 12px 0; border: 1px solid #27343d; border-radius: 11px; background: #090e12; overflow: hidden; }
            .code-label { padding: 6px 11px; border-bottom: 1px solid #202b32; color: #71818b; font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; }
            .code-block pre { margin: 0; padding: 13px; overflow-x: auto; white-space: pre; color: #dce6eb; font: 13px/1.65 ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace; }
            .code-block pre code { padding: 0; background: transparent; color: inherit; font: inherit; }
            a { color: #45cef3; text-decoration-thickness: 1px; text-underline-offset: 3px; }
            mark.search-hit { border-radius: 3px; background: #f0c94a; color: #17120a; padding: 0 1px; }
            .empty { padding: 22px 0 6px; color: #74838c; text-align: center; }
            .question-section[hidden], .session[hidden], .toc-session[hidden], .question-group[hidden] { display: none; }
            .sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; border: 0; }
            @media (max-width: 940px) { .layout { width: min(780px, calc(100% - 28px)); grid-template-columns: 1fr; } .toc { position: static; max-height: 72vh; } }
          </style>
        </head>
        <body>
          <main class="layout">
            <nav class="toc" aria-label="会话与问题目录">
              <div class="toc-tools">
                <div class="toc-title">会话目录</div>
                <label class="search-label" for="search">搜索导出内容</label>
                <input class="search" id="search" type="search" placeholder="输入关键词…" autocomplete="off" aria-describedby="search-status">
                <div class="search-status" id="search-status" role="status" aria-live="polite">输入关键词搜索问题和回复</div>
                <div class="search-actions">
                  <button id="search-prev" type="button" aria-label="上一个搜索结果" disabled>上一条</button>
                  <button id="search-next" type="button" aria-label="下一个搜索结果" disabled>下一条</button>
                  <button id="search-clear" type="button" aria-label="清除搜索" disabled>清除</button>
                </div>
                <div class="current-position" id="current-position" aria-live="polite">尚未进入问题</div>
              </div>
              <div class="toc-scroll">\(tocItems)</div>
            </nav>
            <div class="reader">
              <section class="summary">
                <h1>Codex 会话导出</h1>
                <div class="meta">项目：\(Self.escapeHTML(projectName)) · \(threads.count) 条会话 · \(Self.iso8601(now())) · 已脱敏</div>
                <div class="meta">已隐藏平台注入配置、运行环境、插件清单、附件临时路径和内部引用元数据；完整原始记录请使用 .codexmonitorbundle。</div>
              </section>
              \(conversations)
            </div>
          </main>
          <script>
            const search = document.getElementById('search');
            const searchStatus = document.getElementById('search-status');
            const searchPrevious = document.getElementById('search-prev');
            const searchNext = document.getElementById('search-next');
            const searchClear = document.getElementById('search-clear');
            const currentPosition = document.getElementById('current-position');
            const questionLinks = [...document.querySelectorAll('.question-link')];
            const questionSections = [...document.querySelectorAll('.question-section')];
            let searchMatches = [];
            let searchMatchIndex = -1;
            let searchTimer;

            function activateQuestion(target, options = {}) {
              if (!target) return;
              const link = questionLinks.find(candidate => candidate.dataset.target === target.id);
              questionLinks.forEach(candidate => {
                const active = candidate === link;
                candidate.classList.toggle('active', active);
                if (active) candidate.setAttribute('aria-current', 'location');
                else candidate.removeAttribute('aria-current');
              });
              if (link) {
                const group = link.closest('.question-group');
                if (group) group.open = true;
                link.scrollIntoView({ block: 'nearest' });
              }
              const number = target.dataset.questionNumber;
              const total = target.dataset.questionTotal;
              currentPosition.textContent = `问题 ${number} / ${total}`;
              if (options.scroll) target.scrollIntoView({ behavior: 'smooth', block: 'start' });
              if (options.flash) {
                target.classList.remove('flash');
                requestAnimationFrame(() => target.classList.add('flash'));
                setTimeout(() => target.classList.remove('flash'), 1200);
              }
            }

            questionLinks.forEach(link => link.addEventListener('click', event => {
              event.preventDefault();
              const target = document.getElementById(link.dataset.target);
              if (!target) return;
              history.replaceState(null, '', `#${target.id}`);
              activateQuestion(target, { scroll: true, flash: true });
            }));

            const observer = new IntersectionObserver(entries => {
              const visible = entries.filter(entry => entry.isIntersecting)
                .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
              if (!visible) return;
              activateQuestion(visible.target);
            }, { rootMargin: '-18% 0px -68% 0px', threshold: [0, .25, .6] });
            questionSections.forEach(section => observer.observe(section));

            function clearSearchMarks() {
              document.querySelectorAll('mark.search-hit').forEach(mark => {
                mark.replaceWith(document.createTextNode(mark.textContent || ''));
              });
              questionSections.forEach(section => section.normalize());
            }

            function highlightMatches(root, term) {
              const nodes = [];
              const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
                acceptNode(node) {
                  const parent = node.parentElement;
                  if (!parent || parent.closest('script, style, summary, mark')) return NodeFilter.FILTER_REJECT;
                  return node.nodeValue.toLocaleLowerCase().includes(term)
                    ? NodeFilter.FILTER_ACCEPT
                    : NodeFilter.FILTER_REJECT;
                }
              });
              while (walker.nextNode()) nodes.push(walker.currentNode);
              let count = 0;
              nodes.forEach(node => {
                const text = node.nodeValue;
                const lower = text.toLocaleLowerCase();
                const fragment = document.createDocumentFragment();
                let cursor = 0;
                let match;
                while ((match = lower.indexOf(term, cursor)) !== -1) {
                  fragment.append(document.createTextNode(text.slice(cursor, match)));
                  const mark = document.createElement('mark');
                  mark.className = 'search-hit';
                  mark.textContent = text.slice(match, match + term.length);
                  fragment.append(mark);
                  cursor = match + term.length;
                  count += 1;
                }
                fragment.append(document.createTextNode(text.slice(cursor)));
                node.replaceWith(fragment);
              });
              return count;
            }

            function syncNavigationVisibility(term) {
              questionLinks.forEach(link => {
                const target = document.getElementById(link.dataset.target);
                link.hidden = !!term && (!target || target.hidden);
              });
              document.querySelectorAll('.question-group').forEach(group => {
                const visibleLinks = [...group.querySelectorAll('.question-link')].filter(link => !link.hidden);
                group.hidden = !!term && visibleLinks.length === 0;
                if (term && visibleLinks.length > 0) group.open = true;
              });
              document.querySelectorAll('.toc-session').forEach(group => {
                const session = document.getElementById(group.dataset.session);
                group.hidden = !!term && (!session || session.hidden);
              });
            }

            function showSearchMatch(index) {
              if (searchMatches.length === 0) return;
              searchMatchIndex = (index + searchMatches.length) % searchMatches.length;
              const target = searchMatches[searchMatchIndex];
              const term = search.value.trim().toLocaleLowerCase();
              const process = target.querySelector('.process-group');
              if (process && process.textContent.toLocaleLowerCase().includes(term)) process.open = true;
              activateQuestion(target, { scroll: true, flash: true });
              const base = searchStatus.dataset.summary || '';
              searchStatus.textContent = `${base} · 当前 ${searchMatchIndex + 1} / ${searchMatches.length}`;
            }

            function runSearch() {
              clearSearchMarks();
              const term = search.value.trim().toLocaleLowerCase();
              searchClear.disabled = !term;
              if (!term) {
                questionSections.forEach(section => { section.hidden = false; });
                document.querySelectorAll('.session, .toc-session, .question-group, .question-link').forEach(element => { element.hidden = false; });
                searchMatches = [];
                searchMatchIndex = -1;
                searchPrevious.disabled = true;
                searchNext.disabled = true;
                searchStatus.textContent = '输入关键词搜索问题和回复';
                searchStatus.dataset.summary = '';
                return;
              }

              searchMatches = questionSections.filter(section =>
                section.textContent.toLocaleLowerCase().includes(term)
              );
              questionSections.forEach(section => {
                section.hidden = !searchMatches.includes(section);
              });
              document.querySelectorAll('.session').forEach(session => {
                session.hidden = ![...session.querySelectorAll('.question-section')].some(section => !section.hidden);
              });
              syncNavigationVisibility(term);
              const occurrences = searchMatches.reduce(
                (sum, section) => sum + highlightMatches(section, term),
                0
              );
              const summary = `${searchMatches.length} 个问题 · ${occurrences} 处匹配`;
              searchStatus.dataset.summary = summary;
              searchStatus.textContent = summary;
              searchPrevious.disabled = searchMatches.length === 0;
              searchNext.disabled = searchMatches.length === 0;
              if (searchMatches.length > 0) showSearchMatch(0);
            }

            search.addEventListener('input', () => {
              clearTimeout(searchTimer);
              searchTimer = setTimeout(runSearch, 140);
            });
            searchPrevious.addEventListener('click', () => showSearchMatch(searchMatchIndex - 1));
            searchNext.addEventListener('click', () => showSearchMatch(searchMatchIndex + 1));
            searchClear.addEventListener('click', () => {
              search.value = '';
              runSearch();
              search.focus();
            });

            const initialTarget = document.querySelector(location.hash || '.question-section')
              || questionSections[0];
            if (initialTarget?.classList.contains('question-section')) activateQuestion(initialTarget);
          </script>
        </body>
        </html>
        """
    }

    private static func markdownHTML(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [String] = []
        var paragraph: [String] = []
        var listTag: String?
        var listItems: [String] = []
        var quoteLines: [String] = []
        var inCodeBlock = false
        var codeLanguage = ""
        var codeLines: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append("<p>" + paragraph.map(Self.inlineMarkdownHTML).joined(separator: "<br>") + "</p>")
            paragraph.removeAll(keepingCapacity: true)
        }

        func flushList() {
            guard let tag = listTag, !listItems.isEmpty else { return }
            blocks.append("<\(tag)>" + listItems.map { "<li>\($0)</li>" }.joined() + "</\(tag)>")
            listItems.removeAll(keepingCapacity: true)
            listTag = nil
        }

        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            blocks.append("<blockquote><p>" + quoteLines.map(Self.inlineMarkdownHTML).joined(separator: "<br>") + "</p></blockquote>")
            quoteLines.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            let label = codeLanguage.isEmpty ? "代码" : codeLanguage
            blocks.append(
                "<div class=\"code-block\"><div class=\"code-label\">\(Self.escapeHTML(label))</div>"
                    + "<pre><code>\(Self.escapeHTML(codeLines.joined(separator: "\n")))</code></pre></div>"
            )
            codeLines.removeAll(keepingCapacity: true)
            codeLanguage = ""
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inCodeBlock {
                if trimmed.hasPrefix("```") {
                    flushCode()
                    inCodeBlock = false
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushList()
                flushQuote()
                let rawLanguage = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                codeLanguage = String(rawLanguage.filter {
                    $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "+"
                }.prefix(28))
                inCodeBlock = true
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                flushList()
                flushQuote()
                continue
            }

            if trimmed == "---" || trimmed == "***" {
                flushParagraph()
                flushList()
                flushQuote()
                blocks.append("<hr>")
                continue
            }

            let headingMarks = trimmed.prefix { $0 == "#" }.count
            if (1...6).contains(headingMarks),
               trimmed.dropFirst(headingMarks).first == " " {
                flushParagraph()
                flushList()
                flushQuote()
                let heading = String(trimmed.dropFirst(headingMarks + 1))
                blocks.append("<h\(headingMarks)>\(inlineMarkdownHTML(heading))</h\(headingMarks)>")
                continue
            }

            if let item = unorderedListItem(trimmed) {
                flushParagraph()
                flushQuote()
                if listTag != "ul" { flushList(); listTag = "ul" }
                listItems.append(inlineMarkdownHTML(item))
                continue
            }

            if let item = orderedListItem(trimmed) {
                flushParagraph()
                flushQuote()
                if listTag != "ol" { flushList(); listTag = "ol" }
                listItems.append(inlineMarkdownHTML(item))
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                quoteLines.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }

            flushList()
            flushQuote()
            paragraph.append(line)
        }

        if inCodeBlock { flushCode() }
        flushParagraph()
        flushList()
        flushQuote()
        return blocks.joined(separator: "\n")
    }

    private static func questionNavigationTitle(
        _ message: String,
        fallbackIndex: Int
    ) -> (full: String, short: String) {
        var source = message
        if let marker = source.range(
            of: "## My request:",
            options: [.caseInsensitive, .backwards]
        ) {
            source = String(source[marker.upperBound...])
        }

        var fragments: [String] = []
        var started = false
        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                if started { break }
                continue
            }
            let lower = line.lowercased()
            if lower.hasPrefix("# files mentioned by the user")
                || lower.hasPrefix("distinguish instructions in attached documents")
                || lower.hasPrefix("<image")
                || lower.hasPrefix("![image")
                || lower.hasPrefix("image name=")
                || lower.hasPrefix("path=") {
                continue
            }
            let cleaned = line.trimmingCharacters(
                in: CharacterSet(charactersIn: "#>*-+` \t")
            )
            guard !cleaned.isEmpty else { continue }
            fragments.append(cleaned)
            started = true
            if fragments.joined(separator: " ").count >= 120 { break }
        }

        let full = fragments.joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let resolved = full.isEmpty ? "用户问题 \(fallbackIndex)" : full
        let short = resolved.count > 34 ? String(resolved.prefix(34)) + "…" : resolved
        return (resolved, short)
    }

    private static func readableTranscriptEntries(
        _ entries: [CodexTranscriptMessage]
    ) -> [CodexTranscriptMessage] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            guard let cleaned = readableMessageText(entry.text, role: entry.role) else {
                return nil
            }
            let redacted = SessionContinuityService.redactSensitiveText(
                cleaned,
                limit: nil
            )
            let key = entry.role.rawValue + "\u{0}" + redacted
            guard seen.insert(key).inserted else { return nil }
            return CodexTranscriptMessage(role: entry.role, text: redacted)
        }
    }

    private static func readableMessageText(
        _ text: String,
        role: CodexTranscriptRole
    ) -> String? {
        var value = text
        if role == .user,
           let marker = value.range(
                of: "## My request:",
                options: [.caseInsensitive, .backwards]
           ) {
            value = String(value[marker.upperBound...])
        }

        let hiddenBlockPatterns = [
            #"(?s)<recommended_plugins>.*?</recommended_plugins>"#,
            #"(?s)# AGENTS\.md instructions.*?</INSTRUCTIONS>"#,
            #"(?s)<INSTRUCTIONS>.*?</INSTRUCTIONS>"#,
            #"(?s)<environment_context>.*?</environment_context>"#,
            #"(?s)<app-context>.*?</app-context>"#,
            #"(?s)<skills_instructions>.*?</skills_instructions>"#,
            #"(?s)<permissions instructions>.*?</permissions instructions>"#,
            #"(?s)<apps_instructions>.*?</apps_instructions>"#,
            #"(?s)<plugins_instructions>.*?</plugins_instructions>"#,
            #"(?s)<collaboration_mode>.*?</collaboration_mode>"#,
            #"(?s)<oai-mem-citation>.*?</oai-mem-citation>"#,
            #"(?s)<image_resize_notice>.*?</image_resize_notice>"#,
        ]
        for pattern in hiddenBlockPatterns {
            value = value.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }

        let filteredLines = value.components(separatedBy: .newlines).filter { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            return !lower.hasPrefix("# files mentioned by the user")
                && !lower.hasPrefix("distinguish instructions in attached documents")
                && !lower.hasPrefix("<image name=")
                && !lower.hasPrefix("<image ")
                && !lower.hasPrefix("## codex-clipboard-")
                && !lower.hasPrefix("## my request:")
        }
        value = filteredLines.joined(separator: "\n")
        value = value.replacingOccurrences(
            of: #"\n[ \t]*\n(?:[ \t]*\n)+"#,
            with: "\n\n",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func conversationTurns(
        _ entries: [CodexTranscriptMessage]
    ) -> [ReadableTurn] {
        var turns: [ReadableTurn] = []
        var current: ReadableTurn?
        for entry in entries {
            if entry.role == .user {
                if let current { turns.append(current) }
                current = ReadableTurn(question: entry.text, responses: [])
            } else if current != nil {
                current?.responses.append(entry.text)
            }
        }
        if let current { turns.append(current) }
        return turns
    }

    private static func markdownTableCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func unorderedListItem(_ value: String) -> String? {
        for marker in ["- ", "* ", "+ "] where value.hasPrefix(marker) {
            return String(value.dropFirst(marker.count))
        }
        return nil
    }

    private static func orderedListItem(_ value: String) -> String? {
        guard let dot = value.firstIndex(of: "."),
              value.index(after: dot) < value.endIndex,
              value[value.index(after: dot)] == " ",
              !value[..<dot].isEmpty,
              value[..<dot].allSatisfy({ $0.isNumber })
        else { return nil }
        return String(value[value.index(dot, offsetBy: 2)...])
    }

    private static func inlineMarkdownHTML(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let suffix = text[index...]

            if suffix.hasPrefix("**"),
               let close = text.range(
                    of: "**",
                    range: text.index(index, offsetBy: 2)..<text.endIndex
               ) {
                let content = String(text[text.index(index, offsetBy: 2)..<close.lowerBound])
                result += "<strong>\(escapeHTML(content))</strong>"
                index = close.upperBound
                continue
            }

            if text[index] == "`" {
                let contentStart = text.index(after: index)
                if let close = text[contentStart...].firstIndex(of: "`") {
                    result += "<code>\(escapeHTML(String(text[contentStart..<close])))</code>"
                    index = text.index(after: close)
                    continue
                }
            }

            if text[index] == "[",
               let labelEnd = text[index...].firstIndex(of: "]") {
                let openParen = text.index(after: labelEnd)
                if openParen < text.endIndex,
                   text[openParen] == "(",
                   let targetEnd = text[text.index(after: openParen)...].firstIndex(of: ")") {
                    let label = String(text[text.index(after: index)..<labelEnd])
                    let target = String(text[text.index(after: openParen)..<targetEnd])
                    if let href = safeLinkHref(target) {
                        result += "<a href=\"\(escapeHTML(href))\">\(escapeHTML(label))</a>"
                    } else {
                        result += escapeHTML(label) + " <code>" + escapeHTML(target) + "</code>"
                    }
                    index = text.index(after: targetEnd)
                    continue
                }
            }

            if text[index] == "*" || text[index] == "_" {
                let marker = text[index]
                let contentStart = text.index(after: index)
                if let close = text[contentStart...].firstIndex(of: marker), close > contentStart {
                    result += "<em>\(escapeHTML(String(text[contentStart..<close])))</em>"
                    index = text.index(after: close)
                    continue
                }
            }

            result += escapeHTML(String(text[index]))
            index = text.index(after: index)
        }
        return result
    }

    private static func safeLinkHref(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value).absoluteString
        }
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["https", "http", "mailto", "file"].contains(scheme)
        else { return nil }
        return url.absoluteString
    }

    private func writePortableBundle(
        threads: [LocalThreadRecord],
        projectName: String,
        to outputURL: URL,
        progress: ((SessionExportProgress) -> Void)?
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
        let orderedThreads = sorted(threads)
        for (index, thread) in orderedThreads.enumerated() {
            progress?(SessionExportProgress(
                completed: index,
                total: orderedThreads.count,
                currentItem: thread.title,
                stage: .reading,
                fraction: 0.80 * Double(index) / Double(orderedThreads.count)
            ))
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
            progress?(SessionExportProgress(
                completed: index + 1,
                total: orderedThreads.count,
                currentItem: thread.title,
                stage: .processing,
                fraction: 0.80 * Double(index + 1) / Double(orderedThreads.count)
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

        progress?(SessionExportProgress(
            completed: orderedThreads.count,
            total: orderedThreads.count,
            currentItem: outputURL.lastPathComponent,
            stage: .compressing,
            fraction: 0.90
        ))
        try createZipArchive(from: stagingRoot, to: archiveTemp)
        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: archiveTemp)
        } else {
            try fileManager.moveItem(at: archiveTemp, to: outputURL)
        }
    }

    private func transcriptEntries(
        at url: URL,
        progress: ((Int64, Int64) -> Void)? = nil
    ) throws -> [CodexTranscriptMessage] {
        guard fileManager.fileExists(atPath: url.path) else {
            throw ExportError(message: "找不到会话原始记录：\(url.lastPathComponent)")
        }
        var entries: [CodexTranscriptMessage] = []
        var seen = Set<String>()
        try forEachJSONLine(at: url, progress: progress) { object in
            guard let message = CodexTranscriptParser.message(from: object) else { return }
            let key = message.role.rawValue + "\u{0}" + message.text
            guard seen.insert(key).inserted else { return }
            entries.append(message)
        }
        return entries
    }

    private func forEachJSONLine(
        at url: URL,
        progress: ((Int64, Int64) -> Void)? = nil,
        handleObject: ([String: Any]) -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = Int64(values?.fileSize ?? 0)
        var processedBytes: Int64 = 0
        progress?(0, fileSize)
        var buffer = Data()
        while true {
            let chunk = try handle.read(upToCount: 64 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            processedBytes += Int64(chunk.count)
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                if !line.isEmpty,
                   let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                    handleObject(object)
                }
                buffer.removeSubrange(...newline)
            }
            progress?(processedBytes, fileSize)
        }
        if !buffer.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] {
            handleObject(object)
        }
        progress?(fileSize > 0 ? fileSize : processedBytes, fileSize)
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
