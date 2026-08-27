import AppKit
import Combine
import SwiftUI

@MainActor
final class ActivityIslandWindowController: NSObject {
    private let store: MonitorStore
    private let model = ActivityIslandViewModel()
    private var panel: NSPanel!
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []
    private var lifecycle = ActivityIslandLifecycle()
    private var lastLiveSnapshot: ActivityIslandSnapshot?
    private var lastFingerprint: String?
    private var transitionGeneration = 0
    private var scheduledWorkItems: [DispatchWorkItem] = []
    private var preferences = ActivityIslandPreferences.load()

    init(store: MonitorStore) {
        self.store = store
        super.init()
        createPanel()
        observeStore()
        observeScreens()
        observePreferences()
    }

    deinit {
        scheduledWorkItems.forEach { $0.cancel() }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func createPanel() {
        panel = NSPanel(
            contentRect: NSRect(
                origin: .zero,
                size: ActivityIslandLayout.panelSize(
                    presentation: .expanded,
                    scale: CGFloat(preferences.surfaceScale)
                )
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let rootView = ActivityIslandView(model: model)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
    }

    private func observeStore() {
        store.$activeProjects
            .removeDuplicates()
            .sink { [weak self] projects in
                self?.consume(projects)
            }
            .store(in: &cancellables)

        store.$isGlancePresented
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.reposition(animated: true)
            }
            .store(in: &cancellables)
    }

    private func observeScreens() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition(animated: false) }
        })
    }

    private func observePreferences() {
        Publishers.Merge(
            NotificationCenter.default
                .publisher(for: UserDefaults.didChangeNotification),
            NotificationCenter.default
                .publisher(for: .activityIslandPreferencesDidChange)
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reloadPreferences()
            }
            .store(in: &cancellables)
        model.reduceMotionOverride = preferences.reduceMotion
        model.visualStyle = preferences.visualStyle
        model.surfaceOpacity = preferences.surfaceOpacity
        model.surfaceScale = CGFloat(preferences.surfaceScale)
    }

    private func reloadPreferences() {
        let updated = ActivityIslandPreferences.load()
        guard updated != preferences else { return }
        preferences = updated
        model.reduceMotionOverride = updated.reduceMotion
        model.visualStyle = updated.visualStyle
        model.surfaceOpacity = updated.surfaceOpacity
        model.surfaceScale = CGFloat(updated.surfaceScale)
        cancelScheduledTransitions()
        guard shouldShowFloatingIsland else {
            panel.orderOut(nil)
            return
        }
        if let snapshot = lastLiveSnapshot {
            show(
                snapshot,
                event: .activityChanged(
                    requiresAttention: snapshot.phase == .waitingApproval || snapshot.phase == .failed
                ),
                expandedHold: snapshot.phase == .waitingApproval || snapshot.phase == .failed
                    ? nil : updated.expandedHold,
                compactHide: snapshot.phase == .waitingApproval || snapshot.phase == .failed
                    ? nil : updated.compactHide
            )
        }
    }

    private func consume(_ projects: [ActiveProjectState]) {
        guard shouldShowFloatingIsland else {
            if let project = focusedProject(in: projects) {
                let snapshot = makeSnapshot(project: project, projectCount: projects.count)
                lastLiveSnapshot = snapshot
                lastFingerprint = snapshot.fingerprint
            } else {
                lastLiveSnapshot = nil
                lastFingerprint = nil
            }
            panel.orderOut(nil)
            return
        }
        guard let project = focusedProject(in: projects) else {
            guard let previous = lastLiveSnapshot,
                  model.presentation != .hidden || lastFingerprint != nil
            else { return }
            guard preferences.showCompletion else {
                lastLiveSnapshot = nil
                lastFingerprint = nil
                cancelScheduledTransitions()
                apply(.hidden, animated: false)
                return
            }
            let completion = previous.completed()
            lastLiveSnapshot = nil
            lastFingerprint = nil
            show(
                completion,
                event: .activityEnded,
                expandedHold: ActivityIslandTiming.completionExpandedHold,
                compactHide: min(preferences.compactHide, ActivityIslandTiming.completionCompactHide)
            )
            return
        }

        let snapshot = makeSnapshot(project: project, projectCount: projects.count)
        guard snapshot.fingerprint != lastFingerprint else { return }
        lastLiveSnapshot = snapshot
        lastFingerprint = snapshot.fingerprint
        let requiresAttention = snapshot.phase == .waitingApproval || snapshot.phase == .failed
        show(
            snapshot,
            event: .activityChanged(requiresAttention: requiresAttention),
            expandedHold: requiresAttention ? nil : preferences.expandedHold,
            compactHide: requiresAttention ? nil : preferences.compactHide
        )
    }

    private func show(
        _ snapshot: ActivityIslandSnapshot,
        event: ActivityIslandLifecycleEvent,
        expandedHold: TimeInterval?,
        compactHide: TimeInterval?
    ) {
        cancelScheduledTransitions()
        model.snapshot = snapshot
        apply(lifecycle.handle(event), animated: true)

        if let expandedHold {
            schedule(after: expandedHold) { [weak self] in
                guard let self else { return }
                self.apply(self.lifecycle.handle(.expandedHoldElapsed), animated: true)
            }
        }
        if let compactHide, let expandedHold {
            schedule(after: expandedHold + compactHide) { [weak self] in
                guard let self else { return }
                self.apply(self.lifecycle.handle(.compactHideElapsed), animated: true)
            }
        }
    }

    private func apply(_ presentation: ActivityIslandPresentation, animated: Bool) {
        model.presentation = presentation
        switch presentation {
        case .hidden:
            panel.orderOut(nil)
        case .expanded, .compact:
            reposition(animated: animated)
            panel.orderFrontRegardless()
        }
    }

    private func reposition(animated: Bool) {
        guard model.presentation != .hidden,
              let screen = targetScreen()
        else { return }
        let size = ActivityIslandLayout.panelSize(
            presentation: model.presentation,
            scale: CGFloat(preferences.surfaceScale)
        )
        let notchLift = ActivityIslandPlacementPolicy.notchLift(
            safeAreaTop: screen.safeAreaInsets.top
        )
        let target = NSRect(
            x: horizontalOrigin(for: size.width, on: screen),
            y: screen.visibleFrame.maxY
                - ActivityIslandLayout.screenGap
                - size.height
                + notchLift,
            width: size.width,
            height: size.height
        )

        guard animated, panel.isVisible else {
            panel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ActivityIslandMotionPolicy.isReduced(
                systemPreference: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                appPreference: preferences.reduceMotion
            )
                ? 0
                : (model.presentation == .compact ? 0.28 : 0.30)
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    private func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        let generation = transitionGeneration
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.transitionGeneration == generation else { return }
                action()
            }
        }
        scheduledWorkItems.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelScheduledTransitions() {
        transitionGeneration += 1
        scheduledWorkItems.forEach { $0.cancel() }
        scheduledWorkItems.removeAll()
    }

    private func focusedProject(in projects: [ActiveProjectState]) -> ActiveProjectState? {
        projects.min { lhs, rhs in
            if lhs.task.phase.attentionPriority != rhs.task.phase.attentionPriority {
                return lhs.task.phase.attentionPriority < rhs.task.phase.attentionPriority
            }
            return lhs.task.updatedAt > rhs.task.updatedAt
        }
    }

    private func makeSnapshot(
        project: ActiveProjectState,
        projectCount: Int
    ) -> ActivityIslandSnapshot {
        ActivityIslandSnapshot(
            projectID: project.id,
            projectName: project.name,
            phase: project.task.phase,
            actionText: project.detailedActionSummary,
            sessionCount: project.sessionCount,
            projectCount: projectCount,
            updatedAt: max(project.task.updatedAt, project.latestDisplayActivity?.updatedAt ?? .distantPast)
        )
    }

    private func targetScreen() -> NSScreen? {
        switch preferences.screen {
        case .automatic:
            return NSScreen.main ?? NSScreen.screens.first
        case .main:
            return NSScreen.main ?? NSScreen.screens.first
        case .notched:
            return NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
                ?? NSScreen.main
                ?? NSScreen.screens.first
        }
    }

    private func horizontalOrigin(for width: CGFloat, on screen: NSScreen) -> CGFloat {
        let margin: CGFloat = 28
        switch preferences.position {
        case .leading:
            return screen.visibleFrame.minX + margin
        case .center:
            return screen.frame.midX - width / 2
        case .trailing:
            return screen.visibleFrame.maxX - width - margin
        }
    }

    private var shouldShowFloatingIsland: Bool {
        preferences.showsFloatingIsland
    }
}
