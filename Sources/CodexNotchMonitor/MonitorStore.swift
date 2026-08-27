import AppKit
import Foundation
import UniformTypeIdentifiers

enum DisplayCutoutMode: Equatable {
    case notched
    case standardMenuBar
}

struct SessionImportProjectOption: Identifiable, Equatable {
    let name: String
    let path: String
    let isOriginal: Bool
    let isRegistered: Bool

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }
}

struct SessionExportDraft: Identifiable {
    let id = UUID()
    let threads: [LocalThreadRecord]
    let projectName: String
    let allowsProjectBundle: Bool
    let projectEstimate: ProjectTransferEstimate?
    var selectedFormat: SessionExportFormat
    var filenameStem: String
    var destinationDirectory: URL
    var projectTransferOptions: ProjectTransferExportOptions

    var availableFormats: [SessionExportFormat] {
        SessionExportFormat.allCases.filter {
            allowsProjectBundle || $0 != .projectBundle
        }
    }

    var title: String {
        selectedFormat == .projectBundle
            ? "导出完整 Codex 项目"
            : (threads.count == 1 ? "导出 Codex 会话" : "导出项目会话")
    }

    var outputFilename: String {
        let safeStem = SessionExportService.safeFilenameStem(filenameStem)
        return "\(safeStem).\(selectedFormat.fileExtension)"
    }
}

struct PendingProjectSessionRepair: Codable, Equatable, Identifiable {
    let id: UUID
    let bundlePath: String
    let targetProjectPath: String
    let requestedAt: Date
}

@MainActor
final class MonitorStore: ObservableObject {
    private struct QuotaResetAttempt {
        let idempotencyKey: UUID
        let creditID: String?
    }

    @Published private(set) var quotaState: QuotaState = .loading
    @Published private(set) var quotaResetCredits: QuotaResetCreditSummary?
    @Published private(set) var isConsumingQuotaResetCredit = false
    @Published private(set) var quotaResetOperationMessage: String?
    @Published private(set) var tasks: [MonitoredTask] = []
    @Published private(set) var activeProjects: [ActiveProjectState] = []
    @Published var selectedProjectID: String?
    @Published private(set) var costSnapshot: CostSnapshot = .empty
    @Published private(set) var usageAccountOptions: [UsageAccountOption] = []
    @Published private(set) var isCostLoading = false
    @Published private(set) var tiboFeed: TiboFeed?
    @Published private(set) var tiboRadar: CodexResetRadarSnapshot?
    @Published private(set) var tiboFeedFetchedAt: Date?
    @Published private(set) var tiboFeedError: String?
    @Published private(set) var isTiboFeedLoading = false
    @Published private(set) var quotaResetEvents: [QuotaResetEvent] = []
    @Published private(set) var quotaNotificationStatus: QuotaNotificationStatus = .unknown
    @Published private(set) var codexSetupSnapshot: CodexSetupSnapshot?
    @Published private(set) var codexSetupMessage: String?
    @Published private(set) var isCodexSetupWorking = false
    @Published private(set) var isSetupOnboardingComplete = false
    @Published private(set) var isCodexSecurityReviewLaunching = false
    @Published private(set) var appUpdateStatus = AppUpdateStatus.idle(
        currentVersion: AppUpdateService.bundleVersion,
        currentBuild: AppUpdateService.bundleBuild
    )
    @Published private(set) var appUpdateMessage: String?
    @Published private(set) var isManualAppUpdateCheck = false
    @Published private(set) var observedAccount: ObservedAccount?
    @Published private(set) var accountTransition: AccountTransition?
    @Published private(set) var continuitySnapshot: SessionContinuitySnapshot = .empty
    @Published private(set) var continuityError: String?
    @Published private(set) var continuityStatusMessage: String?
    @Published private(set) var continuityDeletionFailure: String?
    @Published private(set) var pendingSidebarCleanupCount = 0
    @Published private(set) var lastSidebarCleanupBackupURL: URL?
    @Published private(set) var continuityScanProgress: (completed: Int, total: Int)?
    @Published private(set) var sessionExportProgress: SessionExportProgress?
    @Published private(set) var sessionExportDraft: SessionExportDraft?
    @Published private(set) var lastSessionExportURL: URL?
    @Published private(set) var isSessionExporting = false
    @Published private(set) var isContinuityLoading = false
    @Published private(set) var isContinuityRecovering = false
    @Published private(set) var deletingContinuityThreadID: String?
    @Published private(set) var deletingContinuityProjectID: String?
    @Published private(set) var lastContinuityBackupURL: URL?
    @Published private(set) var sessionImportPreview: SessionImportPreview?
    @Published private(set) var projectTransferPreview: ProjectTransferPreview?
    @Published private(set) var sessionImportMappedProjectURL: URL?
    @Published private(set) var projectImportTargetURL: URL?
    @Published private(set) var sessionImportProjectOptions: [SessionImportProjectOption] = []
    @Published var sessionImportDuplicateStrategy: SessionImportDuplicateStrategy = .skip
    @Published private(set) var isSessionImportInspecting = false
    @Published private(set) var sessionImportInspectionStartedAt: Date?
    @Published private(set) var sessionImportInspectionTitle: String?
    @Published private(set) var isSessionImporting = false
    @Published private(set) var sessionImportProgress: SessionImportProgress?
    @Published private(set) var lastSessionImportOutcome: SessionImportOutcome?
    @Published private(set) var lastSessionImportBackupURL: URL?
    @Published private(set) var lastProjectImportBackupURL: URL?
    @Published var isExpanded = false
    @Published var isGlancePresented = false
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
    private let tiboRadarService = CodexResetRadarService()
    private let quotaResetMonitor = QuotaResetMonitor()
    private let quotaResetNotifier = QuotaResetNotifier()
    private let codexSetupService = CodexSetupService()
    private let appUpdateService = AppUpdateService()
    private let accountIdentityService = AccountIdentityService()
    private let accountContinuityStore = AccountContinuityStore()
    private let accountStateWatcher = CodexAccountStateWatcher()
    private let sessionExportService = SessionExportService()
    private let sessionImportService = SessionImportService()
    private let projectTransferService = ProjectTransferService()
    private let importedRolloutPathRepairService = ImportedRolloutPathRepairService()
    private let sessionImportCancellationToken = SessionImportCancellationToken()
    private let sidebarCleanupService = CodexSidebarCleanupService()
    private let projectCleanupService = CodexProjectCleanupService()
    private let threadService = CodexThreadService()
    private lazy var sessionContinuityService = SessionContinuityService(threadService: threadService)
    private lazy var sessionRecoveryService = SessionRecoveryService(threadService: threadService)
    private var activeSessionImportPanel: NSOpenPanel?
    private var sessionImportInspectionID: UUID?
    private var exportDirectoryPresenter: ((URL, @escaping (URL?) -> Void) -> Void)?
    private var sessionExportDraftPresenter: (() -> Void)?
    private var shouldRestoreSessionExportWindowOnProgress = false
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
    private var codexSetupTimer: Timer?
    private var appUpdateTimer: Timer?
    private var accountTimer: Timer?
    private var accountStateRefreshWorkItem: DispatchWorkItem?
    private var codexTerminationObserver: NSObjectProtocol?
    private var isProcessingSidebarCleanups = false
    private var isProcessingProjectSessionRepair = false
    private var hasPendingAccountStateRefresh = false
    private var pendingAccountChangeDetectedAt: Date?
    private var projectDisplayOrder: [String] = []
    private var lastProjectCatalogState: CodexProjectCatalog.State?
    private var quotaResetAttempt: QuotaResetAttempt?

    var currentTask: MonitoredTask? {
        focusedProject?.task
    }

