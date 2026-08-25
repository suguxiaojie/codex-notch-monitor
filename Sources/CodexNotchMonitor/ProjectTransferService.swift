import CryptoKit
import Foundation

struct ProjectTransferExportOptions: Codable, Equatable {
    var includeUntrackedFiles: Bool
    var includeAttachments: Bool
    var includeDeploymentArtifacts: Bool
    var includeArchives: Bool
    var includeLargeFiles: Bool

    init(
        includeUntrackedFiles: Bool,
        includeAttachments: Bool,
        includeDeploymentArtifacts: Bool = false,
        includeArchives: Bool = false,
        includeLargeFiles: Bool = false
    ) {
        self.includeUntrackedFiles = includeUntrackedFiles
        self.includeAttachments = includeAttachments
        self.includeDeploymentArtifacts = includeDeploymentArtifacts
        self.includeArchives = includeArchives
        self.includeLargeFiles = includeLargeFiles
    }

    private enum CodingKeys: String, CodingKey {
        case includeUntrackedFiles
        case includeAttachments
        case includeDeploymentArtifacts
        case includeArchives
        case includeLargeFiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        includeUntrackedFiles = try container.decodeIfPresent(
            Bool.self,
            forKey: .includeUntrackedFiles
        ) ?? true
        includeAttachments = try container.decodeIfPresent(
            Bool.self,
            forKey: .includeAttachments
        ) ?? true
        includeDeploymentArtifacts = try container.decodeIfPresent(
            Bool.self,
            forKey: .includeDeploymentArtifacts
        ) ?? false
        includeArchives = try container.decodeIfPresent(
            Bool.self,
            forKey: .includeArchives
        ) ?? false
        includeLargeFiles = try container.decodeIfPresent(
            Bool.self,
            forKey: .includeLargeFiles
        ) ?? false
    }

    static let defaults = ProjectTransferExportOptions(
        includeUntrackedFiles: true,
        includeAttachments: true,
        includeDeploymentArtifacts: false,
        includeArchives: false,
        includeLargeFiles: false
    )
}

struct ProjectTransferEstimate: Equatable {
    let includedFileCount: Int
    let includedBytes: Int64
    let excludedDeploymentCount: Int
    let excludedArchiveCount: Int
    let excludedLargeFileCount: Int
}

struct ProjectTransferGitMetadata: Codable, Equatable {
    struct UntrackedEntry: Codable, Equatable {
        let relativePath: String
        let included: Bool
        let reason: String?
    }

    let isRepository: Bool
    let repositoryRoot: String?
    let remoteURL: String?
    let branch: String?
    let head: String?
    let isDirty: Bool
    let workingTreePatchPath: String?
    let trackedFileCount: Int
    let untracked: [UntrackedEntry]
}

struct ProjectTransferAttachment: Codable, Equatable {
    enum Status: String, Codable {
        case included
        case missing
        case notSelected
        case excluded
    }

    let originalPath: String
    let bundlePath: String?
    let size: Int64?
    let sha256: String?
    let status: Status
    let reason: String?
    let threadIDs: [String]
}

struct ProjectTransferManifest: Codable, Equatable {
    static let supportedFormat = "codex-project-transfer/v1"

    struct Source: Codable, Equatable {
        let application: String
        let version: String
        let platform: String
    }

    struct Project: Codable, Equatable {
        let displayName: String
        let originalPath: String
    }

    struct FileEntry: Codable, Equatable {
        let relativePath: String
        let size: Int64
        let sha256: String
    }

    struct ExcludedEntry: Codable, Equatable {
        let relativePath: String
        let reason: String
    }

    let format: String
    let createdAt: String
    let source: Source
    let project: Project
    let files: [FileEntry]
    let excluded: [ExcludedEntry]
    let sessionsBundlePath: String
    let sessionCount: Int
    let exportOptions: ProjectTransferExportOptions?
    let git: ProjectTransferGitMetadata?
    let attachments: [ProjectTransferAttachment]?
}

struct ProjectTransferChecksums: Codable, Equatable {
    let algorithm: String
    let files: [String: String]
}

struct ProjectTransferPreview: Equatable {
    let bundleURL: URL
    let manifest: ProjectTransferManifest
    let duplicateThreadIDs: Set<String>
    let sourceAccountAliases: Set<String>
    let archiveBytes: Int64
    let expandedBytes: Int64
    let codexIsRunning: Bool

    var fileCount: Int { manifest.files.count }
    var sessionCount: Int { manifest.sessionCount }
    var excludedCount: Int { manifest.excluded.count }
    var duplicateCount: Int { duplicateThreadIDs.count }
    var totalProjectBytes: Int64 { manifest.files.reduce(0) { $0 + $1.size } }
    var includedAttachmentCount: Int {
        manifest.attachments?.filter { $0.status == .included }.count ?? 0
    }
    var missingAttachmentCount: Int {
        manifest.attachments?.filter { $0.status == .missing }.count ?? 0
    }
    var untrackedFileCount: Int { manifest.git?.untracked.count ?? 0 }
    var includedUntrackedFileCount: Int {
        manifest.git?.untracked.filter(\.included).count ?? 0
    }
}

enum ProjectTransferDirectoryDefaults {
    static func importContainerDirectory(
        originalProjectPath: String?,
        currentProjectDirectory: URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        let originalProjectDirectory = originalProjectPath.flatMap { path -> URL? in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
        }
        let candidates = [originalProjectDirectory, currentProjectDirectory]
            .compactMap { $0?.standardizedFileURL.deletingLastPathComponent() }

        for candidate in candidates {
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }
}

struct ProjectTransferImportResult: Equatable {
    let targetProjectURL: URL
    let importedFileCount: Int
    let importedAttachmentCount: Int
    let sessionImport: SessionImportResult
    let backupURL: URL
}

struct ProjectTransferLimits: Equatable {
    var maximumArchiveBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
    var maximumEntries = 100_000
    var maximumExpandedBytes: Int64 = 10 * 1_024 * 1_024 * 1_024
    var maximumSingleEntryBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    var maximumProjectFiles = 100_000
    var maximumProjectBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
    var maximumAttachmentBytes: Int64 = 1 * 1_024 * 1_024 * 1_024
    var maximumSingleAttachmentBytes: Int64 = 200 * 1_024 * 1_024
    var maximumCompressionRatio = 200.0
}

final class ProjectTransferService: @unchecked Sendable {
    struct TransferError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct TransactionManifest: Codable, Equatable {
        let version: Int
        let createdAt: Date
        let sourceBundle: String
        let targetPath: String
        let targetExisted: Bool
        let createdFiles: [String]
        let createdDirectories: [String]
        let sessionBackupPath: String?
        let globalStateExisted: Bool
        let globalStateBackupName: String?
        let globalStateSHA256: String?
        let attachmentRootPath: String?
        let createdAttachmentFiles: [String]?
    }

    private struct ValidatedBundle {
        let root: URL
        let manifest: ProjectTransferManifest
        let archiveBytes: Int64
        let expandedBytes: Int64
    }

    private struct GitInventory {
        let repositoryRoot: URL?
        let remoteURL: String?
        let branch: String?
        let head: String?
        let isDirty: Bool
        let tracked: Set<String>
        let untracked: Set<String>
        let ignored: Set<String>
        let patchData: Data?
    }

    private struct SnapshotCandidate {
        let sourceURL: URL
        let relativePath: String
        let size: Int64
    }

