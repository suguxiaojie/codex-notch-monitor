import AppKit
import Combine
import SwiftUI
import os

@main
struct CodexNotchMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            MonitorSettingsView(store: appDelegate.store)
                .frame(
                    minWidth: 620,
                    idealWidth: 1000,
                    maxWidth: .infinity,
                    minHeight: 620,
                    idealHeight: 720,
                    maxHeight: .infinity
                )
                .background(MonitorDesktopTheme.windowBackground)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1000, height: 720)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("灵动岛设置") {
                    appDelegate.openActivitySettings()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandMenu("监控") {
                Button("显示或收起概览") {
                    appDelegate.togglePanel()
                }
                .keyboardShortcut(" ", modifiers: [.command, .shift])

                Button("打开监控中心") {
                    appDelegate.openMonitorCenter()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("安装与权限") {
                    appDelegate.openSetupPermissions()
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = MonitorStore()
    private var activityIslandController: ActivityIslandWindowController?
    private var activitySettingsWindowController: ActivitySettingsWindowController?
    private var monitorCenterController: MonitorCenterWindowController?
    private var glanceWindowController: GlanceWindowController?
    private var statusItem: NSStatusItem?
    private var statusCancellables: Set<AnyCancellable> = []
    private var statusCountdownTimer: Timer?
    private var statusRotationTimer: Timer?
    private var statusRotation = StatusItemRotation()
    private var animateStatusRotation = false
    private var statusGeometryGeneration = 0
    private var lastStatusGeometry = ""
    private var statusCapacity = StatusItemCapacity()
    private let statusLogger = Logger(subsystem: "com.coverai.codex-notch-monitor.status", category: "layout")
    private var lastMenuBarProject: ActiveProjectState?
    private var tokenReceipt = MenuBarTokenReceipt()
    private var receiptWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AstaSansFontRegistrar.registerBundledFonts()
        let settingsController = ActivitySettingsWindowController(store: store)
        activitySettingsWindowController = settingsController
        let centerController = MonitorCenterWindowController(
            store: store,
            onOpenActivitySettings: { [weak settingsController] in
                settingsController?.show()
            }
        )
        monitorCenterController = centerController
        let glanceController = GlanceWindowController(
            store: store,
            anchorRect: { [weak self] in self?.statusItemScreenFrame },
            onOpenCenter: { [weak centerController] section in
                centerController?.show(section: section)
            }
        )
        glanceWindowController = glanceController
        activityIslandController = ActivityIslandWindowController(store: store)
        installStatusItem()
        store.start()
        if store.shouldPresentSetupOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak centerController] in
                centerController?.show(section: .setup)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        store.refreshNotificationStatus()
        store.refreshContinuity()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openActivitySettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusCountdownTimer?.invalidate()
        statusRotationTimer?.invalidate()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // A new stable identity re-registers the item without deleting the old
        // placement record, which can remain offscreen after a Tahoe update.
        item.autosaveName = "CodexNotchMonitor.StatusItem.v2"
        if let button = item.button {
            let image = NSImage(
                systemSymbolName: "circle.dotted",
                accessibilityDescription: "Codex Monitor"
            )
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.font = .systemFont(
                ofSize: NSFont.systemFontSize,
                weight: .semibold
            )
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp])
        }
        statusItem = item
        updateStatusItem()

        store.$turnTokenUsages
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &statusCancellables)

        store.$quotaState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &statusCancellables)

        store.$activeProjects
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &statusCancellables)

        NotificationCenter.default
            .publisher(for: .activityIslandPreferencesDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &statusCancellables)

        Publishers.Merge3(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didLaunchApplicationNotification
            ),
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.didTerminateApplicationNotification
            ),
            NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification
            )
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.updateStatusItem() }
        .store(in: &statusCancellables)

        statusCountdownTimer = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
    }

    private func updateStatusItem(now: Date = Date()) {
        guard let item = statusItem, let button = item.button else { return }
        let preferences = ActivityIslandPreferences.load()
        let project = preferences.routesTaskStateToMenuBar
            ? store.activeProjects.min(by: { lhs, rhs in
                if lhs.task.phase.attentionPriority != rhs.task.phase.attentionPriority {
                    return lhs.task.phase.attentionPriority < rhs.task.phase.attentionPriority
                }
                if lhs.task.updatedAt != rhs.task.updatedAt { return lhs.task.updatedAt > rhs.task.updatedAt }
                return lhs.id < rhs.id
            }) : nil
        var displayed = project
        var completed = false
        if !preferences.routesTaskStateToMenuBar {
            lastMenuBarProject = nil
            receiptWork?.cancel()
            receiptWork = nil
        } else if let project {
            lastMenuBarProject = project
        } else if let previous = lastMenuBarProject,
                  let task = previous.sessions.first?.task,
                  let usage = store.turnTokenUsages[task.id],
                  usage.turnID == task.turnID,
                  tokenReceipt.resolve(usage: usage, now: now) {
            displayed = previous
            completed = true
            if receiptWork == nil, let expiry = tokenReceipt.expiresAt {
                let work = DispatchWorkItem { [weak self] in
                    self?.receiptWork = nil
                    self?.updateStatusItem()
                }
                receiptWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, expiry.timeIntervalSince(now)), execute: work)
            }
        }

        let bucket = store.quotaState.primaryBucket
        let regions = NSScreen.screens.map { screen in
            Double(screen.auxiliaryTopRightArea?.width ?? screen.frame.width / 2)
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let measure: (String) -> Double = { text in
            Double((text as NSString).size(withAttributes: [.font: font]).width)
        }
        var budget = StatusItemLayout.budget(menuRegionWidth: regions.min())
        if preferences.menuBarDensity == .detailed, let window = button.window,
           let screen = window.screen {
            let region = screen.auxiliaryTopRightArea ?? NSRect(
                x: screen.frame.midX, y: screen.visibleFrame.maxY,
                width: screen.frame.width / 2, height: screen.frame.maxY - screen.visibleFrame.maxY)
            // Only trust a real on-screen anchor, never Tahoe's (0, -6) placeholder.
            if region.contains(NSPoint(x: window.frame.maxX - 1, y: window.frame.midY)) {
                budget = max(32, min(
                    StatusItemLayout.budget(menuRegionWidth: regions.min(), detailed: true),
                    Double(window.frame.maxX - region.minX - 24)))
            }
        }
        let capacityContext = preferences.menuBarDensity.rawValue + NSScreen.screens.map { NSStringFromRect($0.frame) }.joined()
        budget = statusCapacity.constrain(budget, context: capacityContext)
        let remaining = bucket?.limitingWindow?.remainingPercent
        let quotaText = MenuBarStatusFormatter.title(for: bucket?.limitingWindow, relativeTo: now)
        var tooltip = MenuBarStatusFormatter.details(for: bucket, relativeTo: now)
        var titles = [quotaText, remaining.map { "余 \($0)%" } ?? "额度同步中"]
        var compactCandidates: [String]?
        var rotationPages = [remaining.map { "余 \($0)%" } ?? "额度同步中"]
        let resetText = MenuBarStatusFormatter.resetText(bucket?.limitingWindow?.resetsAt, relativeTo: now)
        if !resetText.isEmpty { rotationPages.append("\(resetText)后重置") }
        var rotationIdentity = "quota"
        let lowQuota = remaining.map { $0 <= 10 } ?? false
        var fixedMessage = lowQuota
        var image = quotaStatusImage()

        if let displayed {
            let task = displayed.sessions.first?.task
            let usage = task.flatMap { task in
                store.turnTokenUsages[task.id].flatMap { $0.turnID == task.turnID ? $0 : nil }
            }
            let status = completed ? "已完成" : displayed.task.phase.menuBarTitle
            let count = store.activeProjects.count
            let others = count > 1 ? " ＋\(count - 1)" : ""
            rotationIdentity = (task?.id ?? displayed.id) + "/" + (task?.turnID ?? "")
            fixedMessage = completed || displayed.task.phase == .waitingApproval || displayed.task.phase == .failed || lowQuota
            rotationPages = [StatusItemLayout.projectTitle(
                status: status, project: displayed.name, suffix: others,
                budget: budget, measure: measure)].compactMap { $0 }
            if let total = usage?.total {
                rotationPages.append(status + " · 本轮 " + MenuBarTokenFormatter.shortCount(total))
            }
            if let remaining {
                let windowLabel = preferences.menuBarDensity == .detailed
                    ? (bucket?.limitingWindow?.windowLabel ?? "额度") : ""
                rotationPages.append(status + " · " + windowLabel + "余 \(remaining)%")
            }
            titles = StatusItemLayout.taskTitles(
                status: status, project: displayed.name, projectCount: count,
                token: usage?.total.map { "本轮 " + MenuBarTokenFormatter.shortCount($0) },
                quota: remaining.map { "余 \($0)%" })
            compactCandidates = Array(titles.dropFirst())
            let tokenSuffix = usage?.total.map { " · 本轮 " + MenuBarTokenFormatter.shortCount($0) } ?? ""
            if let fitted = StatusItemLayout.projectTitle(status: status, project: displayed.name,
                suffix: others + tokenSuffix, budget: budget, measure: measure) {
                titles.insert(fitted, at: 1)
            }
            if let fitted = StatusItemLayout.projectTitle(status: status, project: displayed.name,
                suffix: others, budget: budget, measure: measure) {
                titles.insert(fitted, at: titles.count - 1)
                if count > 1 { compactCandidates?.insert(fitted, at: 1) }
            }
            if let remaining, lowQuota, !completed, displayed.task.phase != .waitingApproval, displayed.task.phase != .failed {
                titles = [status + others + " · 额度仅余 \(remaining)%", status + " · 余 \(remaining)%"]
                compactCandidates = nil
            }
            image = NSImage(systemSymbolName: completed ? "checkmark.circle" : statusSymbol(for: displayed),
                            accessibilityDescription: status)
            image?.isTemplate = true
            tooltip = "\(status) · \(displayed.name)\n"
                + (usage?.label ?? "本轮 Token 等待统计") + "\n"
                + displayed.detailedActionSummary + "\n" + tooltip
            if count > 1 || displayed.sessions.count > 1 {
                let details = store.activeProjects.map { project in
                    let sessions = project.sessions.enumerated().map { index, session in
                        let usage = self.store.turnTokenUsages[session.task.id]
                        let label = usage?.turnID == session.task.turnID
                            ? (usage?.label ?? "本轮 Token 等待统计") : "本轮 Token 等待统计"
                        return "  会话 \(index + 1) · \(session.task.phase.title) · \(label)"
                    }.joined(separator: "\n")
                    return "\(project.name)（\(project.sessions.count) 会话）\n\(sessions)"
                }.joined(separator: "\n\n")
                tooltip += "\n\n运行中的项目（各会话独立统计）\n" + details
            }
        }

        let candidates: [String]
        switch preferences.menuBarDensity {
        case .iconOnly:
            candidates = []
        case .compact:
            candidates = compactCandidates ?? Array(titles.dropFirst())
        case .automatic where isQuotaViewRunning:
            candidates = []
        case .automatic, .detailed:
            candidates = titles
        }
        var layout = StatusItemLayout.resolve(candidates: candidates, budget: budget, measure: measure)
        let fullFits = titles.first.map { measure($0) + 36 <= budget } ?? true
        let canRotate = preferences.routesTaskStateToMenuBar && preferences.menuBarOverflow == .rotate
            && !candidates.isEmpty && !fullFits && !fixedMessage && item.isVisible
        let pages = canRotate ? StatusItemRotation.fittingPages(rotationPages, budget: budget, measure: measure) : []
        if statusRotation.configure(identity: rotationIdentity, pages: pages) {
            statusRotationTimer?.invalidate()
            statusRotationTimer = nil
        }
        if let title = statusRotation.title {
            // Reserve the same bounded slot across every page and token update.
            layout = StatusItemLayout(title: title, width: budget)
            if statusRotationTimer == nil {
                let timer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    let hovered = self.statusItemScreenFrame?.contains(NSEvent.mouseLocation) == true
                    self.animateStatusRotation = self.statusRotation.advance(hovered: hovered)
                    self.updateStatusItem()
                }
                statusRotationTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        } else {
            statusRotationTimer?.invalidate()
            statusRotationTimer = nil
        }
        let shouldFade = animateStatusRotation && !preferences.reduceMotion
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !pages.isEmpty
        animateStatusRotation = false
        button.imageScaling = .scaleProportionallyDown
        button.font = font
        button.image = image ?? NSImage(systemSymbolName: "circle.dotted", accessibilityDescription: "Codex Monitor")
        // Titles are already measured; never blank the live item between updates.
        let targetLength = layout.title.isEmpty ? NSStatusItem.squareLength : layout.width
        if item.length != targetLength { item.length = targetLength }
        button.imagePosition = layout.title.isEmpty ? .imageOnly : .imageLeading
        if button.title != layout.title { button.title = layout.title }
        if shouldFade {
            button.wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            button.layer?.add(fade, forKey: "statusRotation")
        } else {
            button.layer?.removeAnimation(forKey: "statusRotation")
        }
        button.toolTip = tooltip
        button.setAccessibilityLabel("Codex Monitor\n" + tooltip)
        statusGeometryGeneration += 1
        let generation = statusGeometryGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.statusGeometryGeneration == generation,
                  let item = self.statusItem, let button = item.button else { return }
            let window = button.window
            let geometry = "visible=\(item.isVisible) length=\(item.length) chars=\(button.title.count) "
                + "windowVisible=\(window?.isVisible ?? false) occluded=\(!(window?.occlusionState.contains(.visible) ?? false)) "
                + "frame=\(String(describing: window?.frame)) button=\(button.frame) hidden=\(button.isHidden)"
            if geometry != self.lastStatusGeometry {
                self.lastStatusGeometry = geometry
                self.statusLogger.notice("\(geometry, privacy: .public)")
            }
            if let window {
                let onMenuBar = NSScreen.screens.contains { screen in
                    window.frame.midY >= screen.visibleFrame.maxY
                        && window.frame.midY <= screen.frame.maxY
                        && window.frame.maxX > screen.frame.minX
                        && window.frame.minX < screen.frame.maxX
                }
                if self.statusCapacity.observe(width: item.length, onMenuBar: onMenuBar,
                    occluded: !window.occlusionState.contains(.visible)) {
                    self.updateStatusItem()
                }
            }
        }
    }

    private func quotaStatusImage() -> NSImage? {
        switch MenuBarQuotaIconModel.state(for: store.quotaState) {
        case let .ready(remainingPercent):
            return MenuBarQuotaRingRenderer.image(remainingPercent: remainingPercent)
        case .loading:
            let image = NSImage(
                systemSymbolName: "circle.dotted",
                accessibilityDescription: "额度同步中"
            )
            image?.isTemplate = true
            return image
        case .failed:
            let image = NSImage(
                systemSymbolName: "exclamationmark.circle",
                accessibilityDescription: "额度读取失败"
            )
            image?.isTemplate = true
            return image
        }
    }

    private var isQuotaViewRunning: Bool {
        let identifiers = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        return StatusItemCoexistencePolicy.usesIconOnlyMode(
            runningBundleIdentifiers: identifiers
        )
    }


    private func statusSymbol(for project: ActiveProjectState) -> String {
        switch project.task.phase {
        case .waitingApproval: return "hand.raised.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .completed: return "checkmark.circle.fill"
        case .usingTool: return "terminal.fill"
        case .ended: return "moon.fill"
        case .starting, .working: return "waveform.path.ecg"
        }
    }

    private var statusItemScreenFrame: NSRect? {
        guard let button = statusItem?.button,
              let window = button.window
        else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc func togglePanel() {
        glanceWindowController?.toggle()
    }

    @objc private func refreshQuota() {
        store.refreshQuota()
    }

    @objc func openMonitorCenter() {
        monitorCenterController?.show(section: .usage)
    }

    @objc func openActivitySettings() {
        activitySettingsWindowController?.show()
    }

    @objc func openSetupPermissions() {
        monitorCenterController?.show(section: .setup)
    }

    @objc private func openCoverAI() {
        CoverAILinks.open(.appMenu)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