    var shouldPresentSetupOnboarding: Bool {
        codexSetupService.shouldPresentOnboarding
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
        isExpanded ? IslandPanelLayout.glanceWidth : compactPanelWidth
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

    var confirmableQuotaRecoveries: [QuotaResetConfirmationCandidate] {
        quotaResetMonitor.confirmableRecoveries
    }

    func selectProject(_ id: String) {
        guard activeProjects.contains(where: { $0.id == id }) else { return }
        selectedProjectID = id
    }

    func start() {
        do { try AppPaths.prepareDirectories() } catch { }
        observeCodexTerminationForSidebarCleanup()
        processPendingSidebarCleanups()
        processPendingProjectSessionRepairs()
        tiboRadar = tiboRadarService.cachedSnapshot
        tiboFeed = tiboRadar?.evidenceFeed
        tiboFeedFetchedAt = tiboRadarService.cachedAt
        quotaResetEvents = quotaResetMonitor.history
        quotaResetNotifier.refreshAuthorizationStatus { [weak self] status in
            self?.quotaNotificationStatus = status
        }
        notificationStatusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNotificationStatus() }
        }
        refreshCodexSetup()
        if let cachedUpdate = appUpdateService.cachedStatus(
            currentVersion: AppUpdateService.bundleVersion,
            currentBuild: AppUpdateService.bundleBuild
        ) {
            appUpdateStatus = cachedUpdate
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.checkForAppUpdate(force: false)
        }
        appUpdateTimer = Timer.scheduledTimer(
            withTimeInterval: AppUpdateService.automaticCheckInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.checkForAppUpdate(force: false) }
        }
        codexSetupTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCodexSetup() }
        }
        refreshQuota()
        consumeHookEvents()
        refreshSessionActivity()
        refreshCost()
        refreshTiboFeed()
        refreshContinuity(forceInventory: true)
        accountStateWatcher.start { [weak self] detectedAt in
            Task { @MainActor in
                self?.handleAccountStateChange(detectedAt: detectedAt)
            }
        }
        eventTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.consumeHookEvents() }
        }
        quotaTimer = Timer.scheduledTimer(
            withTimeInterval: MonitorRefreshCadence.quota,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshQuota() }
        }
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSessionActivity() }
        }
        costTimer = Timer.scheduledTimer(
            withTimeInterval: MonitorRefreshCadence.cost,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshCost() }
        }
        tiboFeedTimer = Timer.scheduledTimer(
            withTimeInterval: CodexResetRadarService.refreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshTiboFeed() }
        }
        accountTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshContinuity(forceInventory: true) }
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
            case let .success(snapshot):
                self.quotaRetryWorkItem?.cancel()
                self.quotaRetryWorkItem = nil
                self.consecutiveQuotaFailures = 0
                let now = Date()
                self.quotaState = .loaded(snapshot.buckets, now)
                self.quotaResetCredits = snapshot.resetCredits
                let evaluation = self.quotaResetMonitor.evaluate(
                    buckets: snapshot.buckets,
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

    func consumeQuotaResetCredit() {
        guard !isConsumingQuotaResetCredit else { return }
        guard quotaResetCredits?.availableCount ?? 0 > 0 else {
            quotaResetOperationMessage = "当前没有可用的额度重置卡。"
            return
        }
        isConsumingQuotaResetCredit = true
        quotaResetOperationMessage = nil
        let attempt = quotaResetAttempt ?? QuotaResetAttempt(
            idempotencyKey: UUID(),
            creditID: quotaResetCredits?
                .nextRedeemableCredit(relativeTo: Date())?
                .id
        )
        quotaResetAttempt = attempt
        quotaService.consumeResetCredit(
            creditID: attempt.creditID,
            idempotencyKey: attempt.idempotencyKey
        ) { [weak self] result in
            guard let self else { return }
            self.isConsumingQuotaResetCredit = false
            switch result {
            case let .success(outcome):
                self.quotaResetAttempt = nil
                switch outcome {
                case .reset:
                    self.quotaResetMonitor.markManualResetRequested()
                    self.quotaResetOperationMessage = "额度重置成功，正在刷新额度与剩余卡次数。"
                case .nothingToReset:
                    self.quotaResetOperationMessage = "当前没有符合条件的用量周期，额度卡未消耗。"
                case .noCredit:
                    self.quotaResetOperationMessage = "账号当前没有可用的额度重置卡。"
                case .alreadyRedeemed:
                    self.quotaResetOperationMessage = "本次重置请求已经成功处理，正在刷新额度。"
                }
                self.refreshQuota()
            case let .failure(error):
                self.quotaResetOperationMessage = "额度重置失败：\(error.localizedDescription)。再次确认会安全重试同一次请求。"
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

    func requestNotificationAuthorizationForSetup() {
        quotaResetNotifier.requestAuthorization { [weak self] status in
            self?.quotaNotificationStatus = status
        }
    }

    func checkForAppUpdate(force: Bool) {
        guard appUpdateStatus.phase != .checking else { return }
        isManualAppUpdateCheck = force
        let previous = appUpdateStatus
        appUpdateStatus = previous.checking()
        appUpdateMessage = nil
        appUpdateService.check(
            force: force,
            currentVersion: AppUpdateService.bundleVersion,
            currentBuild: AppUpdateService.bundleBuild
        ) { [weak self] result in
            guard let self else { return }
            self.isManualAppUpdateCheck = false
            switch result {
            case let .success(status):
                self.appUpdateStatus = status
                self.appUpdateMessage = status.message
                guard status.phase == .updateAvailable,
                      let release = status.release,
                      self.quotaNotificationStatus == .enabled,
                      self.appUpdateService.shouldNotify(version: release.normalizedVersion)
                else { return }
                self.quotaResetNotifier.notifyAppUpdate(
                    version: release.normalizedVersion,
                    architecture: status.asset.map { _ in AppUpdateArchitecture.current.displayName },
                    releaseURL: release.htmlURL
                )
                self.appUpdateService.markNotified(version: release.normalizedVersion)
            case let .failure(error):
                self.appUpdateStatus = AppUpdateStatus(
                    phase: .failed,
                    currentVersion: previous.currentVersion,
                    currentBuild: previous.currentBuild,
                    release: previous.release,
                    asset: previous.asset,
                    checkedAt: previous.checkedAt,
                    message: error.localizedDescription
                )
                self.appUpdateMessage = error.localizedDescription
            }
        }
    }

    func openAppUpdateDownload() {
        if let url = appUpdateStatus.asset?.downloadURL {
            if !NSWorkspace.shared.open(url) {
                appUpdateMessage = "无法打开下载地址，请改用 Release 页面。"
            }
            return
        }
        openAppReleasePage()
    }

    func openAppReleasePage() {
        guard let url = appUpdateStatus.release?.releaseURL else {
            appUpdateMessage = "当前没有可打开的 Release 页面。"
            return
        }
        if !NSWorkspace.shared.open(url) {
            appUpdateMessage = "无法打开 GitHub Release 页面。"
        }
    }

    func deferAppUpdate() {
        guard let version = appUpdateStatus.release?.normalizedVersion else { return }
        let until = appUpdateService.deferNotification(version: version)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        appUpdateMessage = "已稍后提醒；\(formatter.string(from: until)) 前不再发送此版本的系统通知。"
    }

    func refreshCodexSetup() {
        if codexSetupService.consumeSecurityReviewResult() {
            isCodexSecurityReviewLaunching = false
            codexSetupMessage = "当前 Hook Active 状态已确认。请完全退出并重新打开 Codex，然后发送一条真实消息。"
        } else if let failure = codexSetupService.consumeSecurityReviewFailure() {
            isCodexSecurityReviewLaunching = false
            codexSetupMessage = failure
        }
        codexSetupSnapshot = codexSetupService.snapshot()
        isSetupOnboardingComplete = !codexSetupService.shouldPresentOnboarding
    }

    func installCodexSetupHooks() {
        guard !isCodexSetupWorking else { return }
        isCodexSetupWorking = true
        codexSetupMessage = nil
        let service = codexSetupService
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try service.installHooks() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCodexSetupWorking = false
                switch result {
                case let .success(outcome):
                    self.codexSetupMessage = outcome.hooksBackupURL.map {
                        "Hook 已安装；原配置已备份为 \($0.lastPathComponent)。下一步请在 /hooks 确认当前状态。"
                    } ?? "Hook 已安装。下一步请在 /hooks 确认当前状态。"
                case let .failure(error):
                    self.codexSetupMessage = "Hook 安装失败：\(error.localizedDescription)"
                }
                self.refreshCodexSetup()
            }
        }
    }

    func openCodexHookSecurityReview() {
        guard !isCodexSecurityReviewLaunching else {
            codexSetupMessage = "正在打开 Hooks 管理，请稍候。"
            return
        }
        do {
            let launcher = try codexSetupService.prepareSecurityReviewLauncher()
            guard NSWorkspace.shared.open(launcher) else {
                codexSetupMessage = "无法打开 Terminal 安全审核窗口。"
                return
            }
            isCodexSecurityReviewLaunching = true
            codexSetupMessage = "正在打开 Codex Hooks 管理；信任仍需由你亲自确认。"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.isCodexSecurityReviewLaunching else { return }
                self.isCodexSecurityReviewLaunching = false
                self.codexSetupMessage = "Hooks 管理已打开；如果窗口已经关闭，可以立即重新打开。"
            }
        } catch {
            codexSetupMessage = "无法开始安全审核：\(error.localizedDescription)"
        }
        refreshCodexSetup()
    }

    func confirmCodexHookSecurityReview() {
        guard codexSetupService.markSecurityReviewConfirmed() else {
            codexSetupMessage = "当前 Hook 安装状态无法确认，请刷新后重试。"
            refreshCodexSetup()
            return
        }
        isCodexSecurityReviewLaunching = false
        codexSetupMessage = "已记录当前 Hook 在 Codex 中处于 Active。请完全退出并重新打开 Codex，再发送一条真实消息。"
        refreshCodexSetup()
    }

    func uninstallCodexSetupHooks() {
        guard !isCodexSetupWorking else { return }
        isCodexSetupWorking = true
        codexSetupMessage = nil
        let service = codexSetupService
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try service.uninstallHooks() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCodexSetupWorking = false
                switch result {
                case let .success(backup):
                    self.codexSetupMessage = backup.map {
                        "Codex Monitor Hooks 已移除；操作前配置备份为 \($0.lastPathComponent)。"
                    } ?? "当前没有需要移除的 Codex Monitor Hooks。"
                case let .failure(error):
                    self.codexSetupMessage = "Hook 卸载失败：\(error.localizedDescription)"
                }
                self.refreshCodexSetup()
            }
        }
    }

    func completeSetupOnboarding() {
        codexSetupService.markOnboardingCompleted()
        isSetupOnboardingComplete = true
    }

    func resetSetupOnboarding() {
        codexSetupService.resetOnboarding()
        isSetupOnboardingComplete = false
    }

    func revealCodexSetupBackups() {
        let url = FileManager.default.fileExists(
            atPath: codexSetupService.paths.backupDirectory.path
        ) ? codexSetupService.paths.backupDirectory : AppPaths.supportDirectory
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openNotificationSettings() {
        _ = quotaResetNotifier.openNotificationSettings()
    }

    func refreshContinuity(
        forceInventory: Bool = false,
        accountObservedAt: Date? = nil
    ) {
        guard !isContinuityLoading,
              !isContinuityRecovering,
              deletingContinuityThreadID == nil,
              deletingContinuityProjectID == nil
        else { return }
        isContinuityLoading = true
        continuityScanProgress = nil
        if forceInventory || continuitySnapshot.checkedAt == .distantPast {
            refreshContinuityAndInventory(accountObservedAt: accountObservedAt)
            return
        }
        accountIdentityService.fetch(observedAt: accountObservedAt ?? Date()) { [weak self] accountResult in
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

    private func refreshContinuityAndInventory(accountObservedAt: Date? = nil) {
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

        accountIdentityService.fetch(observedAt: accountObservedAt ?? Date()) { result in
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

    private func handleAccountStateChange(detectedAt: Date) {
        hasPendingAccountStateRefresh = true
        pendingAccountChangeDetectedAt = detectedAt
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
            let detectedAt = self.pendingAccountChangeDetectedAt
            self.pendingAccountChangeDetectedAt = nil
            self.refreshContinuity(
                forceInventory: true,
                accountObservedAt: detectedAt
            )
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
                switch recovery.completionState {
                case .complete:
                    self.continuityStatusMessage = "恢复成功：\(recovery.recoveredCount) / \(recovery.requestedCount) 条会话，新增 \(recovery.projectBindingsAdded) 条项目绑定"
                case .partial:
                    self.continuityStatusMessage = nil
                    self.continuityError = "仅部分恢复：\(recovery.recoveredCount) / \(recovery.requestedCount) 条会话；新增 \(recovery.projectBindingsAdded) 条项目绑定。操作前备份已保留。"
                case .ineffective:
                    self.continuityStatusMessage = nil
                    self.continuityError = "恢复未生效：App Server 未确认任何目标会话可见（0 / \(recovery.requestedCount)）；新增 \(recovery.projectBindingsAdded) 条项目绑定。操作前备份已保留。"
                }
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

    func deleteContinuityThread(_ thread: LocalThreadRecord) {
        guard deletingContinuityThreadID == nil,
              deletingContinuityProjectID == nil,
              !isSessionExporting,
              continuitySnapshot.userThreads.contains(where: { $0.id == thread.id })
        else { return }
        deletingContinuityThreadID = thread.id
        continuityDeletionFailure = nil
        continuityError = nil
        continuityStatusMessage = "正在通过 Codex 删除「\(thread.title)」…"
        deleteThreadAndResidual(thread) { [weak self] result in
            guard let self else { return }
            self.deletingContinuityThreadID = nil
            switch result {
            case let .failure(error):
                self.continuityStatusMessage = nil
                let message = "删除会话失败：\(error.localizedDescription)"
                self.continuityError = message
                self.continuityDeletionFailure = message
            case let .success(movedResidualToTrash):
                self.continuitySnapshot.threads.removeAll { $0.id == thread.id }
                self.continuitySnapshot.checkedAt = Date()
                self.continuityError = nil
                let baseMessage = movedResidualToTrash
                    ? "已删除「\(thread.title)」，本地残留已移入废纸篓"
                    : "已删除「\(thread.title)」"
                self.continuityStatusMessage = baseMessage
                    + self.registerSidebarCleanup(for: thread)
                self.refreshContinuity(forceInventory: true)
            }
        }
    }

    func deleteContinuityProject(
        _ project: ContinuityProjectGroup,
        deleteProjectDirectory: Bool
    ) {
        let threads = project.threads.filter { thread in
            continuitySnapshot.userThreads.contains { $0.id == thread.id }
        }
        guard !threads.isEmpty,
              deletingContinuityThreadID == nil,
              deletingContinuityProjectID == nil,
              !isSessionExporting
        else { return }

        deletingContinuityProjectID = project.id
        continuityDeletionFailure = nil
        continuityError = nil
        continuityStatusMessage = "正在删除「\(project.name)」的 0 / \(threads.count) 条会话…"
        var deletedCount = 0
        var residualTrashCount = 0
        var queuedSidebarCleanupCount = 0
        var failures: [(title: String, message: String)] = []

        func deleteNext(_ index: Int) {
            guard index < threads.count else {
                self.deletingContinuityThreadID = nil
                self.deletingContinuityProjectID = nil
                if failures.isEmpty {
                    do {
                        let finalization = try self.finalizeDeletedProject(
                            project,
                            deleteProjectDirectory: deleteProjectDirectory
                        )
                        self.continuityError = nil
                        var details = ["已删除「\(project.name)」的 \(deletedCount) 条会话"]
                        if residualTrashCount > 0 {
                            details.append("\(residualTrashCount) 个会话残留已移入废纸篓")
                        }
                        if finalization.removedRegistrationCount > 0 {
                            details.append("Codex 项目登记已移除")
                        }
                        details.append(finalization.movedProjectDirectoryToTrash
                            ? "项目目录已移入废纸篓"
                            : "磁盘项目文件已保留")
                        if queuedSidebarCleanupCount > 0 {
                            details.append("\(queuedSidebarCleanupCount) 条会话侧栏残留将在完全退出 Codex 后自动清理")
                        }
                        self.continuityStatusMessage = details.joined(separator: "；")
                    } catch {
                        let message = "会话已删除，但项目收尾失败：\(error.localizedDescription)"
                        self.continuityStatusMessage = nil
                        self.continuityError = message
                        self.continuityDeletionFailure = message
                    }
                } else {
                    self.continuityStatusMessage = nil
                    let first = failures[0]
                    let message = "项目会话仅删除 \(deletedCount) / \(threads.count) 条；「\(first.title)」失败：\(first.message)"
                    self.continuityError = message
                    self.continuityDeletionFailure = message
                }
                self.refreshContinuity(forceInventory: true)
                return
            }

            let thread = threads[index]
            self.deletingContinuityThreadID = thread.id
            self.continuityStatusMessage = "正在删除「\(project.name)」的 \(index + 1) / \(threads.count) 条会话…"
            self.deleteThreadAndResidual(thread) { result in
                switch result {
                case let .success(movedResidualToTrash):
                    deletedCount += 1
                    if movedResidualToTrash { residualTrashCount += 1 }
                    let cleanupStatus = self.registerSidebarCleanup(for: thread)
                    if cleanupStatus.contains("完全退出 Codex") {
                        queuedSidebarCleanupCount += 1
                    }
                    self.continuitySnapshot.threads.removeAll { $0.id == thread.id }
                    self.continuitySnapshot.checkedAt = Date()
                case let .failure(error):
                    failures.append((thread.title, error.localizedDescription))
                }
                deleteNext(index + 1)
            }
        }

        deleteNext(0)
    }

    private func finalizeDeletedProject(
        _ project: ContinuityProjectGroup,
        deleteProjectDirectory: Bool
    ) throws -> (removedRegistrationCount: Int, movedProjectDirectoryToTrash: Bool) {
        let fileManager = FileManager.default
        let stateURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/.codex-global-state.json")
        let originalState = fileManager.fileExists(atPath: stateURL.path)
            ? try Data(contentsOf: stateURL)
            : nil
        var removedRegistrationCount = 0
        if let originalState {
            let removal = try CodexProjectCatalog.removingLocalProject(
                atPath: project.id,
                from: originalState
            )
            removedRegistrationCount = removal.removedProjectIDs.count
            if !removal.removedProjectIDs.isEmpty {
                let backupDirectory = AppPaths.sidebarCleanupBackups
                    .appendingPathComponent("project-delete-\(UUID().uuidString)", isDirectory: true)
                try fileManager.createDirectory(
                    at: backupDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try originalState.write(
                    to: backupDirectory.appendingPathComponent(".codex-global-state.json"),
                    options: .atomic
                )
                let attributes = try? fileManager.attributesOfItem(atPath: stateURL.path)
                try removal.data.write(to: stateURL, options: .atomic)
                if let permissions = attributes?[.posixPermissions] {
                    try? fileManager.setAttributes(
                        [.posixPermissions: permissions],
                        ofItemAtPath: stateURL.path
                    )
                }
                lastSidebarCleanupBackupURL = backupDirectory
            }
        }

        guard deleteProjectDirectory else {
            _ = try projectCleanupService.registerCleanup(
                projectName: project.name,
                projectPath: project.id
            )
            return (removedRegistrationCount, false)
        }
        let projectURL = URL(fileURLWithPath: project.id, isDirectory: true).standardizedFileURL
        let protectedPaths: Set<String> = [
            "/",
            fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path,
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").standardizedFileURL.path,
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Documents").standardizedFileURL.path,
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").standardizedFileURL.path,
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library").standardizedFileURL.path,
            "/Applications",
            "/Users",
        ]
        guard !protectedPaths.contains(projectURL.path) else {
            if let originalState { try? originalState.write(to: stateURL, options: .atomic) }
            throw NSError(
                domain: "CodexProjectDeletion",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "拒绝删除过于宽泛的目录：\(projectURL.path)"]
            )
        }
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: projectURL.path, isDirectory: &isDirectory) else {
            _ = try projectCleanupService.registerCleanup(
                projectName: project.name,
                projectPath: project.id
            )
            return (removedRegistrationCount, false)
        }
        guard isDirectory.boolValue else {
            if let originalState { try? originalState.write(to: stateURL, options: .atomic) }
            throw NSError(
                domain: "CodexProjectDeletion",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "项目路径不是文件夹：\(projectURL.path)"]
            )
        }
        do {
            try fileManager.trashItem(at: projectURL, resultingItemURL: nil)
            _ = try projectCleanupService.registerCleanup(
                projectName: project.name,
                projectPath: project.id
            )
            return (removedRegistrationCount, true)
        } catch {
            if let originalState { try? originalState.write(to: stateURL, options: .atomic) }
            throw NSError(
                domain: "CodexProjectDeletion",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "项目目录移入废纸篓失败，Codex 项目登记已恢复：\(error.localizedDescription)"]
            )
        }
    }

    func dismissContinuityDeletionFailure() {
        continuityDeletionFailure = nil
    }

    private func registerSidebarCleanup(for thread: LocalThreadRecord) -> String {
        do {
            let disposition = try sidebarCleanupService.registerCleanup(
                threadID: thread.id,
                title: thread.title
            )
            pendingSidebarCleanupCount = sidebarCleanupService.pendingCount()
            switch disposition {
            case .noResidue:
                return ""
            case .queued:
                return "；完全退出 Codex 后将自动清理侧栏残留"
            case let .completed(result):
                lastSidebarCleanupBackupURL = result.backupURL
                    ?? result.catalogBackupURL
                return "；Codex 侧栏残留已清理"
            }
        } catch {
            let message = "会话已删除，但侧栏清理排队失败：\(error.localizedDescription)"
            continuityDeletionFailure = message
            continuityError = message
            return ""
        }
    }

    private func observeCodexTerminationForSidebarCleanup() {
        guard codexTerminationObserver == nil else { return }
        codexTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            let name = application?.localizedName?.lowercased() ?? ""
            let identifier = application?.bundleIdentifier?.lowercased() ?? ""
            guard name == "codex"
                || name == "chatgpt"
                || identifier == "com.openai.codex"
                || identifier == "com.openai.chat"
            else { return }
            Task { @MainActor in
                self?.processPendingSidebarCleanups()
                self?.processPendingProjectSessionRepairs()
            }
        }
    }

    private func processPendingSidebarCleanups() {
        pendingSidebarCleanupCount = sidebarCleanupService.pendingCount()
            + projectCleanupService.pendingCount()
        guard pendingSidebarCleanupCount > 0,
              !isProcessingSidebarCleanups
        else { return }
        isProcessingSidebarCleanups = true
        let service = sidebarCleanupService
        let projectService = projectCleanupService
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result {
                (
                    threads: try service.processPendingIfPossible(),
                    projects: try projectService.processPendingIfPossible()
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isProcessingSidebarCleanups = false
                self.pendingSidebarCleanupCount = service.pendingCount()
                    + projectService.pendingCount()
                switch result {
                case let .failure(error):
                    self.continuityError = "侧栏残留自动清理失败：\(error.localizedDescription)"
                case let .success(cleanups):
                    guard !cleanups.threads.isEmpty || !cleanups.projects.isEmpty else { return }
                    self.lastSidebarCleanupBackupURL = cleanups.projects.compactMap(\.backupURL).last
                        ?? cleanups.threads.compactMap {
                        $0.backupURL ?? $0.catalogBackupURL
                    }.last
                    self.continuityError = nil
                    let total = cleanups.threads.count + cleanups.projects.count
                    self.continuityStatusMessage = "已自动清理 \(total) 条 Codex 侧栏残留"
                    self.refreshContinuity(forceInventory: true)
                }
            }
        }
    }

    private func processPendingProjectSessionRepairs() {
        guard !isProcessingProjectSessionRepair,
              !isSessionImporting,
              !SessionRecoveryService.isCodexDesktopRunning(),
              let repair = (try? loadPendingProjectSessionRepairs())?.first
        else { return }
        let bundleURL = URL(fileURLWithPath: repair.bundlePath)
        let targetURL = URL(fileURLWithPath: repair.targetProjectPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleURL.path),
              FileManager.default.fileExists(atPath: targetURL.path)
        else {
            continuityError = "会话补导任务缺少迁移包或目标目录"
            return
        }
        isProcessingProjectSessionRepair = true
        isSessionImporting = true
        continuityError = nil
        continuityStatusMessage = "正在补导完整项目中的会话…"
        sessionImportCancellationToken.reset()
        sessionImportProgress = SessionImportProgress(
            stage: .validating,
            completed: 0,
            total: 0,
            currentItem: bundleURL.lastPathComponent
        )
        let service = projectTransferService
        let cancellationToken = sessionImportCancellationToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try service.importSessionsOnly(
                    bundleURL: bundleURL,
                    targetProjectURL: targetURL,
                    progress: { progress in
                        DispatchQueue.main.async { [weak self] in
                            guard self?.isProcessingProjectSessionRepair == true else { return }
                            self?.sessionImportProgress = progress
                        }
                    },
                    isCancelled: { cancellationToken.isCancelled }
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .failure(error):
                    self.isProcessingProjectSessionRepair = false
                    self.isSessionImporting = false
                    self.sessionImportProgress = nil
                    self.continuityStatusMessage = nil
                    self.continuityError = "项目会话补导失败：\(error.localizedDescription)"
                case let .success(imported):
                    do {
                        var pending = try self.loadPendingProjectSessionRepairs()
                        pending.removeAll { $0.id == repair.id }
                        try self.savePendingProjectSessionRepairs(pending)
                    } catch {
                        self.isProcessingProjectSessionRepair = false
                        self.isSessionImporting = false
                        self.sessionImportProgress = nil
                        self.continuityStatusMessage = nil
                        self.continuityError = "会话已补导，但无法清除待处理任务：\(error.localizedDescription)"
                        return
                    }
                    self.lastSessionImportBackupURL = imported.backupURL
                    self.sessionImportProgress = SessionImportProgress(
                        stage: .rebuilding,
                        completed: imported.importedCount,
                        total: imported.importedCount,
                        currentItem: targetURL.lastPathComponent
                    )
                    self.threadService.rebuildThreadIndex(
                        requiredThreadIDs: imported.importedThreadIDs
                    ) { visibility in
                        self.isProcessingProjectSessionRepair = false
                        self.isSessionImporting = false
                        self.sessionImportProgress = nil
                        self.applySessionImportVisibilityResult(visibility, imported: imported)
                        if self.continuityError == nil {
                            self.continuityStatusMessage = "已补导 \(imported.importedCount) 条项目会话到「\(targetURL.lastPathComponent)」"
                        }
                        self.refreshContinuity(forceInventory: true)
                        self.refreshCost()
                        self.processPendingProjectSessionRepairs()
                    }
                }
            }
        }
    }

    private func loadPendingProjectSessionRepairs() throws -> [PendingProjectSessionRepair] {
        let url = AppPaths.pendingProjectSessionRepairs
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            [PendingProjectSessionRepair].self,
            from: Data(contentsOf: url)
        )
    }

    private func savePendingProjectSessionRepairs(
        _ repairs: [PendingProjectSessionRepair]
    ) throws {
        let url = AppPaths.pendingProjectSessionRepairs
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(repairs).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func deleteThreadAndResidual(
        _ thread: LocalThreadRecord,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        let repair: ImportedRolloutPathRepair?
        do {
            repair = try importedRolloutPathRepairService.prepareForDeletion(thread)
        } catch {
            completion(.failure(error))
            return
        }
        guard let repair else {
            deletePreparedThreadAndResidual(thread, completion: completion)
            return
        }
        threadService.rebuildThreadIndex(requiredThreadIDs: [thread.id]) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .failure(error):
                try? self.importedRolloutPathRepairService.rollback(repair)
                completion(.failure(CodexAppServerClient.ProtocolError(
                    message: "已备份会话，但标准文件名修复后无法重建索引：\(error.localizedDescription)"
                )))
            case let .success(visibleIDs):
                guard visibleIDs.contains(thread.id) else {
                    try? self.importedRolloutPathRepairService.rollback(repair)
                    completion(.failure(CodexAppServerClient.ProtocolError(
                        message: "已备份会话，但 Codex 仍未识别修复后的 rollout 文件"
                    )))
                    return
                }
                self.deletePreparedThreadAndResidual(repair.thread, completion: completion)
            }
        }
    }

    private func deletePreparedThreadAndResidual(
        _ thread: LocalThreadRecord,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        performOfficialThreadDelete(thread, allowArchiveFallback: true, completion: completion)
    }

    private func performOfficialThreadDelete(
        _ thread: LocalThreadRecord,
        allowArchiveFallback: Bool,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        threadService.deleteThread(id: thread.id) { result in
            switch result {
            case let .failure(error):
                if allowArchiveFallback,
                   error.localizedDescription.localizedCaseInsensitiveContains("active writer") {
                    self.threadService.archiveThread(id: thread.id) { archiveResult in
                        switch archiveResult {
                        case let .failure(archiveError):
                            completion(.failure(CodexAppServerClient.ProtocolError(
                                message: "会话正被 Codex 加载，自动归档释放失败：\(archiveError.localizedDescription)"
                            )))
                        case .success:
                            self.performOfficialThreadDelete(
                                thread,
                                allowArchiveFallback: false,
                                completion: completion
                            )
                        }
                    }
                    return
                }
                completion(.failure(error))
            case .success:
                let residuals = self.remainingRolloutURLs(
                    threadID: thread.id,
                    preferredURL: thread.rolloutURL
                )
                guard !residuals.isEmpty else {
                    completion(.success(false))
                    return
                }
                do {
                    for url in residuals {
                        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    }
                    completion(.success(true))
                } catch {
                    if residuals.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                        completion(.failure(CodexAppServerClient.ProtocolError(
                            message: "Codex 已删除线程索引，但本地会话文件清理失败：\(error.localizedDescription)"
                        )))
                    } else {
                        completion(.success(false))
                    }
                }
            }
        }
    }

    private func remainingRolloutURLs(
        threadID: String,
        preferredURL: URL
    ) -> [URL] {
        var results: [URL] = []
        if FileManager.default.fileExists(atPath: preferredURL.path) {
            results.append(preferredURL)
        }
        let codexHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
        let roots = [
            codexHome.appendingPathComponent("sessions", isDirectory: true),
            codexHome.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) else { continue }
            for case let url as URL in enumerator
                where url.pathExtension == "jsonl"
                    && url.lastPathComponent.contains(threadID)
                    && !results.contains(url) {
                results.append(url)
            }
        }
        return results
    }

    func exportSession(_ thread: LocalThreadRecord) {
        presentSessionExportDraft(
            threads: [thread],
            projectName: thread.projectName,
            filenameStem: thread.title,
            allowsProjectBundle: false,
            projectEstimate: nil
        )
    }

    func exportProject(_ project: ContinuityProjectGroup) {
        guard !isSessionExporting,
              deletingContinuityThreadID == nil,
              deletingContinuityProjectID == nil else { return }
        isSessionExporting = true
        continuityError = nil
        continuityStatusMessage = "正在预检「\(project.name)」的项目迁移范围…"
        sessionExportProgress = SessionExportProgress(
            completed: 0,
            total: 0,
            currentItem: "计算默认安全文件数和大小",
            stage: .preparing,
            fraction: 0.01
        )
        let service = projectTransferService
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result {
                try service.estimate(threads: project.threads)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSessionExporting = false
                self.sessionExportProgress = nil
                switch result {
                case let .failure(error):
                    self.continuityStatusMessage = nil
                    self.continuityError = "项目导出预检失败：\(error.localizedDescription)"
                case let .success(estimate):
                    self.continuityStatusMessage = "请选择导出格式和保存位置"
                    self.presentSessionExportDraft(
                        threads: project.threads,
                        projectName: project.name,
                        filenameStem: project.name,
                        allowsProjectBundle: true,
                        projectEstimate: estimate
                    )
                }
            }
        }
    }

    private func presentSessionExportDraft(
        threads: [LocalThreadRecord],
        projectName: String,
        filenameStem: String,
        allowsProjectBundle: Bool,
        projectEstimate: ProjectTransferEstimate?
    ) {
        guard !threads.isEmpty,
              !isSessionExporting,
              deletingContinuityThreadID == nil,
              deletingContinuityProjectID == nil
        else { return }
        let downloadsDirectory = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        sessionExportDraft = SessionExportDraft(
            threads: threads,
            projectName: projectName,
            allowsProjectBundle: allowsProjectBundle,
            projectEstimate: projectEstimate,
            selectedFormat: allowsProjectBundle ? .projectBundle : .markdown,
            filenameStem: SessionExportService.safeFilenameStem(filenameStem),
            destinationDirectory: downloadsDirectory,
            projectTransferOptions: .defaults
        )
        continuityError = nil
        lastSessionExportURL = nil
        continuityStatusMessage = "请选择导出格式和保存位置"
        sessionExportDraftPresenter?()
    }

    func updateSessionExportFormat(_ format: SessionExportFormat) {
        guard var draft = sessionExportDraft,
              draft.availableFormats.contains(format)
        else { return }
        draft.selectedFormat = format
        sessionExportDraft = draft
    }

    func updateSessionExportFilenameStem(_ filenameStem: String) {
        guard var draft = sessionExportDraft else { return }
        draft.filenameStem = filenameStem
        sessionExportDraft = draft
    }

    func updateSessionExportOptions(_ options: ProjectTransferExportOptions) {
        guard var draft = sessionExportDraft else { return }
        draft.projectTransferOptions = options
        sessionExportDraft = draft
    }

    func setExportDirectoryPresenter(
        _ presenter: @escaping (URL, @escaping (URL?) -> Void) -> Void
    ) {
        exportDirectoryPresenter = presenter
    }

    func setSessionExportDraftPresenter(_ presenter: @escaping () -> Void) {
        sessionExportDraftPresenter = presenter
    }

    func chooseSessionExportDirectory() {
        guard let draft = sessionExportDraft else { return }
        exportDirectoryPresenter?(draft.destinationDirectory) { [weak self] selectedURL in
            guard let self, let selectedURL, var draft = self.sessionExportDraft else { return }
            draft.destinationDirectory = selectedURL.standardizedFileURL
            self.sessionExportDraft = draft
        }
    }

    func cancelSessionExportDraft() {
        guard !isSessionExporting else { return }
        sessionExportDraft = nil
        shouldRestoreSessionExportWindowOnProgress = false
        continuityStatusMessage = nil
    }

    func confirmSessionExport() {
        guard let draft = sessionExportDraft,
              !draft.filenameStem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isSessionExporting
        else { return }
        let outputURL = uniqueSessionExportURL(
            directory: draft.destinationDirectory,
            filename: draft.outputFilename
        )
        startSessionExport(draft, outputURL: outputURL)
    }

    private func uniqueSessionExportURL(directory: URL, filename: String) -> URL {
        let candidate = directory.appendingPathComponent(filename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let fileExtension = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var suffix = 2
        while true {
            let nextFilename = fileExtension.isEmpty
                ? "\(stem)-\(suffix)"
                : "\(stem)-\(suffix).\(fileExtension)"
            let next = directory.appendingPathComponent(nextFilename, isDirectory: false)
            if !FileManager.default.fileExists(atPath: next.path) { return next }
            suffix += 1
        }
    }

    private func startSessionExport(_ draft: SessionExportDraft, outputURL: URL) {
        let exportService = sessionExportService
        continuityError = nil
        continuityStatusMessage = nil
        isSessionExporting = true
        shouldRestoreSessionExportWindowOnProgress = true
        sessionExportProgress = SessionExportProgress(
            completed: 0,
            total: draft.threads.count,
            currentItem: draft.threads.count == 1 ? draft.threads[0].title : "准备导出",
            stage: .preparing,
            fraction: 0
        )
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result {
                try exportService.export(
                    threads: draft.threads,
                    projectName: draft.projectName,
                    format: draft.selectedFormat,
                    to: outputURL,
                    projectTransferOptions: draft.projectTransferOptions,
                    progress: { progress in
                        DispatchQueue.main.async { [weak self] in
                            guard self?.isSessionExporting == true else { return }
                            self?.sessionExportProgress = progress
                            if self?.shouldRestoreSessionExportWindowOnProgress == true {
                                self?.shouldRestoreSessionExportWindowOnProgress = false
                                self?.sessionExportDraftPresenter?()
                            }
                        }
                    }
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSessionExporting = false
                self.shouldRestoreSessionExportWindowOnProgress = false
                switch result {
                case let .success(exported):
                    let completedProgress = SessionExportProgress(
                        completed: exported.sessionCount,
                        total: exported.sessionCount,
                        currentItem: exported.outputURL.lastPathComponent,
                        stage: .completed,
                        fraction: 1
                    )
                    self.sessionExportProgress = completedProgress
                    self.continuityError = nil
                    self.continuityStatusMessage = "已导出 \(exported.sessionCount) 条会话：\(exported.outputURL.lastPathComponent)"
                    self.lastSessionExportURL = exported.outputURL
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        guard !self.isSessionExporting,
                              self.sessionExportProgress == completedProgress
                        else { return }
                        self.sessionExportProgress = nil
                    }
                case let .failure(error):
                    self.sessionExportProgress = nil
                    self.continuityStatusMessage = nil
                    self.continuityError = "导出失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func revealLastSessionExport() {
        guard let lastSessionExportURL,
              FileManager.default.fileExists(atPath: lastSessionExportURL.path)
        else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastSessionExportURL])
    }

    func chooseSessionImportBundle() {
        presentSessionImportPanel(selectingDirectory: false)
    }

    func chooseSessionImportProjectDirectory() {
        presentSessionImportPanel(selectingDirectory: true)
    }

    private var currentCodexProjectDirectoryURL: URL? {
        let paths = [selectedProject?.path, focusedProject?.path, currentTask?.projectPath]
            .compactMap { $0 }
        for path in paths {
            var isDirectory = ObjCBool(false)
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            }
        }
        return nil
    }

    private var sessionImportDirectoryURL: URL? {
        guard let preview = projectTransferPreview else {
            return currentCodexProjectDirectoryURL
        }
        return ProjectTransferDirectoryDefaults.importContainerDirectory(
            originalProjectPath: preview.manifest.project.originalPath,
            currentProjectDirectory: currentCodexProjectDirectoryURL
        )
    }

    private func beginSessionImportInspection(_ title: String) -> UUID {
        let id = UUID()
        sessionImportInspectionID = id
        isSessionImportInspecting = true
        sessionImportInspectionStartedAt = Date()
        sessionImportInspectionTitle = title
        return id
    }

    private func finishSessionImportInspection(_ id: UUID) -> Bool {
        guard sessionImportInspectionID == id else { return false }
        sessionImportInspectionID = nil
        isSessionImportInspecting = false
        sessionImportInspectionStartedAt = nil
        sessionImportInspectionTitle = nil
        return true
    }

    var projectImportReadinessIssue: String? {
        guard let preview = projectTransferPreview else {
            return "项目迁移包尚未完成校验"
        }
        if isSessionImporting {
            return "已有导入任务正在进行"
        }
        if SessionRecoveryService.isCodexDesktopRunning() {
            return "请先使用 Cmd + Q 完全退出 Codex／ChatGPT Desktop，再开始导入"
        }
        if sessionImportDuplicateStrategy == .skip,
           preview.sessionCount > 0,
           preview.duplicateCount == preview.sessionCount {
            return "包内全部会话 ID 都已存在；请选择“全部生成新 ID”，否则只会导入项目文件"
        }
        guard let target = projectImportTargetURL else {
            return "请先选择一个新目录或空目录"
        }
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  FileManager.default.isWritableFile(atPath: target.path)
            else { return "目标项目目录不可写" }
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: nil
            ) else { return "无法读取目标项目目录" }
            if contents.contains(where: { $0.lastPathComponent != ".DS_Store" }) {
                return "目标目录不是空目录；完整项目导入不会覆盖或合并现有文件"
            }
            return nil
        }
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            return "目标项目的上级目录不可写"
        }
        return nil
    }

    func selectSessionImportProject(_ option: SessionImportProjectOption) {
        sessionImportMappedProjectURL = option.url
    }

    var selectedSessionImportProjectOption: SessionImportProjectOption? {
        guard let selectedPath = sessionImportMappedProjectURL?.standardizedFileURL.path else {
            return nil
        }
        return sessionImportProjectOptions.first { $0.path == selectedPath }
            ?? SessionImportProjectOption(
                name: sessionImportMappedProjectURL?.lastPathComponent ?? "所选文件夹",
                path: selectedPath,
                isOriginal: false,
                isRegistered: false
            )
    }

    func recheckSelectedSessionImportBundle() {
        guard !isSessionImporting else { return }
        if let url = projectTransferPreview?.bundleURL {
            inspectProjectTransferBundle(at: url)
        } else if let url = sessionImportPreview?.bundleURL {
            inspectSessionImportBundle(at: url)
        }
    }

    func cancelSessionImport() {
        if isSessionImportInspecting {
            sessionImportInspectionID = nil
            isSessionImportInspecting = false
            sessionImportInspectionStartedAt = nil
            sessionImportInspectionTitle = nil
            continuityStatusMessage = nil
            return
        }
        if isSessionImporting {
            sessionImportCancellationToken.cancel()
            sessionImportProgress = SessionImportProgress(
                stage: .cancelling,
                completed: sessionImportProgress?.completed ?? 0,
                total: sessionImportProgress?.total
                    ?? projectTransferPreview.map { $0.fileCount + $0.sessionCount }
                    ?? sessionImportPreview?.sessionCount
                    ?? 0,
                currentItem: sessionImportProgress?.currentItem
            )
            continuityStatusMessage = "正在取消并回滚本次导入…"
            return
        }
        sessionImportPreview = nil
        projectTransferPreview = nil
        sessionImportMappedProjectURL = nil
        projectImportTargetURL = nil
        sessionImportProjectOptions = []
        sessionImportProgress = nil
        continuityStatusMessage = nil
    }

    func importSelectedSessionBundle() {
        guard let preview = sessionImportPreview, !isSessionImporting else { return }
        sessionImportCancellationToken.reset()
        isSessionImporting = true
        lastSessionImportOutcome = nil
        sessionImportProgress = SessionImportProgress(
            stage: .validating,
            completed: 0,
            total: preview.sessionCount,
            currentItem: nil
        )
        continuityError = nil
        continuityStatusMessage = "正在备份当前状态并导入 \(preview.sessionCount) 条会话…"
        let service = sessionImportService
        let mappedURL = sessionImportMappedProjectURL
        let strategy = sessionImportDuplicateStrategy
        let cancellationToken = sessionImportCancellationToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try service.importBundle(
                    preview: preview,
                    mappedProjectURL: mappedURL,
                    duplicateStrategy: strategy,
                    progress: { progress in
                        DispatchQueue.main.async { [weak self] in
                            guard self?.isSessionImporting == true else { return }
                            self?.sessionImportProgress = progress
                        }
                    },
                    isCancelled: { cancellationToken.isCancelled }
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .failure(error):
                    self.isSessionImporting = false
                    self.sessionImportProgress = nil
                    self.continuityStatusMessage = nil
                    self.continuityError = error.localizedDescription
                case let .success(imported):
                    self.lastSessionImportBackupURL = imported.backupURL
                    self.sessionImportProgress = SessionImportProgress(
                        stage: .rebuilding,
                        completed: imported.importedCount,
                        total: imported.importedCount,
                        currentItem: nil
                    )
                    self.threadService.rebuildThreadIndex(
                        requiredThreadIDs: imported.importedThreadIDs
                    ) { visibilityResult in
                        self.isSessionImporting = false
                        self.sessionImportPreview = nil
                        self.sessionImportMappedProjectURL = nil
                        self.sessionImportProjectOptions = []
                        self.sessionImportProgress = nil
                        self.applySessionImportVisibilityResult(visibilityResult, imported: imported)
                        self.refreshContinuity(forceInventory: true)
                        self.refreshCost()
                    }
                }
            }
        }
    }

    func importSelectedProjectBundle() {
        guard let preview = projectTransferPreview else {
            continuityStatusMessage = nil
            continuityError = "项目迁移包尚未完成校验"
            return
        }
        guard let targetURL = projectImportTargetURL else {
            continuityStatusMessage = nil
            continuityError = "请先选择完整项目的导入目录"
            return
        }
        if let issue = projectImportReadinessIssue {
            continuityStatusMessage = nil
            continuityError = issue
            return
        }
        sessionImportCancellationToken.reset()
        isSessionImporting = true
        lastSessionImportOutcome = nil
        sessionImportProgress = SessionImportProgress(
            stage: .validating,
            completed: 0,
            total: preview.fileCount + preview.sessionCount,
            currentItem: nil
        )
        continuityError = nil
        continuityStatusMessage = "正在备份并导入完整项目…"
        let service = projectTransferService
        let strategy = sessionImportDuplicateStrategy
        let cancellationToken = sessionImportCancellationToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try service.importBundle(
                    preview: preview,
                    targetProjectURL: targetURL,
                    duplicateStrategy: strategy,
                    progress: { progress in
                        DispatchQueue.main.async { [weak self] in
                            guard self?.isSessionImporting == true else { return }
                            self?.sessionImportProgress = progress
                        }
                    },
                    isCancelled: { cancellationToken.isCancelled }
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case let .failure(error):
                    self.isSessionImporting = false
                    self.sessionImportProgress = nil
                    self.continuityStatusMessage = nil
                    self.continuityError = "项目导入失败：\(error.localizedDescription)"
                case let .success(imported):
                    self.lastProjectImportBackupURL = imported.backupURL
                    self.sessionImportProgress = SessionImportProgress(
                        stage: .rebuilding,
                        completed: imported.importedFileCount,
                        total: imported.importedFileCount,
                        currentItem: imported.targetProjectURL.lastPathComponent
                    )
                    self.threadService.rebuildThreadIndex(
                        requiredThreadIDs: imported.sessionImport.importedThreadIDs
                    ) { visibilityResult in
                        self.isSessionImporting = false
                        self.projectTransferPreview = nil
                        self.projectImportTargetURL = nil
                        self.sessionImportProgress = nil
                        self.applySessionImportVisibilityResult(
                            visibilityResult,
                            imported: imported.sessionImport
                        )
                        if self.continuityError == nil {
                            self.continuityStatusMessage = "已导入项目「\(imported.targetProjectURL.lastPathComponent)」：\(imported.importedFileCount) 个文件、\(imported.importedAttachmentCount) 个附件、\(imported.sessionImport.importedCount) 条会话，App Server 全部可见"
                        }
                        self.refreshContinuity(forceInventory: true)
                        self.refreshCost()
                    }
                }
            }
        }
    }

    func rollbackLastProjectImport() {
        guard let backupURL = lastProjectImportBackupURL, !isSessionImporting else { return }
        isSessionImporting = true
        continuityError = nil
        continuityStatusMessage = "正在撤销上次完整项目导入…"
        let service = projectTransferService
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try service.rollbackImport(at: backupURL) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isSessionImporting = false
                switch result {
                case let .failure(error):
                    self.continuityStatusMessage = nil
                    self.continuityError = "撤销项目导入失败：\(error.localizedDescription)"
                case .success:
                    self.lastProjectImportBackupURL = nil
                    self.lastSessionImportOutcome = nil
                    self.sessionImportProgress = nil
                    self.continuityError = nil
                    self.continuityStatusMessage = "已撤销上次完整项目导入"
                    self.refreshContinuity(forceInventory: true)
                    self.refreshCost()
                }
            }
        }
    }

    func retryLastSessionImportVisibilityCheck() {
        guard let outcome = lastSessionImportOutcome,
              outcome.requiresRetry,
              !isSessionImporting
        else { return }
        isSessionImporting = true
        sessionImportProgress = SessionImportProgress(
            stage: .rebuilding,
            completed: outcome.result.importedCount,
            total: outcome.result.importedCount,
            currentItem: nil
        )
        threadService.rebuildThreadIndex(
            requiredThreadIDs: outcome.result.importedThreadIDs
        ) { [weak self] result in
            guard let self else { return }
            self.isSessionImporting = false
            self.sessionImportProgress = nil
            self.applySessionImportVisibilityResult(result, imported: outcome.result)
            self.refreshContinuity(forceInventory: true)
        }
    }

    private func applySessionImportVisibilityResult(
        _ visibilityResult: Result<Set<String>, Error>,
        imported: SessionImportResult
    ) {
        switch visibilityResult {
        case let .failure(error):
            lastSessionImportOutcome = SessionImportOutcome(
                result: imported,
                visibility: .rebuildFailed(error.localizedDescription)
            )
            continuityStatusMessage = "会话文件已导入 \(imported.importedCount) 条，但 Codex 索引重建失败"
            continuityError = "文件已写入且可回滚；App Server 确认失败：\(error.localizedDescription)"
        case let .success(visible):
            let visibleCount = imported.importedThreadIDs.intersection(visible).count
            lastSessionImportOutcome = SessionImportOutcome(
                result: imported,
                visibility: .visible(visibleCount, expected: imported.importedCount)
            )
            if visibleCount < imported.importedCount {
                continuityStatusMessage = "会话文件已导入 \(imported.importedCount) 条，App Server 暂可见 \(visibleCount) 条"
                continuityError = "导入部分成功：请重试 Codex 索引确认，或使用导入前备份回滚。"
            } else {
                continuityError = nil
                continuityStatusMessage = "已导入 \(imported.importedCount) 条，跳过 \(imported.skippedDuplicateCount) 条，App Server 全部可见"
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
                    self.lastSessionImportOutcome = nil
                    self.sessionImportProgress = nil
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
        panel.title = selectingDirectory ? "选择目标项目目录" : "选择 Codex 会话或项目迁移包"
        panel.prompt = selectingDirectory
            ? (projectTransferPreview == nil ? "映射到此目录" : "导入到此空目录")
            : "检查备份"
        panel.canChooseDirectories = selectingDirectory
        panel.canChooseFiles = !selectingDirectory
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = selectingDirectory && projectTransferPreview != nil
        panel.directoryURL = selectingDirectory
            ? sessionImportDirectoryURL
            : FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if !selectingDirectory {
            panel.allowedContentTypes = [
                UTType(filenameExtension: "codexmonitorbundle") ?? .zip,
                UTType(filenameExtension: "codexprojectbundle") ?? .zip,
            ]
            panel.message = "只会校验和预览。会话包恢复对话；项目包只允许导入到新目录或空目录。"
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
                let selected = selectedURL.standardizedFileURL
                if self.projectTransferPreview != nil {
                    self.projectImportTargetURL = selected
                    return
                }
                self.sessionImportMappedProjectURL = selected
                if !self.sessionImportProjectOptions.contains(where: { $0.path == selected.path }) {
                    self.sessionImportProjectOptions.append(SessionImportProjectOption(
                        name: selected.lastPathComponent,
                        path: selected.path,
                        isOriginal: false,
                        isRegistered: false
                    ))
                }
                return
            }
            if selectedURL.pathExtension.lowercased() == "codexprojectbundle" {
                self.inspectProjectTransferBundle(at: selectedURL)
            } else {
                self.inspectSessionImportBundle(at: selectedURL)
            }
        }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    private func inspectSessionImportBundle(at url: URL) {
        continuityError = nil
        continuityStatusMessage = "正在校验会话备份…"
        let inspectionID = beginSessionImportInspection("正在校验会话备份")
        let service = sessionImportService
        let existingIDs = Set(continuitySnapshot.userThreads.map(\.id))
        let previousSelection = sessionImportMappedProjectURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try service.inspect(bundleURL: url, existingThreadIDs: existingIDs) }
            DispatchQueue.main.async {
                guard let self,
                      self.finishSessionImportInspection(inspectionID)
                else { return }
                switch result {
                case let .failure(error):
                    self.sessionImportPreview = nil
                    self.continuityStatusMessage = nil
                    self.continuityError = "备份检查失败：\(error.localizedDescription)"
                case let .success(preview):
                    self.projectTransferPreview = nil
                    self.projectImportTargetURL = nil
                    self.sessionImportPreview = preview
                    self.sessionImportProjectOptions = self.makeSessionImportProjectOptions(preview: preview)
                    if let previousSelection,
                       FileManager.default.isWritableFile(atPath: previousSelection.path) {
                        self.sessionImportMappedProjectURL = previousSelection
                    } else {
                        self.sessionImportMappedProjectURL = preview.requiresPathMapping
                            ? nil
                            : URL(fileURLWithPath: preview.manifest.project.originalPath, isDirectory: true)
                                .standardizedFileURL
                    }
                    self.sessionImportDuplicateStrategy = .skip
                    self.continuityError = nil
                    self.continuityStatusMessage = nil
                }
            }
        }
    }

    private func inspectProjectTransferBundle(at url: URL) {
        continuityError = nil
        continuityStatusMessage = "正在校验完整项目迁移包…"
        let inspectionID = beginSessionImportInspection("正在校验完整项目迁移包")
        let service = projectTransferService
        let existingIDs = Set(continuitySnapshot.userThreads.map(\.id))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result {
                try service.inspect(bundleURL: url, existingThreadIDs: existingIDs)
            }
            DispatchQueue.main.async {
                guard let self,
                      self.finishSessionImportInspection(inspectionID)
                else { return }
                switch result {
                case let .failure(error):
                    self.projectTransferPreview = nil
                    self.continuityStatusMessage = nil
                    self.continuityError = "项目迁移包检查失败：\(error.localizedDescription)"
                case let .success(preview):
                    self.sessionImportPreview = nil
                    self.sessionImportMappedProjectURL = nil
                    self.sessionImportProjectOptions = []
                    self.projectTransferPreview = preview
                    self.projectImportTargetURL = nil
                    self.sessionImportDuplicateStrategy = .duplicate
                    self.continuityError = nil
                    self.continuityStatusMessage = nil
                }
            }
        }
    }

    private func makeSessionImportProjectOptions(
        preview: SessionImportPreview
    ) -> [SessionImportProjectOption] {
        let originalPath = URL(
            fileURLWithPath: preview.manifest.project.originalPath,
            isDirectory: true
        ).standardizedFileURL.path
        let registered = CodexProjectCatalog.loadState().namesByPath
        var optionsByPath: [String: SessionImportProjectOption] = [:]
        for (path, name) in registered {
            let normalized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
            optionsByPath[normalized] = SessionImportProjectOption(
                name: name,
                path: normalized,
                isOriginal: normalized == originalPath,
                isRegistered: true
            )
        }
        for project in continuitySnapshot.projectGroups where !project.id.isEmpty {
            let normalized = URL(fileURLWithPath: project.id, isDirectory: true).standardizedFileURL.path
            guard optionsByPath[normalized] == nil else { continue }
            optionsByPath[normalized] = SessionImportProjectOption(
                name: project.name,
                path: normalized,
                isOriginal: normalized == originalPath,
                isRegistered: false
            )
        }
        if optionsByPath[originalPath] == nil {
            optionsByPath[originalPath] = SessionImportProjectOption(
                name: preview.manifest.project.displayName,
                path: originalPath,
                isOriginal: true,
                isRegistered: false
            )
        }
        return Array(optionsByPath.values)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { lhs, rhs in
                if lhs.isOriginal != rhs.isOriginal { return lhs.isOriginal }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
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
        tiboRadarService.fetch { [weak self] result in
            guard let self else { return }
            self.isTiboFeedLoading = false
            switch result {
            case let .success((radar, fetchedAt)):
                self.tiboRadar = radar
                self.tiboFeed = radar.evidenceFeed
                self.tiboFeedFetchedAt = fetchedAt
                self.tiboFeedError = radar.evidenceFeed.monitor.status == "ok"
                    ? nil
                    : "数据源已标记延迟"
                self.handleQuotaResetEvents(self.quotaResetMonitor.reconcile(feed: radar.evidenceFeed))
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

    func confirmUserQuotaReset(_ candidate: QuotaResetConfirmationCandidate) {
        guard let event = quotaResetMonitor.confirmUserReset(candidateID: candidate.id) else { return }
        handleQuotaResetEvents([event])
    }

    func setQuotaResetDisplayType(
        eventID: String,
        displayType: QuotaResetDisplayType?
    ) {
        guard quotaResetMonitor.setDisplayType(
            eventID: eventID,
            displayType: displayType
        ) != nil else { return }
        quotaResetEvents = quotaResetMonitor.history
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
            codexSetupService.recordConnectedEvent()
        }
        refreshCodexSetup()
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

    deinit {
        codexSetupTimer?.invalidate()
        appUpdateTimer?.invalidate()
        if let codexTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(codexTerminationObserver)
        }
    }
}
