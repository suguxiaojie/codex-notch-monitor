import AppKit
import Combine
import SwiftUI

@main
struct CodexNotchMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            MonitorSettingsView(store: appDelegate.store)
                .frame(width: 640, height: 620)
                .padding(22)
                .background(MonitorTheme.windowBackground)
                .preferredColorScheme(.dark)
        }
        .commands {
            CommandMenu("监控") {
                Button("显示或收起概览") {
                    appDelegate.togglePanel()
                }
                .keyboardShortcut(" ", modifiers: [.command, .shift])

                Button("打开监控中心") {
                    appDelegate.openMonitorCenter()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("灵动岛设置") {
                    appDelegate.openActivitySettings()
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])

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
    private var monitorCenterController: MonitorCenterWindowController?
    private var glanceWindowController: GlanceWindowController?
    private var statusItem: NSStatusItem?
    private var statusCancellables: Set<AnyCancellable> = []
    private var statusCountdownTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AstaSansFontRegistrar.registerBundledFonts()
        let centerController = MonitorCenterWindowController(store: store)
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

    func applicationWillTerminate(_ notification: Notification) {
        statusCountdownTimer?.invalidate()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "CodexNotchMonitor.StatusItem"
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
        guard let button = statusItem?.button else { return }
        let preferences = ActivityIslandPreferences.load()
        let menuBarProject = preferences.routesTaskStateToMenuBar
            ? store.activeProjects.min(by: { lhs, rhs in
                if lhs.task.phase.attentionPriority != rhs.task.phase.attentionPriority {
                    return lhs.task.phase.attentionPriority < rhs.task.phase.attentionPriority
                }
                return lhs.task.updatedAt > rhs.task.updatedAt
            })
            : nil
        if let menuBarProject {
            let image = NSImage(
                systemSymbolName: statusSymbol(for: menuBarProject),
                accessibilityDescription: "Codex \(menuBarProject.task.phase.title)"
            )
            image?.isTemplate = true
            button.image = image
        } else {
            button.image = quotaStatusImage()
        }
        button.imageScaling = .scaleProportionallyDown
        let density = StatusItemCoexistencePolicy.effectiveDensity(
            preference: preferences.menuBarDensity,
            quotaViewIsRunning: isQuotaViewRunning,
            availableWidth: availableStatusItemWidth(for: button)
        )
        switch density {
        case .iconOnly:
            applyIconOnlyStatus(
                to: button,
                project: menuBarProject,
                now: now,
                quotaViewIsRunning: isQuotaViewRunning
            )
            return
        case .compact:
            applyCompactStatus(to: button, project: menuBarProject, now: now)
            return
        case .automatic, .detailed:
            break
        }
        statusItem?.length = NSStatusItem.variableLength
        button.imagePosition = .imageLeading
        guard let window = store.quotaState.primaryBucket?.headlineWindow else {
            if let menuBarProject {
                button.title = " " + MenuBarActivityFormatter.title(
                    phase: menuBarProject.task.phase,
                    projectName: menuBarProject.name,
                    actionSummary: menuBarProject.detailedActionSummary,
                    projectCount: store.activeProjects.count,
                    quotaTitle: "--"
                )
                button.toolTip = MenuBarActivityFormatter.tooltip(
                    phase: menuBarProject.task.phase,
                    projectName: menuBarProject.name,
                    actionSummary: menuBarProject.detailedActionSummary,
                    projectCount: store.activeProjects.count,
                    quotaTitle: "同步中"
                )
                button.setAccessibilityLabel(
                    button.toolTip ?? "Codex \(menuBarProject.task.phase.title)，额度同步中"
                )
            } else {
                button.title = " --"
                button.toolTip = "Codex Monitor · 额度同步中"
                button.setAccessibilityLabel("Codex Monitor，额度同步中")
            }
            return
        }

        let reset = MenuBarStatusFormatter.resetText(
            window.resetsAt,
            relativeTo: now
        )
        let quotaTitle = MenuBarStatusFormatter.title(
            for: window,
            relativeTo: now
        )
        if let menuBarProject {
            button.title = " " + MenuBarActivityFormatter.title(
                phase: menuBarProject.task.phase,
                projectName: menuBarProject.name,
                actionSummary: menuBarProject.detailedActionSummary,
                projectCount: store.activeProjects.count,
                quotaTitle: quotaTitle
            )
            button.toolTip = MenuBarActivityFormatter.tooltip(
                phase: menuBarProject.task.phase,
                projectName: menuBarProject.name,
                actionSummary: menuBarProject.detailedActionSummary,
                projectCount: store.activeProjects.count,
                quotaTitle: quotaTitle
            )
            button.setAccessibilityLabel(
                button.toolTip ?? "Codex \(menuBarProject.task.phase.title)，剩余 \(window.remainingPercent)%"
            )
        } else {
            button.title = " " + quotaTitle
            button.toolTip = "Codex 剩余 \(window.remainingPercent)%\(reset.isEmpty ? "" : "，\(reset)后重置")"
            button.setAccessibilityLabel(
                "Codex 可用，剩余 \(window.remainingPercent)%\(reset.isEmpty ? "" : "，\(reset)后重置")"
            )
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

    private func availableStatusItemWidth(
        for button: NSStatusBarButton
    ) -> CGFloat? {
        guard let window = button.window,
              let screen = window.screen ?? NSScreen.main
        else { return nil }
        let leftBoundary = screen.auxiliaryTopRightArea?.minX
            ?? screen.frame.midX
        return max(0, window.frame.maxX - leftBoundary - 8)
    }

    private func applyIconOnlyStatus(
        to button: NSStatusBarButton,
        project: ActiveProjectState?,
        now: Date,
        quotaViewIsRunning: Bool
    ) {
        statusItem?.length = NSStatusItem.squareLength
        button.imagePosition = .imageOnly
        button.title = ""
        let quotaTitle = MenuBarStatusFormatter.title(
            for: store.quotaState.primaryBucket?.headlineWindow,
            relativeTo: now
        )
        if let project {
            button.toolTip = MenuBarActivityFormatter.tooltip(
                phase: project.task.phase,
                projectName: project.name,
                actionSummary: project.detailedActionSummary,
                projectCount: store.activeProjects.count,
                quotaTitle: quotaTitle
            ) + (quotaViewIsRunning
                ? "\nQuotaView 共存模式：菜单栏仅显示状态图标"
                : "\n菜单栏空间不足：已自动切换为仅图标")
            button.setAccessibilityLabel(
                "Codex \(project.task.phase.title)，仅图标菜单栏模式"
            )
        } else {
            let reason = quotaViewIsRunning ? "QuotaView 共存模式" : "菜单栏空间不足"
            button.toolTip = "Codex Monitor · \(reason)\n额度 \(quotaTitle)"
            button.setAccessibilityLabel("Codex Monitor，仅图标菜单栏模式")
        }
    }

    private func applyCompactStatus(
        to button: NSStatusBarButton,
        project: ActiveProjectState?,
        now: Date
    ) {
        statusItem?.length = NSStatusItem.variableLength
        button.imagePosition = .imageLeading
        let window = store.quotaState.primaryBucket?.headlineWindow
        let quota = window.map { "\($0.remainingPercent)%" } ?? "--"
        if let project {
            button.title = " \(project.task.phase.menuBarTitle) · \(quota)"
            let fullQuota = MenuBarStatusFormatter.title(for: window, relativeTo: now)
            button.toolTip = MenuBarActivityFormatter.tooltip(
                phase: project.task.phase,
                projectName: project.name,
                actionSummary: project.detailedActionSummary,
                projectCount: store.activeProjects.count,
                quotaTitle: fullQuota
            ) + "\n菜单栏精简模式"
            button.setAccessibilityLabel(
                "Codex \(project.task.phase.title)，剩余 \(quota)"
            )
        } else {
            button.title = " \(quota)"
            let fullQuota = MenuBarStatusFormatter.title(for: window, relativeTo: now)
            button.toolTip = "Codex Monitor · 菜单栏精简模式\n额度 \(fullQuota)"
            button.setAccessibilityLabel("Codex 剩余 \(quota)")
        }
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
        monitorCenterController?.show(section: .settings)
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
