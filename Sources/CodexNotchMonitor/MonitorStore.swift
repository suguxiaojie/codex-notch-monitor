import AppKit
import Foundation
import UniformTypeIdentifiers

enum DisplayCutoutMode: Equatable {
    case notched
    case standardMenuBar
}

@MainActor
final class MonitorStore: ObservableObject {
    @Published private(set) var quotaState: QuotaState = .loading
    @Published private(set) var tasks: [MonitoredTask] = []
    @Published private(set) var activeProjects: [ActiveProjectState] = []
    @Published var selectedProjectID: String?
    @Published private(set) var costSnapshot: CostSnapshot = .empty
    @Published private(set) var usageAccountOptions: [UsageAccountOption] = []
    @Published private(set) var isCostLoading = false
    @Published private(set) var tiboFeed: TiboFeed?
    @Published private(set) var tiboFeedFetchedAt: Date?
    @Published private(set) var tiboFeedError: String?
    @Published private(set) var isTiboFeedLoading = false
    @Published private(set) var quotaResetEvents: [QuotaResetEvent] = []
    @Published private(set) var quotaNotificationStatus: QuotaNotificationStatus = .unknown
    @Published private(set) var observedAccount: ObservedAccount?
    @Published private(set) var accountTransition: AccountTransition?
    @Published private(set) var continuitySnapshot: SessionContinuitySnapshot = .empty
    @Published private(set) var continuityError: String?
    @Published private(set) var continuityStatusMessage: String?
    @Published private(set) var continuityScanProgress: (completed: Int, total: Int)?
    @Published private(set) var isContinuityLoading = false
    @Published private(set) var isContinuityRecovering = false
    @Published private(set) var lastContinuityBackupURL: URL?
    @Published private(set) var sessionImportPreview: SessionImportPreview?
    @Published private(set) var sessionImportMappedProjectURL: URL?
    @Published var sessionImportDuplicateStrategy: SessionImportDuplicateStrategy = .skip
    @Published private(set) var isSessionImporting = false
    @Published private(set) var lastSessionImportBackupURL: URL?
    @Published var isExpanded = false
    @Published var compactContentVisible = true
    @Published var expandedContentVisible = false
    @Published var isExpansionTransitioning = false
    @Published var notchObstructionWidth: CGFloat = 0
    @Published var compactPanelWidth: CGFloat = 326
    @Published var compactPanelHeight: CGFloat = 40
    @Published var compactMenuBarHeight: CGFloat = 33
    @Published var compactDetailsVisible = false
    @Published var displayCutoutMode: DisplayCutoutMode = .notched

    private let quotaService = QuotaService()
    private let sessionActivityService = SessionActivityService()
    private let costService = CostService()
    private let tiboFeedService = TiboFeedService()
    private let quotaResetMonitor = QuotaResetMonitor()
    private let quotaResetNotifier = QuotaResetNotifier()
    private let accountIdentityService = AccountIdentityService()
    private let accountContinuityStore = AccountContinuityStore()
    private let accountStateWatcher = CodexAccountStateWatcher()
    private let sessionExportService = SessionExportService()
    private let sessionImportService = SessionImportService()
    private let threadService = CodexThreadService()
    private lazy var sessionContinuityService = SessionContinuityService(threadService: threadService)
    private lazy var sessionRecoveryService = SessionRecoveryService(threadService: threadService)
    private var activeSessionExportPanel: NSSavePanel?
    private var activeSessionExportAccessory: SessionExportAccessoryController?
    private var activeSessionImportPanel: NSOpenPanel?
    private var eventTimer: Timer?
    private var quotaTimer: Timer?
    private var quotaRetryWorkItem: DispatchWorkItem?
    private var consecutiveQuotaFailures = 0
    private var isRefreshingQuota = false
    private var sessionTimer: Timer?
    private var isReadingSession = false
    private var costTimer: Timer?
    private var costRequestID: UUID?
    private var tiboFeedTimer: Timer?
    private var notificationStatusTimer: Timer?
    private var accountTimer: Timer?
    private var accountStateRefreshWorkItem: DispatchWorkItem?
    private var hasPendingAccountStateRefresh = false
    private var projectDisplayOrder: [String] = []
    private var lastProjectCatalogState: CodexProjectCatalog.State?