    private let fileManager: FileManager
    private let homeDirectory: URL
    private let backupRoot: URL
    private let now: () -> Date
    private let limits: ProjectTransferLimits
    private let importedAttachmentsRoot: URL
    private let sessionExportService: SessionExportService
    private let sessionImportService: SessionImportService
    private let codexIsRunning: () -> Bool

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupRoot: URL = AppPaths.continuityBackups
            .appendingPathComponent("project-imports", isDirectory: true),
        now: @escaping () -> Date = Date.init,
        limits: ProjectTransferLimits = ProjectTransferLimits(),
        importedAttachmentsRoot: URL = AppPaths.importedAttachments,
        sessionExportService: SessionExportService = SessionExportService(),
        sessionImportService: SessionImportService = SessionImportService(),
        codexIsRunning: @escaping () -> Bool = SessionRecoveryService.isCodexDesktopRunning
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.backupRoot = backupRoot
        self.now = now
        self.limits = limits
        self.importedAttachmentsRoot = importedAttachmentsRoot
        self.sessionExportService = sessionExportService
        self.sessionImportService = sessionImportService
        self.codexIsRunning = codexIsRunning
    }

    func estimate(
        threads: [LocalThreadRecord],
        options: ProjectTransferExportOptions = .defaults
    ) throws -> ProjectTransferEstimate {
        guard let projectPath = threads.first?.projectPath else {
            throw TransferError(message: "项目中没有可预检的会话")
        }
        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL
        guard isExistingDirectory(projectURL) else {
            throw TransferError(message: "项目目录不存在：\(projectURL.path)")
        }
        let git = inspectGit(projectURL: projectURL)
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        var enumerationFailure: String?
        guard let enumerator = fileManager.enumerator(
            at: projectURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, error in
                enumerationFailure = "\(url.path)：\(error.localizedDescription)"
                return false
            }
        ) else { throw TransferError(message: "无法预检项目目录") }
        var includedFileCount = 0
        var includedBytes: Int64 = 0
        var deploymentCount = 0
        var archiveCount = 0
        var largeFileCount = 0
        for case let url as URL in enumerator {
            let relativePath = try relativePath(of: url, under: projectURL)
            let values = try url.resourceValues(forKeys: Set(keys))
            let reason = exclusionReason(
                relativePath: relativePath,
                isDirectory: values.isDirectory == true,
                isSymbolicLink: values.isSymbolicLink == true,
                size: Int64(values.fileSize ?? 0),
                options: options
            )
            if let reason {
                if reason.contains("历史部署") { deploymentCount += 1 }
                if reason.contains("归档或部署包") { archiveCount += 1 }
                if reason.contains("大型文件") { largeFileCount += 1 }
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true { continue }
            if git.ignored.contains(relativePath) { continue }
            if git.untracked.contains(relativePath), !options.includeUntrackedFiles { continue }
            guard values.isRegularFile == true else { continue }
            includedFileCount += 1
            includedBytes += Int64(values.fileSize ?? 0)
        }
        if let enumerationFailure {
            throw TransferError(message: "项目预检不完整：\(enumerationFailure)")
        }
        return ProjectTransferEstimate(
            includedFileCount: includedFileCount,
            includedBytes: includedBytes,
            excludedDeploymentCount: deploymentCount,
            excludedArchiveCount: archiveCount,
            excludedLargeFileCount: largeFileCount
        )
    }

    func export(
        threads: [LocalThreadRecord],
        projectName: String,
        to outputURL: URL,
        options: ProjectTransferExportOptions = .defaults,
        progress: ((SessionExportProgress) -> Void)? = nil
    ) throws -> SessionExportResult {
        guard outputURL.pathExtension.lowercased() == "codexprojectbundle" else {
            throw TransferError(message: "完整项目迁移包必须使用 .codexprojectbundle")
        }
        let userThreads = threads.filter { $0.kind == .userConversation }
        guard !userThreads.isEmpty else {
            throw TransferError(message: "项目中没有可迁移的用户会话")
        }
        let paths = Set(userThreads.map { $0.projectPath })
        guard paths.count == 1, let sourcePath = paths.first else {
            throw TransferError(message: "项目迁移包只能包含同一项目路径的会话")
        }
        let projectURL = URL(fileURLWithPath: sourcePath, isDirectory: true).standardizedFileURL
        guard isExistingDirectory(projectURL), fileManager.isReadableFile(atPath: projectURL.path) else {
            throw TransferError(message: "项目目录不存在或不可读：\(projectURL.path)")
        }

        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("codex-project-export-\(UUID().uuidString)", isDirectory: true)
        let filesRoot = stagingRoot.appendingPathComponent("project/files", isDirectory: true)
        let sessionsRoot = stagingRoot.appendingPathComponent("sessions", isDirectory: true)
        let archiveTemp = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")
        try fileManager.createDirectory(at: filesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: stagingRoot)
            try? fileManager.removeItem(at: archiveTemp)
        }

        progress?(SessionExportProgress(
            completed: 0,
            total: userThreads.count,
            currentItem: "扫描项目文件",
            stage: .reading,
            fraction: 0.02
        ))
        let gitInventory = inspectGit(projectURL: projectURL) { step, total, item in
            progress?(SessionExportProgress(
                completed: step,
                total: total,
                currentItem: item,
                stage: .reading,
                fraction: 0.02 + 0.06 * Double(step) / Double(max(1, total))
            ))
        }
        let snapshot = try snapshotProject(
            from: projectURL,
            to: filesRoot,
            git: gitInventory,
            options: options,
            progress: progress
        )
        progress?(SessionExportProgress(
            completed: 0,
            total: userThreads.count,
            currentItem: "生成会话迁移包",
            stage: .processing,
            fraction: 0.58
        ))

        let sessionsRelativePath = "sessions/project.codexmonitorbundle"
        let sessionsURL = stagingRoot.appendingPathComponent(sessionsRelativePath)
        _ = try sessionExportService.export(
            threads: userThreads,
            projectName: projectName,
            format: .portableBundle,
            to: sessionsURL,
            progress: nil
        )

        let gitMetadata = makeGitMetadata(
            inventory: gitInventory,
            snapshot: snapshot,
            options: options
        )
        let gitRelativePath = "project/git.json"
        let gitData = try Self.encoder.encode(gitMetadata)
        try gitData.write(to: stagingRoot.appendingPathComponent(gitRelativePath), options: .atomic)
        if let patchPath = gitMetadata.workingTreePatchPath,
           let patchData = gitInventory.patchData {
            let patchURL = stagingRoot.appendingPathComponent(patchPath)
            try fileManager.createDirectory(
                at: patchURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try patchData.write(to: patchURL, options: .atomic)
        }

        let attachments = try collectAttachments(
            threads: userThreads,
            stagingRoot: stagingRoot,
            includeAttachments: options.includeAttachments
        )

        let manifest = ProjectTransferManifest(
            format: ProjectTransferManifest.supportedFormat,
            createdAt: Self.iso8601(now()),
            source: ProjectTransferManifest.Source(
                application: "Codex Notch Monitor",
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    ?? "development",
                platform: "macOS"
            ),
            project: ProjectTransferManifest.Project(
                displayName: projectName,
                originalPath: projectURL.path
            ),
            files: snapshot.files,
            excluded: snapshot.excluded,
            sessionsBundlePath: sessionsRelativePath,
            sessionCount: userThreads.count,
            exportOptions: options,
            git: gitMetadata,
            attachments: attachments
        )
        let encoder = Self.encoder
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: stagingRoot.appendingPathComponent("manifest.json"), options: .atomic)
        let notice = """
        Codex Notch Monitor 完整项目迁移包

        此包包含项目文件快照与原始 Codex 会话。导出器已默认排除凭据、密钥、数据库、上传目录、依赖与构建产物，但项目源码和会话仍可能包含敏感信息。
        P1 会记录已脱敏的 Git 远程、分支、HEAD、dirty patch 和未跟踪文件选择，并可选包含会话中仍存在的本地附件。缺失附件只记录报告，不伪造文件。
        请勿公开分享。此包不包含 auth.json、Cookie、Token 或独立账号凭据。
        格式：\(ProjectTransferManifest.supportedFormat)
        """
        let noticeData = Data(notice.utf8)
        try noticeData.write(to: stagingRoot.appendingPathComponent("README.txt"), options: .atomic)

