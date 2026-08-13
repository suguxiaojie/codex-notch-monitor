import Foundation

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
    @Published private(set) var isCostLoading = false
    @Published private(set) var tiboFeed: TiboFeed?
    @Published private(set) var tiboFeedFetchedAt: Date?
    @Published private(set) var tiboFeedError: String?
    @Published private(set) var isTiboFeedLoading = false
    @Published private(set) var quotaResetEvents: [QuotaResetEvent] = []
    @Published private(set) var quotaNotificationStatus: QuotaNotificationStatus = .unknown
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
    private var eventTimer: Timer?
    private var quotaTimer: Timer?
    private var quotaRetryWorkItem: DispatchWorkItem?
    private var consecutiveQuotaFailures = 0
    private var isRefreshingQuota = false
    private var sessionTimer: Timer?
    private var isReadingSession = false
    private var costTimer: Timer?
    private var tiboFeedTimer: Timer?
    private var notificationStatusTimer: Timer?
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
        let overrides = sessionProjectPathOverrides
        costService.fetch(sessionPathOverrides: overrides) { [weak self] snapshot in
            self?.costSnapshot = snapshot
            self?.isCostLoading = false
        }
    }

    func refreshAll() {
        refreshQuota()
        refreshTiboFeed()
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