    var currentTask: MonitoredTask? {
        focusedProject?.task
    }

    var focusedProject: ActiveProjectState? {
        activeProjects.min { lhs, rhs in
            if lhs.task.phase.attentionPriority != rhs.task.phase.attentionPriority {
                return lhs.task.phase.attentionPriority < rhs.task.phase.attentionPriority
            }
            return lhs.task.updatedAt > rhs.task.updatedAt
        }
    }

    var selectedProject: ActiveProjectState? {
        if let selectedProjectID,
           let selected = activeProjects.first(where: { $0.id == selectedProjectID }) {
            return selected
        }
        return focusedProject
    }

    var sessionActivities: [SessionActivityItem] {
        selectedProject?.activities ?? []
    }

    var approvalProjectCount: Int {
        activeProjects.filter { $0.task.phase == .waitingApproval }.count
    }

    var compactProjectsHeight: CGFloat {
        guard compactDetailsVisible || approvalProjectCount > 0 else { return 0 }
        return CompactProjectLayout.contentHeight(for: activeProjects.count)
    }

    var visibleIslandWidth: CGFloat {
        isExpanded ? IslandPanelLayout.expandedWidth : compactPanelWidth
    }

    var usesNotchLayout: Bool {
        displayCutoutMode == .notched
    }

    /// Expanded content starts below the hardware camera while the black
    /// silhouette remains flush with the screen top, like CodexIsland.
    var visibleIslandHeight: CGFloat {
        isExpanded
            ? IslandPanelLayout.expandedContentHeight + compactMenuBarHeight
            : compactPanelHeight
    }

    var compactVisibleProjects: [ActiveProjectState] {
        guard activeProjects.count > 4 else { return activeProjects }
        return activeProjects.sorted { lhs, rhs in
            if lhs.task.phase.attentionPriority != rhs.task.phase.attentionPriority {
                return lhs.task.phase.attentionPriority < rhs.task.phase.attentionPriority
            }
            return lhs.task.updatedAt > rhs.task.updatedAt
        }.prefix(3).map { $0 }
    }

    /// The second compact row is reserved for an actionable detail. Progress
    /// prose belongs to the expanded activity list and should not duplicate
    /// the task-level headline in the menu bar.
    var compactDetailActivity: SessionActivityItem? {
        guard let project = focusedProject else { return nil }
        return project.latestDisplayActivity
    }

    var continuityAccountTitle: String {
        observedAccount?.alias
            ?? accountContinuityStore.currentAccountAlias()
            ?? "正在识别当前账号"
    }