        var checksums: [String: String] = [
            "manifest.json": Self.sha256(manifestData),
            "README.txt": Self.sha256(noticeData),
            sessionsRelativePath: try Self.sha256(of: sessionsURL),
            gitRelativePath: Self.sha256(gitData),
        ]
        if let patchPath = gitMetadata.workingTreePatchPath {
            checksums[patchPath] = try Self.sha256(
                of: stagingRoot.appendingPathComponent(patchPath)
            )
        }
        for file in snapshot.files {
            checksums["project/files/\(file.relativePath)"] = file.sha256
        }
        for attachment in attachments where attachment.status == .included {
            guard let bundlePath = attachment.bundlePath,
                  let digest = attachment.sha256 else { continue }
            checksums[bundlePath] = digest
        }
        try encoder.encode(ProjectTransferChecksums(
            algorithm: "SHA-256",
            files: checksums
        )).write(to: stagingRoot.appendingPathComponent("checksums.json"), options: .atomic)

        progress?(SessionExportProgress(
            completed: userThreads.count,
            total: userThreads.count,
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
            format: .projectBundle
        )
    }

    func inspect(
        bundleURL: URL,
        existingThreadIDs: Set<String>
    ) throws -> ProjectTransferPreview {
        guard bundleURL.pathExtension.lowercased() == "codexprojectbundle" else {
            throw TransferError(message: "请选择 .codexprojectbundle 完整项目迁移包")
        }
        let validated = try extractAndValidate(bundleURL)
        defer { try? fileManager.removeItem(at: validated.root) }
        let sessionsURL = validated.root.appendingPathComponent(
            validated.manifest.sessionsBundlePath
        )
        let sessionPreview = try sessionImportService.inspect(
            bundleURL: sessionsURL,
            existingThreadIDs: existingThreadIDs
        )
        guard sessionPreview.sessionCount == validated.manifest.sessionCount else {
            throw TransferError(message: "项目 Manifest 与嵌套会话包数量不一致")
        }
        return ProjectTransferPreview(
            bundleURL: bundleURL,
            manifest: validated.manifest,
            duplicateThreadIDs: sessionPreview.duplicateThreadIDs,
            sourceAccountAliases: Set(
                sessionPreview.manifest.sessions.compactMap(\.ownershipAlias)
            ),
            archiveBytes: validated.archiveBytes,
            expandedBytes: validated.expandedBytes,
            codexIsRunning: sessionPreview.codexIsRunning
        )
    }

    func importBundle(
        preview: ProjectTransferPreview,
        targetProjectURL: URL,
        duplicateStrategy: SessionImportDuplicateStrategy,
        progress: ((SessionImportProgress) -> Void)? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> ProjectTransferImportResult {
        guard !codexIsRunning() else {
            throw TransferError(message: "请先使用 Cmd + Q 完全退出 Codex／ChatGPT Desktop，再导入完整项目")
        }
        if duplicateStrategy == .skip,
           preview.sessionCount > 0,
           preview.duplicateCount == preview.sessionCount {
            throw TransferError(
                message: "包内全部会话 ID 都已存在；请选择“全部生成新 ID”，避免生成没有会话的空项目"
            )
        }
        let target = targetProjectURL.standardizedFileURL
        let targetExisted = fileManager.fileExists(atPath: target.path)
        try validateImportTarget(target, targetExisted: targetExisted)
        let validated = try extractAndValidate(preview.bundleURL)
        defer { try? fileManager.removeItem(at: validated.root) }

        let backupURL = try createTransactionBackup(
            sourceBundle: preview.bundleURL,
            target: target,
            targetExisted: targetExisted
        )
        var createdFiles: [String] = []
        var createdDirectories: [String] = []
        var sessionBackupURL: URL?
        var attachmentRootURL: URL?
        var createdAttachmentFiles: [String] = []
        do {
            try checkCancellation(isCancelled)
            if !targetExisted {
                try fileManager.createDirectory(
                    at: target,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            progress?(SessionImportProgress(
                stage: .importing,
                completed: 0,
                total: validated.manifest.files.count + validated.manifest.sessionCount,
                currentItem: "恢复项目文件"
            ))
            let filesRoot = validated.root.appendingPathComponent("project/files", isDirectory: true)
            for (index, file) in validated.manifest.files.enumerated() {
                try checkCancellation(isCancelled)
                let destination = target.appendingPathComponent(file.relativePath)
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw TransferError(message: "目标项目中已存在文件：\(file.relativePath)")
                }
                try createParentDirectories(
                    for: destination,
                    under: target,
                    recorded: &createdDirectories
                )
                try fileManager.copyItem(
                    at: filesRoot.appendingPathComponent(file.relativePath),
                    to: destination
                )
                createdFiles.append(file.relativePath)
                progress?(SessionImportProgress(
                    stage: .importing,
                    completed: index + 1,
                    total: validated.manifest.files.count + validated.manifest.sessionCount,
                    currentItem: file.relativePath
                ))
            }

            _ = try registerTargetProject(
                name: validated.manifest.project.displayName,
                path: target.path
            )

            let restoredAttachments = try restoreAttachments(
                manifest: validated.manifest,
                extractedRoot: validated.root
            )
            attachmentRootURL = restoredAttachments.root
            createdAttachmentFiles = restoredAttachments.createdFiles

            let sessionsURL = validated.root.appendingPathComponent(
                validated.manifest.sessionsBundlePath
            )
            let sessionPreview = try sessionImportService.inspect(
                bundleURL: sessionsURL,
                existingThreadIDs: []
            )
            guard sessionPreview.sessionCount == validated.manifest.sessionCount else {
                throw TransferError(message: "项目 Manifest 与嵌套会话包数量不一致")
            }
            let sessionResult = try sessionImportService.importBundle(
                preview: sessionPreview,
                mappedProjectURL: target,
                duplicateStrategy: duplicateStrategy,
                pathReplacements: restoredAttachments.pathReplacements,
                restoreArchivedAsActive: true,
                progress: progress,
                isCancelled: isCancelled
            )
            sessionBackupURL = sessionResult.backupURL
            try finishTransactionBackup(
                at: backupURL,
                createdFiles: createdFiles,
                createdDirectories: createdDirectories,
                sessionBackupURL: sessionResult.backupURL,
                attachmentRootURL: attachmentRootURL,
                createdAttachmentFiles: createdAttachmentFiles
            )
            return ProjectTransferImportResult(
                targetProjectURL: target,
                importedFileCount: createdFiles.count,
                importedAttachmentCount: createdAttachmentFiles.count,
                sessionImport: sessionResult,
                backupURL: backupURL
            )
        } catch {
            try? rollbackRuntime(
                target: target,
                targetExisted: targetExisted,
                createdFiles: createdFiles,
                createdDirectories: createdDirectories,
                sessionBackupURL: sessionBackupURL,
                projectBackupURL: backupURL,
                attachmentRootURL: attachmentRootURL,
                createdAttachmentFiles: createdAttachmentFiles
            )
            throw error
        }
    }

    func importSessionsOnly(
        bundleURL: URL,
        targetProjectURL: URL,
        progress: ((SessionImportProgress) -> Void)? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) throws -> SessionImportResult {
        guard !codexIsRunning() else {
            throw TransferError(message: "请先使用 Cmd + Q 完全退出 Codex／ChatGPT Desktop，再补导项目会话")
        }
        let target = targetProjectURL.standardizedFileURL
        guard isExistingDirectory(target), fileManager.isWritableFile(atPath: target.path) else {
            throw TransferError(message: "补导目标项目目录不存在或不可写：\(target.path)")
        }
        progress?(SessionImportProgress(
            stage: .validating,
            completed: 0,
            total: 0,
            currentItem: "校验完整项目迁移包"
        ))
        let validated = try extractAndValidate(bundleURL)
        defer { try? fileManager.removeItem(at: validated.root) }
        let sessionsURL = validated.root.appendingPathComponent(
            validated.manifest.sessionsBundlePath
        )
        let sessionPreview = try sessionImportService.inspect(
            bundleURL: sessionsURL,
            existingThreadIDs: []
        )
        guard sessionPreview.sessionCount == validated.manifest.sessionCount else {
            throw TransferError(message: "项目 Manifest 与嵌套会话包数量不一致")
        }
        return try sessionImportService.importBundle(
            preview: sessionPreview,
            mappedProjectURL: target,
            duplicateStrategy: .duplicate,
            restoreArchivedAsActive: true,
            progress: progress,
            isCancelled: isCancelled
        )
    }

    func rollbackImport(at backupURL: URL) throws {
        let manifest = try Self.decoder.decode(
            TransactionManifest.self,
            from: Data(contentsOf: backupURL.appendingPathComponent("project-import-manifest.json"))
        )
        guard manifest.version == 1 else {
            throw TransferError(message: "不支持的项目导入回滚格式")
        }
        try rollbackRuntime(
            target: URL(fileURLWithPath: manifest.targetPath, isDirectory: true),
            targetExisted: manifest.targetExisted,
            createdFiles: manifest.createdFiles,
            createdDirectories: manifest.createdDirectories,
            sessionBackupURL: manifest.sessionBackupPath.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            },
            projectBackupURL: backupURL,
            attachmentRootURL: manifest.attachmentRootPath.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            },
            createdAttachmentFiles: manifest.createdAttachmentFiles ?? []
        )
    }

    private func snapshotProject(
        from projectURL: URL,
        to filesRoot: URL,
        git: GitInventory,
        options: ProjectTransferExportOptions,
        progress: ((SessionExportProgress) -> Void)?
    ) throws -> (
        files: [ProjectTransferManifest.FileEntry],
        excluded: [ProjectTransferManifest.ExcludedEntry]
    ) {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ]
        var enumerationFailure: String?
        guard let enumerator = fileManager.enumerator(
            at: projectURL,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, error in
                enumerationFailure = "\(url.path)：\(error.localizedDescription)"
                return false
            }
        ) else { throw TransferError(message: "无法扫描项目目录") }
        var candidates: [SnapshotCandidate] = []
        var excluded: [ProjectTransferManifest.ExcludedEntry] = []
        var totalBytes: Int64 = 0
        var scannedEntries = 0
        for case let url as URL in enumerator {
            scannedEntries += 1
            let relativePath = try relativePath(of: url, under: projectURL)
            let values = try url.resourceValues(forKeys: Set(keys))
            if let reason = exclusionReason(
                relativePath: relativePath,
                isDirectory: values.isDirectory == true,
                isSymbolicLink: values.isSymbolicLink == true,
                size: Int64(values.fileSize ?? 0),
                options: options
            ) {
                excluded.append(.init(relativePath: relativePath, reason: reason))
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true { continue }
            if git.ignored.contains(relativePath) {
                excluded.append(.init(relativePath: relativePath, reason: "Git 忽略文件"))
                continue
            }
            if git.untracked.contains(relativePath), !options.includeUntrackedFiles {
                excluded.append(.init(
                    relativePath: relativePath,
                    reason: "导出时未选择包含 Git 未跟踪文件"
                ))
                continue
            }
            guard values.isRegularFile == true else {
                excluded.append(.init(relativePath: relativePath, reason: "不支持的文件类型"))
                continue
            }
            guard candidates.count < limits.maximumProjectFiles else {
                throw TransferError(message: "项目文件数超过上限 \(limits.maximumProjectFiles)")
            }
            let size = Int64(values.fileSize ?? 0)
            totalBytes += size
            guard totalBytes <= limits.maximumProjectBytes else {
                throw TransferError(message: "项目文件总大小超过上限")
            }
            candidates.append(SnapshotCandidate(
                sourceURL: url,
                relativePath: relativePath,
                size: size
            ))
            if scannedEntries == 1 || scannedEntries.isMultiple(of: 50) {
                progress?(SessionExportProgress(
                    completed: scannedEntries,
                    total: 0,
                    currentItem: "扫描项目文件 · 已发现 \(candidates.count) 个安全文件",
                    stage: .reading,
                    processedBytes: nil,
                    totalBytes: nil,
                    fraction: 0.09
                ))
            }
        }
        if let enumerationFailure {
            throw TransferError(message: "项目文件扫描不完整：\(enumerationFailure)")
        }
        var files: [ProjectTransferManifest.FileEntry] = []
        var processedBytes: Int64 = 0
        for (index, candidate) in candidates.enumerated() {
            let target = filesRoot.appendingPathComponent(candidate.relativePath)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: candidate.sourceURL, to: target)
            files.append(.init(
                relativePath: candidate.relativePath,
                size: candidate.size,
                sha256: try Self.sha256(of: target)
            ))
            processedBytes += candidate.size
            let fraction = candidates.isEmpty
                ? 0.54
                : 0.10 + 0.44 * Double(index + 1) / Double(candidates.count)
            progress?(SessionExportProgress(
                completed: index + 1,
                total: candidates.count,
                currentItem: candidate.relativePath,
                stage: .processing,
                processedBytes: processedBytes,
                totalBytes: totalBytes,
                fraction: fraction
            ))
        }
        return (
            files.sorted { $0.relativePath < $1.relativePath },
            excluded.sorted { $0.relativePath < $1.relativePath }
        )
    }

    private func inspectGit(
        projectURL: URL,
        progress: ((Int, Int, String) -> Void)? = nil
    ) -> GitInventory {
        let totalSteps = 7
        progress?(0, totalSteps, "确认 Git 仓库")
        let rootResult = runGit(["-C", projectURL.path, "rev-parse", "--show-toplevel"])
        guard rootResult.status == 0,
              let rootText = String(data: rootResult.output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rootText.isEmpty else {
            return GitInventory(
                repositoryRoot: nil,
                remoteURL: nil,
                branch: nil,
                head: nil,
                isDirty: false,
                tracked: [],
                untracked: [],
                ignored: [],
                patchData: nil
            )
        }
        let repositoryRoot = URL(fileURLWithPath: rootText, isDirectory: true).standardizedFileURL
        let prefix: String
        if projectURL.path == repositoryRoot.path {
            prefix = ""
        } else {
            prefix = (try? relativePath(of: projectURL, under: repositoryRoot)) ?? ""
        }
        let pathspec = prefix.isEmpty ? "." : prefix
        progress?(1, totalSteps, "读取 Git 已跟踪文件")
        let tracked = gitPathSet(
            runGit(["-C", repositoryRoot.path, "ls-files", "-z", "--", pathspec]).output,
            projectPrefix: prefix
        )
        progress?(2, totalSteps, "读取 Git 未跟踪文件")
        let untracked = gitPathSet(
            runGit([
                "-C", repositoryRoot.path, "ls-files", "--others", "--exclude-standard",
                "-z", "--", pathspec,
            ]).output,
            projectPrefix: prefix
        )
        progress?(3, totalSteps, "读取 Git 忽略文件")
        let ignored = gitPathSet(
            runGit([
                "-C", repositoryRoot.path, "ls-files", "--others", "--ignored",
                "--exclude-standard", "-z", "--", pathspec,
            ]).output,
            projectPrefix: prefix
        )
        progress?(4, totalSteps, "读取 Git 分支")
        let branch = gitString([
            "-C", repositoryRoot.path, "symbolic-ref", "--short", "-q", "HEAD",
        ])
        progress?(5, totalSteps, "读取 Git HEAD 和远程")
        let head = gitString(["-C", repositoryRoot.path, "rev-parse", "HEAD"])
        let remote = gitString(["-C", repositoryRoot.path, "remote", "get-url", "origin"])
            .map(Self.sanitizedRemoteURL)
        progress?(6, totalSteps, "生成 Git dirty patch")
        let status = runGit([
            "-C", repositoryRoot.path, "status", "--porcelain=v1", "-z", "--", pathspec,
        ]).output
        let patch = runGit([
            "-C", repositoryRoot.path, "diff", "--binary", "HEAD", "--", pathspec,
        ])
        let patchData = patch.status == 0 && !patch.output.isEmpty ? patch.output : nil
        progress?(7, totalSteps, "Git 信息读取完成")
        return GitInventory(
            repositoryRoot: repositoryRoot,
            remoteURL: remote,
            branch: branch,
            head: head,
            isDirty: !status.isEmpty,
            tracked: tracked,
            untracked: untracked,
            ignored: ignored,
            patchData: patchData
        )
    }

    private func makeGitMetadata(
        inventory: GitInventory,
        snapshot: (
            files: [ProjectTransferManifest.FileEntry],
            excluded: [ProjectTransferManifest.ExcludedEntry]
        ),
        options: ProjectTransferExportOptions
    ) -> ProjectTransferGitMetadata {
        let included = Set(snapshot.files.map(\.relativePath))
        let excludedReasons = Dictionary(
            uniqueKeysWithValues: snapshot.excluded.map { ($0.relativePath, $0.reason) }
        )
        let untracked = inventory.untracked.sorted().map { path in
            ProjectTransferGitMetadata.UntrackedEntry(
                relativePath: path,
                included: included.contains(path),
                reason: included.contains(path)
                    ? nil
                    : (excludedReasons[path]
                        ?? (options.includeUntrackedFiles ? "未进入安全项目快照" : "用户未选择包含"))
            )
        }
        return ProjectTransferGitMetadata(
            isRepository: inventory.repositoryRoot != nil,
            repositoryRoot: inventory.repositoryRoot?.path,
            remoteURL: inventory.remoteURL,
            branch: inventory.branch,
            head: inventory.head,
            isDirty: inventory.isDirty,
            workingTreePatchPath: inventory.patchData == nil
                ? nil
                : "project/working-tree.patch",
            trackedFileCount: inventory.tracked.count,
            untracked: untracked
        )
    }

    private func gitPathSet(_ data: Data, projectPrefix: String) -> Set<String> {
        let prefix = projectPrefix.isEmpty ? "" : projectPrefix + "/"
        return Set(data.split(separator: 0).compactMap { bytes in
            guard let value = String(data: Data(bytes), encoding: .utf8) else { return nil }
            if prefix.isEmpty { return value }
            guard value.hasPrefix(prefix) else { return nil }
            return String(value.dropFirst(prefix.count))
        })
    }

    private func gitString(_ arguments: [String]) -> String? {
        let result = runGit(arguments)
        guard result.status == 0,
              let text = String(data: result.output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private func runGit(_ arguments: [String]) -> (status: Int32, output: Data) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Drain stdout while Git is still running. Waiting first can
            // deadlock once ls-files output fills the pipe buffer.
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        } catch {
            return (-1, Data())
        }
    }

    private static func sanitizedRemoteURL(_ value: String) -> String {
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "http"
                || components.scheme?.lowercased() == "https" else {
            return value
        }
        components.user = nil
        components.password = nil
        return components.string ?? value
    }

    private func collectAttachments(
        threads: [LocalThreadRecord],
        stagingRoot: URL,
        includeAttachments: Bool
    ) throws -> [ProjectTransferAttachment] {
        var references: [String: Set<String>] = [:]
        for thread in threads {
            let paths = try attachmentPaths(in: thread.rolloutURL)
            for path in paths {
                references[path, default: []].insert(thread.id)
            }
        }
        var totalIncludedBytes: Int64 = 0
        var entries: [ProjectTransferAttachment] = []
        for originalPath in references.keys.sorted() {
            let source = URL(fileURLWithPath: originalPath).standardizedFileURL
            let threadIDs = references[originalPath, default: []].sorted()
            guard fileManager.fileExists(atPath: source.path) else {
                entries.append(ProjectTransferAttachment(
                    originalPath: originalPath,
                    bundlePath: nil,
                    size: nil,
                    sha256: nil,
                    status: .missing,
                    reason: "源设备上已找不到附件",
                    threadIDs: threadIDs
                ))
                continue
            }
            let values = try source.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                entries.append(ProjectTransferAttachment(
                    originalPath: originalPath,
                    bundlePath: nil,
                    size: nil,
                    sha256: nil,
                    status: .excluded,
                    reason: "附件不是普通文件或为符号链接",
                    threadIDs: threadIDs
                ))
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            guard includeAttachments else {
                entries.append(ProjectTransferAttachment(
                    originalPath: originalPath,
                    bundlePath: nil,
                    size: size,
                    sha256: nil,
                    status: .notSelected,
                    reason: "导出时未选择包含附件",
                    threadIDs: threadIDs
                ))
                continue
            }
            guard size <= limits.maximumSingleAttachmentBytes else {
                entries.append(ProjectTransferAttachment(
                    originalPath: originalPath,
                    bundlePath: nil,
                    size: size,
                    sha256: nil,
                    status: .excluded,
                    reason: "附件超过单文件大小上限",
                    threadIDs: threadIDs
                ))
                continue
            }
            guard totalIncludedBytes + size <= limits.maximumAttachmentBytes else {
                entries.append(ProjectTransferAttachment(
                    originalPath: originalPath,
                    bundlePath: nil,
                    size: size,
                    sha256: nil,
                    status: .excluded,
                    reason: "附件总大小超过上限",
                    threadIDs: threadIDs
                ))
                continue
            }
            let pathDigest = Self.sha256(Data(originalPath.utf8))
            let safeName = SessionExportService.safeFilenameStem(source.lastPathComponent)
            let bundlePath = "attachments/\(pathDigest.prefix(12))-\(safeName)"
            let target = stagingRoot.appendingPathComponent(bundlePath)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: target)
            let digest = try Self.sha256(of: target)
            totalIncludedBytes += size
            entries.append(ProjectTransferAttachment(
                originalPath: originalPath,
                bundlePath: bundlePath,
                size: size,
                sha256: digest,
                status: .included,
                reason: nil,
                threadIDs: threadIDs
            ))
        }
        return entries
    }

    private func attachmentPaths(in rolloutURL: URL) throws -> Set<String> {
        let handle = try FileHandle(forReadingFrom: rolloutURL)
        defer { try? handle.close() }
        var paths = Set<String>()
        var buffer = Data()
        while true {
            let chunk = try handle.read(upToCount: 256 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                collectAttachmentPaths(from: Data(buffer[..<newline]), into: &paths)
                buffer.removeSubrange(...newline)
            }
        }
        if !buffer.isEmpty { collectAttachmentPaths(from: buffer, into: &paths) }
        return paths
    }

    private func collectAttachmentPaths(from data: Data, into paths: inout Set<String>) {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return }
        var strings: [String] = []
        Self.collectStrings(object, into: &strings)
        for string in strings {
            for candidate in Self.absolutePathCandidates(in: string) {
                let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
                guard Self.isSupportedAttachmentPath(standardized) else { continue }
                paths.insert(standardized)
            }
        }
    }

    private static func collectStrings(_ value: Any, into strings: inout [String]) {
        if let string = value as? String {
            strings.append(string)
        } else if let array = value as? [Any] {
            for item in array { collectStrings(item, into: &strings) }
        } else if let dictionary = value as? [String: Any] {
            for item in dictionary.values { collectStrings(item, into: &strings) }
        }
    }

    private static func absolutePathCandidates(in value: String) -> Set<String> {
        var candidates = Set<String>()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") { candidates.insert(trimmed) }
        let pattern = #"/(?:Users|var|private/var)/[^\s\)\]\}>\"']+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return candidates }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        for match in regex.matches(in: value, range: range) {
            guard let swiftRange = Range(match.range, in: value) else { continue }
            let candidate = String(value[swiftRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,，；;"))
            candidates.insert(candidate)
        }
        return candidates
    }

    private static func isSupportedAttachmentPath(_ path: String) -> Bool {
        path.contains("/.codex/attachments/")
            || URL(fileURLWithPath: path).lastPathComponent.hasPrefix("codex-clipboard-")
    }

    private func exclusionReason(
        relativePath: String,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        size: Int64,
        options: ProjectTransferExportOptions
    ) -> String? {
        if isSymbolicLink { return "符号链接" }
        let components = relativePath.split(separator: "/").map { $0.lowercased() }
        let name = components.last ?? ""
        let excludedDirectories: Set<String> = [
            ".git", "node_modules", ".build", "build", "dist", "deriveddata",
            "uploads", "storage", "backups", ".cache", "coverage", ".venv",
            "venv", "vendor", ".terraform", ".next", ".turbo",
        ]
        if isDirectory, let matched = components.first(where: excludedDirectories.contains) {
            return "默认排除目录：\(matched)"
        }
        let displayName = String(name)
        if isDirectory,
           !options.includeDeploymentArtifacts,
           (displayName.contains("deployment-package")
            || displayName.contains("部署交付包")) {
            return "历史部署目录默认不重复打包"
        }
        if name == ".ds_store" { return "macOS 系统文件" }
        if name == ".env" || name.hasPrefix(".env.") || name == ".envrc" {
            return "环境变量凭据"
        }
        if [
            "auth.json", "credentials.json", "cookies.json", ".npmrc", ".pypirc",
            ".netrc", "id_rsa", "id_ed25519",
        ].contains(name) {
            return "账号凭据"
        }
        let fileExtension = URL(fileURLWithPath: String(name)).pathExtension.lowercased()
        let archiveExtensions: Set<String> = [
            "zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "xz", "dmg", "pkg",
        ]
        if !isDirectory,
           !options.includeArchives,
           archiveExtensions.contains(fileExtension) {
            return "已有归档或部署包默认不嵌套打包"
        }
        if ["pem", "key", "p12", "pfx", "mobileprovision"].contains(fileExtension) {
            return "密钥或证书"
        }
        if ["db", "sqlite", "sqlite3"].contains(fileExtension) { return "数据库需单独迁移" }
        if ["codexprojectbundle", "codexmonitorbundle"].contains(fileExtension) {
            return "已有迁移备份"
        }
        if !isDirectory,
           !options.includeLargeFiles,
           size >= 25 * 1_024 * 1_024 {
            return "大于等于 25 MB 的大型文件默认不打包"
        }
        return nil
    }

    private func extractAndValidate(_ bundleURL: URL) throws -> ValidatedBundle {
        let inspection = try inspectArchive(bundleURL)
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("codex-project-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try runDittoExtract(bundleURL, to: root)
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey]
            ) else { throw TransferError(message: "无法读取项目迁移包") }
            for case let url as URL in enumerator {
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    throw TransferError(message: "项目迁移包不允许符号链接")
                }
            }
            let manifest = try Self.decoder.decode(
                ProjectTransferManifest.self,
                from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
            )
            guard manifest.format == ProjectTransferManifest.supportedFormat else {
                throw TransferError(message: "不支持的项目迁移格式：\(manifest.format)")
            }
            guard manifest.files.count <= limits.maximumProjectFiles else {
                throw TransferError(message: "项目文件数超过允许上限")
            }
            let manifestPaths = manifest.files.map(\.relativePath)
            guard Set(manifestPaths).count == manifestPaths.count,
                  manifest.excluded.allSatisfy({ Self.isSafeRelativePath($0.relativePath) }) else {
                throw TransferError(message: "项目 Manifest 包含重复或不安全路径")
            }
            guard manifest.files.reduce(Int64(0), { $0 + $1.size }) <= limits.maximumProjectBytes else {
                throw TransferError(message: "项目 Manifest 文件总大小超过允许上限")
            }
            let checksums = try Self.decoder.decode(
                ProjectTransferChecksums.self,
                from: Data(contentsOf: root.appendingPathComponent("checksums.json"))
            )
            guard checksums.algorithm.uppercased() == "SHA-256" else {
                throw TransferError(message: "项目迁移包使用了不支持的校验算法")
            }
            var expectedPaths = Set(manifest.files.map { "project/files/\($0.relativePath)" })
                .union(["manifest.json", "README.txt", manifest.sessionsBundlePath])
            if let git = manifest.git {
                expectedPaths.insert("project/git.json")
                let gitDocument = try Self.decoder.decode(
                    ProjectTransferGitMetadata.self,
                    from: Data(contentsOf: root.appendingPathComponent("project/git.json"))
                )
                guard gitDocument == git else {
                    throw TransferError(message: "Git 元数据文档与 Manifest 不一致")
                }
                if let patchPath = git.workingTreePatchPath {
                    guard Self.isSafeRelativePath(patchPath) else {
                        throw TransferError(message: "Git patch 路径不安全")
                    }
                    expectedPaths.insert(patchPath)
                }
            }
            for attachment in manifest.attachments ?? [] where attachment.status == .included {
                guard let bundlePath = attachment.bundlePath,
                      let size = attachment.size,
                      let digest = attachment.sha256,
                      Self.isSafeRelativePath(bundlePath) else {
                    throw TransferError(message: "附件 Manifest 不完整或路径不安全")
                }
                let attachmentURL = root.appendingPathComponent(bundlePath)
                let attributes = try fileManager.attributesOfItem(atPath: attachmentURL.path)
                guard (attributes[.size] as? NSNumber)?.int64Value == size,
                      try Self.sha256(of: attachmentURL) == digest else {
                    throw TransferError(message: "附件完整性校验失败：\(attachment.originalPath)")
                }
                expectedPaths.insert(bundlePath)
            }
            guard Set(checksums.files.keys) == expectedPaths else {
                throw TransferError(message: "项目迁移包校验清单不完整")
            }
            let extractedFiles = try regularFilePaths(under: root)
            let allowedFiles = Set(checksums.files.keys).union(["checksums.json"])
            guard extractedFiles == allowedFiles else {
                throw TransferError(message: "项目迁移包包含未列入校验清单的额外文件")
            }
            for (relativePath, digest) in checksums.files {
                guard Self.isSafeRelativePath(relativePath) else {
                    throw TransferError(message: "项目迁移包校验路径不安全")
                }
                let file = root.appendingPathComponent(relativePath)
                guard fileManager.fileExists(atPath: file.path),
                      try Self.sha256(of: file) == digest else {
                    throw TransferError(message: "\(relativePath) 完整性校验失败")
                }
            }
            for file in manifest.files {
                guard Self.isSafeRelativePath(file.relativePath) else {
                    throw TransferError(message: "项目文件路径不安全")
                }
                let source = root.appendingPathComponent("project/files/\(file.relativePath)")
                let attributes = try fileManager.attributesOfItem(atPath: source.path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard size == file.size,
                      try Self.sha256(of: source) == file.sha256 else {
                    throw TransferError(message: "项目文件校验失败：\(file.relativePath)")
                }
            }
            guard manifest.sessionCount > 0,
                  Self.isSafeRelativePath(manifest.sessionsBundlePath),
                  fileManager.fileExists(
                    atPath: root.appendingPathComponent(manifest.sessionsBundlePath).path
                  ) else { throw TransferError(message: "项目迁移包缺少会话备份") }
            return ValidatedBundle(
                root: root,
                manifest: manifest,
                archiveBytes: inspection.archiveBytes,
                expandedBytes: inspection.expandedBytes
            )
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    private func inspectArchive(_ url: URL) throws -> (archiveBytes: Int64, expandedBytes: Int64) {
        let archiveBytes = ((try fileManager.attributesOfItem(atPath: url.path))[.size] as? NSNumber)?
            .int64Value ?? 0
        guard archiveBytes <= limits.maximumArchiveBytes else {
            throw TransferError(message: "项目迁移包压缩文件过大")
        }
        let entriesData = try runUnzipData(arguments: ["-Z1", url.path])
        let entries = entriesData.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard !entries.isEmpty else {
            throw TransferError(message: "项目迁移包为空")
        }
        guard entries.count <= limits.maximumEntries else {
            throw TransferError(message: "项目迁移包包含 \(entries.count) 个条目，超过 \(limits.maximumEntries) 上限")
        }
        for entry in entries where !Self.isSafeArchiveEntryBytes(entry) {
            let display = String(decoding: entry.prefix(180), as: UTF8.self)
            throw TransferError(message: "项目迁移包包含不安全路径：\(display)")
        }
        let listing = String(
            decoding: try runUnzipData(arguments: ["-Z", "-l", url.path]),
            as: UTF8.self
        )
        var expanded: Int64 = 0
        var compressed: Int64 = 0
        for line in listing.split(whereSeparator: \.isNewline) {
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 10,
                  let mode = columns.first,
                  mode.first == "-" || mode.first == "d" || mode.first == "l",
                  let expandedSize = Int64(columns[3]),
                  let compressedSize = Int64(columns[5]) else { continue }
            guard expandedSize <= limits.maximumSingleEntryBytes else {
                throw TransferError(message: "项目迁移包包含过大的单个文件")
            }
            expanded += expandedSize
            compressed += compressedSize
        }
        guard expanded <= limits.maximumExpandedBytes else {
            throw TransferError(message: "项目迁移包解压后总大小过大")
        }
        let ratio = compressed > 0 ? Double(expanded) / Double(compressed) : 1
        guard ratio <= limits.maximumCompressionRatio else {
            throw TransferError(message: "项目迁移包压缩比异常")
        }
        return (archiveBytes, expanded)
    }

    private func validateImportTarget(_ target: URL, targetExisted: Bool) throws {
        if targetExisted {
            guard isExistingDirectory(target), fileManager.isWritableFile(atPath: target.path) else {
                throw TransferError(message: "目标项目目录不可写")
            }
            let contents = try fileManager.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent != ".DS_Store" }
            guard contents.isEmpty else {
                throw TransferError(message: "P0 只允许导入到新目录或空目录，不会覆盖或合并现有文件")
            }
            return
        }
        let parent = target.deletingLastPathComponent()
        guard isExistingDirectory(parent), fileManager.isWritableFile(atPath: parent.path) else {
            throw TransferError(message: "目标项目的上级目录不可写")
        }
    }

    private func regularFilePaths(under root: URL) throws -> Set<String> {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { throw TransferError(message: "无法复核项目迁移包文件清单") }
        var paths = Set<String>()
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            paths.insert(try relativePath(of: url, under: root))
        }
        return paths
    }

    private func restoreAttachments(
        manifest: ProjectTransferManifest,
        extractedRoot: URL
    ) throws -> (
        root: URL?,
        pathReplacements: [String: String],
        createdFiles: [String]
    ) {
        let included = (manifest.attachments ?? []).filter { $0.status == .included }
        guard !included.isEmpty else { return (nil, [:], []) }
        let root = importedAttachmentsRoot.appendingPathComponent(
            "project-\(Self.timestamp(now()))-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var replacements: [String: String] = [:]
        var created: [String] = []
        do {
            for attachment in included {
                guard let bundlePath = attachment.bundlePath,
                      Self.isSafeRelativePath(bundlePath) else {
                    throw TransferError(message: "附件恢复路径不安全")
                }
                let source = extractedRoot.appendingPathComponent(bundlePath)
                let destination = root.appendingPathComponent(
                    URL(fileURLWithPath: bundlePath).lastPathComponent
                )
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw TransferError(message: "附件恢复目标重复：\(destination.lastPathComponent)")
                }
                try fileManager.copyItem(at: source, to: destination)
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destination.path
                )
                created.append(destination.path)
                replacements[attachment.originalPath] = destination.path
            }
            return (root, replacements, created)
        } catch {
            for path in created.reversed() where fileManager.fileExists(atPath: path) {
                try? fileManager.removeItem(atPath: path)
            }
            if fileManager.fileExists(atPath: root.path) {
                try? fileManager.removeItem(at: root)
            }
            throw error
        }
    }

    private var globalStateURL: URL {
        homeDirectory
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent(".codex-global-state.json")
    }

    private func registerTargetProject(name: String, path: String) throws -> String {
        let stateURL = globalStateURL
        var root: [String: Any] = [:]
        if fileManager.fileExists(atPath: stateURL.path) {
            let data = try Data(contentsOf: stateURL)
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw TransferError(message: "Codex 全局项目状态不是有效 JSON")
            }
            root = decoded
        }
        var projects = root["local-projects"] as? [String: Any] ?? [:]
        let normalizedPath = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        for (key, value) in projects {
            guard let project = value as? [String: Any],
                  let roots = project["rootPaths"] as? [String]
            else { continue }
            if roots.contains(where: {
                URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path == normalizedPath
            }) {
                return (project["id"] as? String) ?? key
            }
        }
        let projectID = UUID().uuidString.lowercased()
        let timestamp = Int64(now().timeIntervalSince1970 * 1_000)
        projects[projectID] = [
            "id": projectID,
            "name": name,
            "rootPaths": [normalizedPath],
            "createdAt": timestamp,
            "updatedAt": timestamp,
        ]
        root["local-projects"] = projects
        try fileManager.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let originalAttributes = try? fileManager.attributesOfItem(atPath: stateURL.path)
        try JSONSerialization.data(
            withJSONObject: root,
            options: [.withoutEscapingSlashes]
        ).write(to: stateURL, options: .atomic)
        if let permissions = originalAttributes?[.posixPermissions] {
            try? fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: stateURL.path
            )
        } else {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: stateURL.path
            )
        }
        return projectID
    }

    private func restoreGlobalState(from projectBackupURL: URL) throws {
        let manifest = try Self.decoder.decode(
            TransactionManifest.self,
            from: Data(contentsOf: projectBackupURL.appendingPathComponent("project-import-manifest.json"))
        )
        let stateURL = globalStateURL
        if manifest.globalStateExisted {
            guard let backupName = manifest.globalStateBackupName,
                  let expectedDigest = manifest.globalStateSHA256 else {
                throw TransferError(message: "项目导入的全局状态备份清单不完整")
            }
            let backup = projectBackupURL.appendingPathComponent(backupName)
            guard fileManager.fileExists(atPath: backup.path),
                  try Self.sha256(of: backup) == expectedDigest else {
                throw TransferError(message: "项目导入的全局状态备份校验失败")
            }
            try Data(contentsOf: backup).write(to: stateURL, options: .atomic)
        } else if fileManager.fileExists(atPath: stateURL.path) {
            try fileManager.removeItem(at: stateURL)
        }
    }

    private func createTransactionBackup(
        sourceBundle: URL,
        target: URL,
        targetExisted: Bool
    ) throws -> URL {
        let directory = backupRoot.appendingPathComponent(
            "project-import-\(Self.timestamp(now()))",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let manifest = TransactionManifest(
            version: 1,
            createdAt: now(),
            sourceBundle: sourceBundle.lastPathComponent,
            targetPath: target.path,
            targetExisted: targetExisted,
            createdFiles: [],
            createdDirectories: [],
            sessionBackupPath: nil,
            globalStateExisted: false,
            globalStateBackupName: nil,
            globalStateSHA256: nil,
            attachmentRootPath: nil,
            createdAttachmentFiles: []
        )
        let stateURL = globalStateURL
        let finalManifest: TransactionManifest
        if fileManager.fileExists(atPath: stateURL.path) {
            let backupName = ".codex-global-state.json"
            let backup = directory.appendingPathComponent(backupName)
            try fileManager.copyItem(at: stateURL, to: backup)
            finalManifest = TransactionManifest(
                version: manifest.version,
                createdAt: manifest.createdAt,
                sourceBundle: manifest.sourceBundle,
                targetPath: manifest.targetPath,
                targetExisted: manifest.targetExisted,
                createdFiles: manifest.createdFiles,
                createdDirectories: manifest.createdDirectories,
                sessionBackupPath: manifest.sessionBackupPath,
                globalStateExisted: true,
                globalStateBackupName: backupName,
                globalStateSHA256: try Self.sha256(of: backup),
                attachmentRootPath: manifest.attachmentRootPath,
                createdAttachmentFiles: manifest.createdAttachmentFiles
            )
        } else {
            finalManifest = manifest
        }
        try Self.encoder.encode(finalManifest).write(
            to: directory.appendingPathComponent("project-import-manifest.json"),
            options: .atomic
        )
        return directory
    }

    private func finishTransactionBackup(
        at backupURL: URL,
        createdFiles: [String],
        createdDirectories: [String],
        sessionBackupURL: URL,
        attachmentRootURL: URL?,
        createdAttachmentFiles: [String]
    ) throws {
        let url = backupURL.appendingPathComponent("project-import-manifest.json")
        let current = try Self.decoder.decode(TransactionManifest.self, from: Data(contentsOf: url))
        let finished = TransactionManifest(
            version: current.version,
            createdAt: current.createdAt,
            sourceBundle: current.sourceBundle,
            targetPath: current.targetPath,
            targetExisted: current.targetExisted,
            createdFiles: createdFiles,
            createdDirectories: createdDirectories,
            sessionBackupPath: sessionBackupURL.path,
            globalStateExisted: current.globalStateExisted,
            globalStateBackupName: current.globalStateBackupName,
            globalStateSHA256: current.globalStateSHA256,
            attachmentRootPath: attachmentRootURL?.path,
            createdAttachmentFiles: createdAttachmentFiles
        )
        try Self.encoder.encode(finished).write(to: url, options: .atomic)
    }

    private func rollbackRuntime(
        target: URL,
        targetExisted: Bool,
        createdFiles: [String],
        createdDirectories: [String],
        sessionBackupURL: URL?,
        projectBackupURL: URL,
        attachmentRootURL: URL?,
        createdAttachmentFiles: [String]
    ) throws {
        if let sessionBackupURL {
            try sessionImportService.rollbackImport(at: sessionBackupURL)
        }
        try restoreGlobalState(from: projectBackupURL)
        for path in createdAttachmentFiles.reversed()
            where fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
        if let attachmentRootURL,
           fileManager.fileExists(atPath: attachmentRootURL.path),
           (try? fileManager.contentsOfDirectory(atPath: attachmentRootURL.path).isEmpty) == true {
            try fileManager.removeItem(at: attachmentRootURL)
        }
        for relativePath in createdFiles.reversed() {
            let url = target.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
        for relativePath in createdDirectories.sorted(by: { $0.count > $1.count }) {
            let url = target.appendingPathComponent(relativePath, isDirectory: true)
            guard fileManager.fileExists(atPath: url.path),
                  (try? fileManager.contentsOfDirectory(atPath: url.path).isEmpty) == true
            else { continue }
            try fileManager.removeItem(at: url)
        }
        if !targetExisted,
           fileManager.fileExists(atPath: target.path),
           (try? fileManager.contentsOfDirectory(atPath: target.path).isEmpty) == true {
            try fileManager.removeItem(at: target)
        }
    }

    private func createParentDirectories(
        for destination: URL,
        under target: URL,
        recorded: inout [String]
    ) throws {
        let parent = destination.deletingLastPathComponent()
        guard parent.path != target.path else { return }
        var missing: [URL] = []
        var cursor = parent
        while cursor.path != target.path,
              !fileManager.fileExists(atPath: cursor.path) {
            missing.append(cursor)
            cursor.deleteLastPathComponent()
        }
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        for directory in missing.reversed() {
            recorded.append(try relativePath(of: directory, under: target))
        }
    }

    private func checkCancellation(_ isCancelled: () -> Bool) throws {
        if isCancelled() {
            throw TransferError(message: "项目导入已取消，已回滚项目文件和会话写入")
        }
    }

    private func relativePath(of url: URL, under root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            throw TransferError(message: "项目文件越出源目录")
        }
        let relative = String(path.dropFirst(rootPath.count + 1))
        guard Self.isSafeRelativePath(relative) else {
            throw TransferError(message: "项目文件路径不安全：\(relative)")
        }
        return relative
    }

    private func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func createZipArchive(from source: URL, to destination: URL) throws {
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", source.path, destination.path]
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TransferError(message: detail.isEmpty ? "无法生成项目迁移包" : detail)
        }
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
            throw TransferError(message: detail.isEmpty ? "无法解压项目迁移包" : detail)
        }
    }

    private func runUnzipData(arguments: [String]) throws -> Data {
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
            throw TransferError(message: "无法读取项目迁移包")
        }
        return data
    }

    private static func isSafeArchiveEntryBytes(_ value: Data.SubSequence) -> Bool {
        let bytes = Array(value)
        guard let first = bytes.first, first != 0x2F, first != 0x5C else { return false }
        var component: [UInt8] = []
        for byte in bytes + [0x2F] {
            if byte == 0x2F || byte == 0x5C {
                if component == [0x2E] || component == [0x2E, 0x2E] { return false }
                component.removeAll(keepingCapacity: true)
            } else {
                component.append(byte)
            }
        }
        return true
    }

    private static func isSafeArchiveEntry(_ value: String) -> Bool {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return !normalized.hasPrefix("/")
            && !components.contains("..")
            && !components.contains(".")
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return !normalized.hasPrefix("/")
            && !components.contains("..")
            && !components.contains(".")
            && !components.contains("")
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

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