    var continuityAccountSubtitle: String? {
        if let observedAccount {
            return [observedAccount.info.maskedEmail, observedAccount.info.planType?.uppercased()]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        if accountContinuityStore.currentAccountAlias() != nil {
            return "上次确认 · 正在验证"
        }
        return nil
    }

    func selectProject(_ id: String) {
        guard activeProjects.contains(where: { $0.id == id }) else { return }
        selectedProjectID = id
    }

    func start() {
        do { try AppPaths.prepareDirectories() } catch { }
        tiboFeed = tiboFeedService.cachedFeed
        tiboFeedFetchedAt = tiboFeedService.cachedAt
        quotaResetEvents = quotaResetMonitor.history
        quotaResetNotifier.requestAuthorization { [weak self] status in
            self?.quotaNotificationStatus = status
        }
        notificationStatusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNotificationStatus() }
        }
        refreshQuota()
        consumeHookEvents()
        refreshSessionActivity()
        refreshCost()
        refreshTiboFeed()
        refreshContinuity(forceInventory: true)
        accountStateWatcher.start { [weak self] in
            Task { @MainActor in
                self?.handleAccountStateChange()
            }
        }
        eventTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.consumeHookEvents() }
        }
        quotaTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshQuota() }
        }
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSessionActivity() }
        }
        costTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCost() }
        }
        tiboFeedTimer = Timer.scheduledTimer(
            withTimeInterval: TiboFeedService.refreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshTiboFeed() }
        }
        accountTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshContinuity() }
        }
    }

    func refreshQuota() {
        guard !isRefreshingQuota else { return }
        isRefreshingQuota = true
        let previous = quotaState.buckets
        if previous.isEmpty { quotaState = .loading }
        quotaService.fetch { [weak self] result in
            guard let self else { return }
            self.isRefreshingQuota = false
            switch result {
            case let .success(buckets):
                self.quotaRetryWorkItem?.cancel()
                self.quotaRetryWorkItem = nil
                self.consecutiveQuotaFailures = 0
                let now = Date()
                self.quotaState = .loaded(buckets, now)
                let evaluation = self.quotaResetMonitor.evaluate(
                    buckets: buckets,
                    feed: self.tiboFeed,
                    now: now
                )
                self.handleQuotaResetEvents(evaluation.events)
                if evaluation.needsFeedRefresh {
                    self.refreshTiboFeed()
                }
            case let .failure(error):
                self.quotaState = .failed(error.localizedDescription, previous: previous)
                self.scheduleQuotaRetry()
            }
        }
    }

    private func scheduleQuotaRetry() {
        quotaRetryWorkItem?.cancel()
        consecutiveQuotaFailures += 1
        // Startup/network races normally recover quickly. Back off to avoid
        // repeatedly spawning App Server while connectivity is genuinely down.
        let delays: [TimeInterval] = [8, 20, 60]
        let delay = delays[min(consecutiveQuotaFailures - 1, delays.count - 1)]
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.refreshQuota() }
        }
        quotaRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func refreshCost() {
        guard !isCostLoading else { return }
        isCostLoading = true
        let requestID = UUID()
        costRequestID = requestID
        let overrides = sessionProjectPathOverrides
        let accountContext = accountContinuityStore.usageAccountContext()
        usageAccountOptions = accountContext.accounts
        costService.fetch(
            sessionPathOverrides: overrides,
            accountContext: accountContext
        ) { [weak self] snapshot in
            guard let self else { return }
            guard self.costRequestID == requestID else { return }
            if self.accountContinuityStore.usageAccountContext() != accountContext {
                self.isCostLoading = false
                self.refreshCost()
                return
            }
            self.costSnapshot = snapshot
            self.isCostLoading = false
        }
    }

    func refreshAll() {
        refreshQuota()
        refreshTiboFeed()
        refreshContinuity(forceInventory: true)
        consumeHookEvents()
        refreshSessionActivity { [weak self] in
            self?.refreshCost()
        }
    }

    func refreshNotificationStatus() {
        quotaResetNotifier.refreshAuthorizationStatus { [weak self] status in
            self?.quotaNotificationStatus = status
        }
    }

    func openNotificationSettings() {
        _ = quotaResetNotifier.openNotificationSettings()
    }

    func refreshContinuity(forceInventory: Bool = false) {
        guard !isContinuityLoading, !isContinuityRecovering else { return }
        isContinuityLoading = true
        continuityScanProgress = nil
        if forceInventory || continuitySnapshot.checkedAt == .distantPast {
            refreshContinuityAndInventory()
            return
        }
        accountIdentityService.fetch { [weak self] accountResult in
            guard let self else { return }
            switch accountResult {
            case let .failure(error):
                self.continuityError = "当前账号暂时无法确认：\(error.localizedDescription)"
                if forceInventory || self.continuitySnapshot.checkedAt == .distantPast {
                    self.fetchContinuityInventory(account: nil)
                } else {
                    self.isContinuityLoading = false
                }
            case let .success(info):
                guard let info else {
                    self.continuityError = "Codex 当前未返回可识别账号"
                    if forceInventory || self.continuitySnapshot.checkedAt == .distantPast {
                        self.fetchContinuityInventory(account: nil)
                    } else {
                        self.isContinuityLoading = false
                    }
                    return
                }
                let changed = self.accountContinuityStore.accountChanged(info)
                if !changed, !forceInventory,
                   self.continuitySnapshot.checkedAt != .distantPast {
                    self.observedAccount = self.accountContinuityStore.observedAccount(for: info)
                    self.continuityError = nil
                    self.isContinuityLoading = false
                    return
                }
                self.fetchContinuityInventory(account: info)
            }
        }
    }

    private func refreshContinuityAndInventory() {
        var accountResult: Result<CodexAccountInfo?, Error>?
        var inventoryResult: Result<SessionContinuitySnapshot, Error>?

        func finishIfReady() {
            guard let accountResult, let inventoryResult else { return }
            self.isContinuityLoading = false
            self.continuityScanProgress = nil

            switch inventoryResult {
            case let .failure(error):
                self.continuityError = "会话盘点失败：\(error.localizedDescription)"
                if case let .success(info?) = accountResult {
                    self.observedAccount = self.accountContinuityStore.observedAccount(for: info)
                }
            case let .success(snapshot):
                switch accountResult {
                case let .failure(error):
                    self.continuitySnapshot = snapshot.applyingOwnership(
                        self.accountContinuityStore.ownershipByThread()
                    )
                    self.continuityError = "当前账号暂时无法确认：\(error.localizedDescription)"
                case .success(nil):
                    self.continuitySnapshot = snapshot.applyingOwnership(
                        self.accountContinuityStore.ownershipByThread()
                    )
                    self.continuityError = "Codex 当前未返回可识别账号"
                case let .success(account?):
                    self.applyContinuitySnapshot(snapshot, account: account)
                }
            }
        }

        accountIdentityService.fetch { result in
            accountResult = result
            finishIfReady()
        }
        sessionContinuityService.fetch(
            progress: { [weak self] completed, total in
                guard self?.isContinuityLoading == true else { return }
                self?.continuityScanProgress = (completed, total)
            },
            completion: { result in
                inventoryResult = result
                finishIfReady()
            }
        )
    }

    private func handleAccountStateChange() {
        hasPendingAccountStateRefresh = true
        schedulePendingAccountStateRefresh(after: 0)
    }

    private func schedulePendingAccountStateRefresh(after delay: TimeInterval) {
        accountStateRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.hasPendingAccountStateRefresh else { return }
            guard !self.isContinuityLoading, !self.isContinuityRecovering else {
                self.schedulePendingAccountStateRefresh(after: 0.35)
                return
            }
            self.hasPendingAccountStateRefresh = false
            self.refreshContinuity(forceInventory: true)
        }
        accountStateRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func recoverHiddenThreads() {
        let threads = continuitySnapshot.recoverableThreads
        guard !threads.isEmpty, !isContinuityRecovering else { return }
        isContinuityRecovering = true
        continuityError = nil
        continuityStatusMessage = "正在备份并恢复 \(threads.count) 条会话…"
        sessionRecoveryService.recover(threads: threads) { [weak self] result in
            guard let self else { return }
            self.isContinuityRecovering = false
            switch result {
            case let .failure(error):
                self.continuityError = error.localizedDescription
                self.continuityStatusMessage = nil
            case let .success(recovery):
                self.lastContinuityBackupURL = recovery.backupURL
                self.continuityStatusMessage = "已恢复 \(recovery.recoveredCount) / \(recovery.requestedCount) 条会话，新增 \(recovery.projectBindingsAdded) 条项目绑定"
                self.refreshContinuity(forceInventory: true)
            }
        }
    }

    func rollbackLastContinuityRecovery() {
        guard let backupURL = lastContinuityBackupURL, !isContinuityRecovering else { return }
        isContinuityRecovering = true
        continuityError = nil
        continuityStatusMessage = "正在恢复到上次操作前…"
        sessionRecoveryService.restoreBackup(at: backupURL) { [weak self] result in
            guard let self else { return }
            self.isContinuityRecovering = false
            switch result {
            case let .failure(error):
                self.continuityError = "回滚失败：\(error.localizedDescription)"
                self.continuityStatusMessage = nil
            case .success:
                self.continuityStatusMessage = "已恢复到上次操作前的本地状态"
                self.lastContinuityBackupURL = nil
                self.refreshContinuity(forceInventory: true)
            }
        }
    }

    func copyHandoffSummary(for thread: LocalThreadRecord) {
        guard thread.canExportSummary else { return }
        let context = SessionContinuityService.handoffContext(for: thread)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(context, forType: .string)
        continuityError = nil
        continuityStatusMessage = "已复制「\(thread.title)」的脱敏交接摘要"
    }

    func exportSession(_ thread: LocalThreadRecord) {
        presentSessionExportPanel(
            threads: [thread],
            projectName: thread.projectName,
            filenameStem: thread.title
        )
    }

    func exportProject(_ project: ContinuityProjectGroup) {
        presentSessionExportPanel(
            threads: project.threads,
            projectName: project.name,
            filenameStem: "\(project.name)-Codex-会话"
        )
    }

    private func presentSessionExportPanel(
        threads: [LocalThreadRecord],
        projectName: String,
        filenameStem: String
    ) {
        guard !threads.isEmpty else { return }
        if let activeSessionExportPanel {
            NSApp.activate(ignoringOtherApps: true)
            activeSessionExportPanel.orderFrontRegardless()
            activeSessionExportPanel.makeKey()
            return
        }

        let panel = NSSavePanel()
        panel.title = threads.count == 1 ? "导出 Codex 会话" : "导出 Codex 项目会话"
        panel.prompt = "导出"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "可读副本会脱敏；可恢复备份保留原始 JSONL，可能包含源码、路径、图片和终端输出。"
        panel.directoryURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first

        let accessory = SessionExportAccessoryController(
            panel: panel,
            filenameStem: SessionExportService.safeFilenameStem(filenameStem)
        )
        panel.accessoryView = accessory.view
        accessory.applySelection()

        // The island is a nonactivating panel at status-bar level. A default
        // save panel opens below it and can look as if the button did nothing.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior.insert(.moveToActiveSpace)
        activeSessionExportPanel = panel
        activeSessionExportAccessory = accessory
        continuityError = nil
        continuityStatusMessage = "请选择导出格式和保存位置"

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self, weak panel] response in
            guard let self else { return }
            let outputURL = panel?.url
            let format = self.activeSessionExportAccessory?.selectedFormat
            self.activeSessionExportPanel = nil
            self.activeSessionExportAccessory = nil
            guard response == .OK,
                  let outputURL,
                  let format
            else {
                self.continuityStatusMessage = nil
                return
            }
            let exportService = self.sessionExportService
            self.continuityError = nil
            self.continuityStatusMessage = "正在导出 \(threads.count) 条会话…"
            DispatchQueue.global(qos: .utility).async {
                let result = Result {
                    try exportService.export(
                        threads: threads,
                        projectName: projectName,
                        format: format,
                        to: outputURL
                    )
                }
                DispatchQueue.main.async {
                    switch result {
                    case let .success(exported):
                        self.continuityError = nil
                        self.continuityStatusMessage = "已导出 \(exported.sessionCount) 条会话：\(exported.outputURL.lastPathComponent)"
                        NSWorkspace.shared.activateFileViewerSelecting([exported.outputURL])
                    case let .failure(error):
                        self.continuityStatusMessage = nil
                        self.continuityError = "导出失败：\(error.localizedDescription)"
                    }
                }
            }
        }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func chooseSessionImportBundle() {
        presentSessionImportPanel(selectingDirectory: false)
    }

    func chooseSessionImportProjectDirectory() {
        presentSessionImportPanel(selectingDirectory: true)
    }

    func cancelSessionImport() {
        guard !isSessionImporting else { return }
        sessionImportPreview = nil
        sessionImportMappedProjectURL = nil
        continuityStatusMessage = nil
    }

    func importSelectedSessionBundle() {
        guard let preview = sessionImportPreview, !isSessionImporting else { return }
        isSessionImporting = true
        continuityError = nil
        continuityStatusMessage = "正在备份当前状态并导入 \(preview.sessionCount) 条会话…"
        let service = sessionImportService
        let mappedURL = sessionImportMappedProjectURL
        let strategy = sessionImportDuplicateStrategy
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try service.importBundle(
                    preview: preview,
                    mappedProjectURL: mappedURL,
                    duplicateStrategy: strategy
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .failure(error):
                    self.isSessionImporting = false
                    self.continuityStatusMessage = nil
                    self.continuityError = error.localizedDescription
                case let .success(imported):
                    self.lastSessionImportBackupURL = imported.backupURL
                    self.threadService.rebuildThreadIndex { visibilityResult in
                        self.isSessionImporting = false
                        self.sessionImportPreview = nil
                        self.sessionImportMappedProjectURL = nil
                        let visible = (try? visibilityResult.get()) ?? []
                        let visibleCount = imported.importedThreadIDs.intersection(visible).count
                        self.continuityError = nil
                        self.continuityStatusMessage = "已导入 \(imported.importedCount) 条，跳过 \(imported.skippedDuplicateCount) 条重复，App Server 可见 \(visibleCount) 条"
                        self.refreshContinuity(forceInventory: true)
                        self.refreshCost()
                    }
                }
            }
        }
    }

    func rollbackLastSessionImport() {
        guard let backupURL = lastSessionImportBackupURL, !isSessionImporting else { return }
        isSessionImporting = true
        continuityError = nil
        continuityStatusMessage = "正在撤销上次会话导入…"
        let service = sessionImportService
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try service.rollbackImport(at: backupURL) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSessionImporting = false
                switch result {
                case let .failure(error):
                    self.continuityStatusMessage = nil
                    self.continuityError = "撤销导入失败：\(error.localizedDescription)"
                case .success:
                    self.lastSessionImportBackupURL = nil
                    self.continuityError = nil
                    self.continuityStatusMessage = "已撤销上次会话导入"
                    self.refreshContinuity(forceInventory: true)
                    self.refreshCost()
                }
            }
        }
    }

    private func presentSessionImportPanel(selectingDirectory: Bool) {
        if let activeSessionImportPanel {
            NSApp.activate(ignoringOtherApps: true)
            activeSessionImportPanel.orderFrontRegardless()
            activeSessionImportPanel.makeKey()
            return
        }
        let panel = NSOpenPanel()
        panel.title = selectingDirectory ? "选择新的项目目录" : "选择 Codex 会话备份"
        panel.prompt = selectingDirectory ? "映射到此目录" : "检查备份"
        panel.canChooseDirectories = selectingDirectory
        panel.canChooseFiles = !selectingDirectory
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if !selectingDirectory {
            panel.allowedContentTypes = [UTType(filenameExtension: "codexmonitorbundle") ?? .zip]
            panel.message = "只会进行完整性检查和预览，确认导入前不会改写 ~/.codex。"
        }
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior.insert(.moveToActiveSpace)
        activeSessionImportPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self, weak panel] response in
            guard let self else { return }
            let selectedURL = panel?.url
            self.activeSessionImportPanel = nil
            guard response == .OK, let selectedURL else { return }
            if selectingDirectory {
                self.sessionImportMappedProjectURL = selectedURL.standardizedFileURL
                return
            }
            self.inspectSessionImportBundle(at: selectedURL)
        }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func inspectSessionImportBundle(at url: URL) {
        continuityError = nil
        continuityStatusMessage = "正在校验会话备份…"
        let service = sessionImportService
        let existingIDs = Set(continuitySnapshot.userThreads.map(\.id))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try service.inspect(bundleURL: url, existingThreadIDs: existingIDs) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .failure(error):
                    self.sessionImportPreview = nil
                    self.continuityStatusMessage = nil
                    self.continuityError = "备份检查失败：\(error.localizedDescription)"
                case let .success(preview):
                    self.sessionImportPreview = preview
                    self.sessionImportMappedProjectURL = preview.requiresPathMapping ? nil : URL(
                        fileURLWithPath: preview.manifest.project.originalPath,
                        isDirectory: true
                    )
                    self.sessionImportDuplicateStrategy = .skip
                    self.continuityError = nil
                    self.continuityStatusMessage = nil
                }
            }
        }
    }

    private func fetchContinuityInventory(account: CodexAccountInfo?) {
        continuityScanProgress = nil
        sessionContinuityService.fetch(
            progress: { [weak self] completed, total in
                guard self?.isContinuityLoading == true else { return }
                self?.continuityScanProgress = (completed, total)
            }
        ) { [weak self] result in
            guard let self else { return }
            self.isContinuityLoading = false
            self.continuityScanProgress = nil
            switch result {
            case let .failure(error):
                self.continuityError = "会话盘点失败：\(error.localizedDescription)"
            case let .success(snapshot):
                if let account {
                    self.applyContinuitySnapshot(snapshot, account: account)
                } else {
                    self.continuitySnapshot = snapshot.applyingOwnership(
                        self.accountContinuityStore.ownershipByThread()
                    )
                }
                if account != nil {
                    self.continuityError = nil
                }
            }
        }
    }

    private func applyContinuitySnapshot(
        _ snapshot: SessionContinuitySnapshot,
        account: CodexAccountInfo
    ) {
        do {
            let previousUsageContext = accountContinuityStore.usageAccountContext()
            let observation = try accountContinuityStore.observe(
                account: account,
                localSessionIDs: Set(snapshot.userThreads.map(\.id))
            )
            observedAccount = observation.account
            accountTransition = observation.transition
            continuitySnapshot = snapshot.applyingOwnership(observation.ownershipByThread)
            continuityError = nil
            if accountContinuityStore.usageAccountContext() != previousUsageContext {
                refreshCost()
            }
            if let transition = observation.transition {
                let recoverableCount = snapshot.recoverableThreads.count
                if recoverableCount == 0 {
                    continuityStatusMessage = "已切换至 \(transition.currentAlias)，本地项目与会话已同步"
                } else {
                    continuityStatusMessage = "已切换至 \(transition.currentAlias)，发现 \(recoverableCount) 条会话待恢复"
                }
                quotaResetNotifier.notifyAccountSwitch(
                    transition,
                    projectCount: snapshot.projectCount,
                    sessionCount: snapshot.sessionCount,
                    recoverableCount: recoverableCount
                )
            }
        } catch {
            continuitySnapshot = snapshot.applyingOwnership(
                accountContinuityStore.ownershipByThread()
            )
            continuityError = "账号连续性状态保存失败：\(error.localizedDescription)"
        }
    }

    func refreshTiboFeed(ifOlderThan minimumAge: TimeInterval = 0) {
        guard !isTiboFeedLoading else { return }
        if minimumAge > 0, let fetchedAt = tiboFeedFetchedAt,
           Date().timeIntervalSince(fetchedAt) < minimumAge {
            return
        }
        isTiboFeedLoading = true
        tiboFeedService.fetch { [weak self] result in
            guard let self else { return }
            self.isTiboFeedLoading = false
            switch result {
            case let .success((feed, fetchedAt)):
                self.tiboFeed = feed
                self.tiboFeedFetchedAt = fetchedAt
                self.tiboFeedError = feed.monitor.status == "ok"
                    ? nil
                    : "数据源状态：\(feed.monitor.errorCode ?? feed.monitor.status)"
                self.handleQuotaResetEvents(self.quotaResetMonitor.reconcile(feed: feed))
            case let .failure(error):
                // Preserve the last verified feed during transient outages.
                self.tiboFeedError = error.localizedDescription
            }
        }
    }

    private func handleQuotaResetEvents(_ events: [QuotaResetEvent]) {
        quotaResetEvents = quotaResetMonitor.history
        for event in events where event.reason.isNotifiable {
            quotaResetNotifier.notify(event)
        }
    }

    private var sessionProjectPathOverrides: [String: String] {
        var result: [String: String] = [:]
        for project in activeProjects {
            for session in project.sessions {
                result[session.id] = session.task.projectPath
            }
        }
        for task in tasks where task.phase.isActive {
            result[task.id] = task.projectPath
        }
        return result
    }

    func consumeHookEvents() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: AppPaths.eventInbox,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            defer { try? manager.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file),
                  let event = try? decoder.decode(HookEvent.self, from: data)
            else { continue }
            apply(event)
        }
    }

    func refreshSessionActivity(completion: (() -> Void)? = nil) {
        guard !isReadingSession else {
            completion?()
            return
        }
        isReadingSession = true
        sessionActivityService.fetch { [weak self] snapshots in
            guard let self else {
                completion?()
                return
            }
            self.isReadingSession = false
            let catalog = CodexProjectCatalog.loadState()
            let catalogChanged = self.lastProjectCatalogState.map { $0 != catalog } ?? false
            self.lastProjectCatalogState = catalog
            let discovered = ProjectActivityAggregator.projects(
                snapshots: snapshots,
                hookTasks: self.tasks,
                catalog: catalog
            )
            self.projectDisplayOrder = CompactProjectLayout.reconcileOrder(
                existing: self.projectDisplayOrder,
                discovered: discovered.map(\.id)
            )
            let byID = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
            self.activeProjects = self.projectDisplayOrder.compactMap { byID[$0] }
            if let selected = self.selectedProjectID,
               !self.activeProjects.contains(where: { $0.id == selected }) {
                self.selectedProjectID = nil
            }
            completion?()
            if catalogChanged { self.refreshCost() }
        }
    }

    private func apply(_ event: HookEvent) {
        let incoming = HookEventMapper.task(from: event)
        let previousPath = tasks.first(where: { $0.id == incoming.id })?.projectPath
        if let index = tasks.firstIndex(where: { $0.id == incoming.id }) {
            tasks[index] = incoming
        } else {
            tasks.append(incoming)
        }
        tasks.sort { $0.updatedAt > $1.updatedAt }
        if tasks.count > 8 { tasks = Array(tasks.prefix(8)) }
        if previousPath != nil, previousPath != incoming.projectPath {
            refreshCost()
        }
    }
}

private final class SessionExportAccessoryController: NSObject {
    let view: NSView
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var panel: NSSavePanel?
    private let filenameStem: String

    var selectedFormat: SessionExportFormat {
        let index = max(0, popup.indexOfSelectedItem)
        return SessionExportFormat.allCases[index]
    }

    init(panel: NSSavePanel, filenameStem: String) {
        self.panel = panel
        self.filenameStem = filenameStem
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 70))
        super.init()

        let title = NSTextField(labelWithString: "导出格式")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.frame = NSRect(x: 0, y: 44, width: 100, height: 18)
        view.addSubview(title)

        popup.addItems(withTitles: SessionExportFormat.allCases.map(\.title))
        popup.selectItem(at: 0)
        popup.target = self
        popup.action = #selector(formatChanged)
        popup.frame = NSRect(x: 0, y: 16, width: 260, height: 26)
        view.addSubview(popup)

        let note = NSTextField(labelWithString: "原始备份用于本地恢复，请勿公开分享。")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 10)
        note.frame = NSRect(x: 270, y: 20, width: 150, height: 18)
        view.addSubview(note)
    }

    @objc private func formatChanged() {
        applySelection()
    }

    func applySelection() {
        guard let panel else { return }
        let contentType: UTType
        switch selectedFormat {
        case .markdown:
            contentType = UTType(filenameExtension: "md") ?? .plainText
        case .html:
            contentType = .html
        case .portableBundle:
            contentType = UTType(filenameExtension: selectedFormat.fileExtension) ?? .zip
        }
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = "\(filenameStem).\(selectedFormat.fileExtension)"
    }
}
