import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchWindowController: NSObject {
    private static let hostSize = NSSize(
        width: IslandPanelLayout.hostWidth,
        height: IslandPanelLayout.hostHeight
    )
    private let store: MonitorStore
    private var panel: NSPanel!
    private var hostingView: NotchHostingView!
    private var observers: [NSObjectProtocol] = []
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var globalScrollMonitor: Any?
    private var localScrollMonitor: Any?
    private var pointerTrackingTimer: Timer?
    private var navigationGeometryTimer: Timer?
    private var compactDetailsObserver: AnyCancellable?
    private var compactPointerOutsideSince: Date?
    private var expansionTransitionWorkItems: [DispatchWorkItem] = []
    private var swipeAccumX: CGFloat = 0
    private var swipeAccumY: CGFloat = 0
    private var swipeTriggered = false
    private var lastSwipeEventAt: TimeInterval = 0
    private var swipeResetWorkItem: DispatchWorkItem?

    init(store: MonitorStore) {
        self.store = store
        super.init()
        createPanel()
        observeScreens()
        observeOutsideClicks()
        observeNavigationGeometry()
        observeCompactDetails()
        observePointerForClickThrough()
        observePageSwipe()
    }

    deinit {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMoveMonitor { NSEvent.removeMonitor(globalMoveMonitor) }
        if let localMoveMonitor { NSEvent.removeMonitor(localMoveMonitor) }
        if let globalScrollMonitor { NSEvent.removeMonitor(globalScrollMonitor) }
        if let localScrollMonitor { NSEvent.removeMonitor(localScrollMonitor) }
        navigationGeometryTimer?.invalidate()
        pointerTrackingTimer?.invalidate()
        swipeResetWorkItem?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func show() {
        reposition(animated: false)
        panel.orderFrontRegardless()
    }

    private func createPanel() {
        let initialRect = NSRect(origin: .zero, size: Self.hostSize)
        panel = NSPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = false

        let view = NotchView(store: store) { [weak self] in
            self?.toggleExpansion()
        }
        hostingView = NotchHostingView(rootView: view, store: store)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
    }

    /// The fixed transparent host never resizes. Only the current visible
    /// silhouette accepts mouse input; every other pixel clicks through to
    /// the app below, matching CodexIsland's hosting architecture.
    private func observePointerForClickThrough() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in self?.updateMouseEventPassthrough() }
        }
        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handler)
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            handler(event)
            return event
        }
        pointerTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMouseEventPassthrough() }
        }
    }

    private func updateMouseEventPassthrough() {
        let shouldIgnore = !visibleIslandFrameOnScreen().contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents != shouldIgnore {
            panel.ignoresMouseEvents = shouldIgnore
        }
    }

    /// Observe scroll events before nested SwiftUI/NSScrollView responders can
    /// consume them. Global and local monitors are mutually complementary:
    /// the nonactivating panel may leave another app key, while controls inside
    /// the panel can still produce local events.
    private func observePageSwipe() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            Task { @MainActor in self?.handlePageSwipe(event) }
        }
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: handler)
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handler(event)
            // Never consume the event: vertical movement must still scroll the
            // Usage content, and horizontal movement has no native child action.
            return event
        }
    }

    private func handlePageSwipe(_ event: NSEvent) {
        guard store.isExpanded,
              store.expandedContentVisible,
              visibleIslandFrameOnScreen().contains(NSEvent.mouseLocation)
        else {
            resetPageSwipe()
            return
        }

        if event.modifierFlags.contains(.shift) {
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX
                : event.scrollingDeltaY
            guard abs(delta) > 0.5, !swipeTriggered else { return }
            postPageChange(for: delta)
            swipeTriggered = true
            schedulePageSwipeReset(after: 0.28)
            return
        }

        guard event.hasPreciseScrollingDeltas else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if event.phase == .began || now - lastSwipeEventAt > 0.22 {
            resetPageSwipe()
        }
        lastSwipeEventAt = now

        // Momentum belongs to the gesture that already crossed the threshold;
        // never let it turn one physical swipe into a second page change.
        if event.momentumPhase.isEmpty {
            swipeAccumX += event.scrollingDeltaX
            swipeAccumY += event.scrollingDeltaY
        }

        if !swipeTriggered,
           abs(swipeAccumX) >= 30,
           abs(swipeAccumX) > abs(swipeAccumY) * 1.20 {
            postPageChange(for: swipeAccumX)
            swipeTriggered = true
        }

        if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
            schedulePageSwipeReset(after: 0.08)
        } else {
            // Some short trackpad gestures have no reliable ended event after
            // crossing a nested ScrollView. An inactivity reset keeps the next
            // physical swipe responsive without unlocking the current momentum.
            schedulePageSwipeReset(after: 0.34)
        }
    }

    private func postPageChange(for deltaX: CGFloat) {
        NotificationCenter.default.post(
            name: deltaX < 0 ? .codexMonitorAdvancePage : .codexMonitorRewindPage,
            object: nil
        )
    }

    private func schedulePageSwipeReset(after delay: TimeInterval) {
        swipeResetWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.resetPageSwipe() }
        }
        swipeResetWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func resetPageSwipe() {
        swipeResetWorkItem?.cancel()
        swipeResetWorkItem = nil
        swipeAccumX = 0
        swipeAccumY = 0
        swipeTriggered = false
        lastSwipeEventAt = 0
    }

    private func observeScreens() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition(animated: false) }
        })
    }

    private func observeOutsideClicks() {
        // A global monitor sees clicks delivered to other applications. It cannot
        // consume those clicks, so the user's original action still happens.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                self?.collapseIfClickIsOutside(at: location)
            }
        }

        // A local monitor covers menu-bar and other clicks owned by this app.
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                self?.collapseIfClickIsOutside(at: location)
            }
            return event
        }
    }

    private func observeNavigationGeometry() {
        navigationGeometryTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.store.isExpanded else { return }
                self.reconcileCompactHoverFromPointer()
                let oldHeight = self.store.compactPanelHeight
                self.reposition(animated: abs(oldHeight - self.desiredCompactHeight()) > 0.5)
            }
        }
    }

    /// SwiftUI's hover-exit can be dropped by a nonactivating NSPanel while
    /// its frame is being animated. Polling the actual pointer against the
    /// current panel frame provides a deterministic fallback and, crucially,
    /// makes the transparent area disappear instead of merely hiding content.
    private func reconcileCompactHoverFromPointer() {
        guard store.compactDetailsVisible, store.approvalProjectCount == 0 else {
            compactPointerOutsideSince = nil
            return
        }
        if visibleIslandFrameOnScreen().contains(NSEvent.mouseLocation) {
            compactPointerOutsideSince = nil
            return
        }
        if let outsideSince = compactPointerOutsideSince {
            guard Date().timeIntervalSince(outsideSince) >= 0.45 else { return }
            compactPointerOutsideSince = nil
            store.compactDetailsVisible = false
        } else {
            compactPointerOutsideSince = Date()
        }
    }

    private func observeCompactDetails() {
        compactDetailsObserver = store.$compactDetailsVisible
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.store.isExpanded else { return }
                    self.reposition(animated: true)
                }
            }
    }

    private func collapseIfClickIsOutside(at screenLocation: NSPoint) {
        guard store.isExpanded, !visibleIslandFrameOnScreen().contains(screenLocation) else { return }
        setExpanded(false)
    }

    private func toggleExpansion() {
        guard !store.isExpansionTransitioning else { return }
        setExpanded(!store.isExpanded)
    }

    /// Separates silhouette movement from dense content arrival. CodexIsland
    /// uses the same perceptual ordering: shape commits first, content follows;
    /// on exit, content gets out of the way before the shape contracts.
    private func setExpanded(_ expanded: Bool) {
        guard expanded != store.isExpanded || store.isExpansionTransitioning else { return }
        expansionTransitionWorkItems.forEach { $0.cancel() }
        expansionTransitionWorkItems.removeAll()
        store.isExpansionTransitioning = true

        if expanded {
            store.compactDetailsVisible = false
            store.compactContentVisible = false
            store.expandedContentVisible = false

            scheduleExpansionStep(after: 0.06) { [weak self] in
                guard let self else { return }
                self.store.isExpanded = true
                self.reposition(animated: true)
            }
            scheduleExpansionStep(after: 0.22) { [weak self] in
                self?.store.expandedContentVisible = true
            }
            scheduleExpansionStep(after: 0.50) { [weak self] in
                self?.store.isExpansionTransitioning = false
            }
        } else {
            store.expandedContentVisible = false
            store.compactContentVisible = false

            scheduleExpansionStep(after: 0.08) { [weak self] in
                guard let self else { return }
                self.store.isExpanded = false
                self.store.compactDetailsVisible = false
                self.reposition(animated: true)
            }
            scheduleExpansionStep(after: 0.28) { [weak self] in
                self?.store.compactContentVisible = true
            }
            scheduleExpansionStep(after: 0.42) { [weak self] in
                guard let self else { return }
                self.store.compactContentVisible = true
                self.store.isExpansionTransitioning = false
            }
        }
    }

    private func scheduleExpansionStep(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        let item = DispatchWorkItem {
            Task { @MainActor in action() }
        }
        expansionTransitionWorkItems.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func reposition(animated: Bool) {
        guard let screen = targetScreen() else { return }
        updateNotchGeometry(for: screen)
        let size = Self.hostSize
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
        let frame = NSRect(origin: origin, size: size)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        updateMouseEventPassthrough()
    }

    private func visibleIslandFrameOnScreen() -> NSRect {
        let width = store.visibleIslandWidth
        let height = store.visibleIslandHeight
        return NSRect(
            x: panel.frame.midX - width / 2,
            y: panel.frame.maxY - height,
            width: width,
            height: height
        )
    }

    private func updateNotchGeometry(for screen: NSScreen) {
        let navigationBarHeight = menuBarHeight(for: screen)
        let compactHeight = navigationBarHeight + store.compactProjectsHeight
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea
        else {
            // `auxiliaryTop*Area` can transiently become nil while macOS
            // rebuilds the menu bar after wake, resolution changes, or status
            // item updates. A positive top safe-area still identifies a
            // physical notch, so retain the last reliable/default notch
            // geometry instead of flashing the no-notch 276 pt layout.
            if screen.safeAreaInsets.top > 0 {
                store.displayCutoutMode = .notched
                installFallbackNotchGeometryIfNeeded()
                store.compactMenuBarHeight = navigationBarHeight
                store.compactPanelHeight = compactHeight
                return
            }
            store.displayCutoutMode = .standardMenuBar
            store.notchObstructionWidth = 0
            // There is no physical cutout on Intel MacBooks and ordinary
            // external displays. Keep the status capsule compact so it does not
            // impersonate a notch or consume unnecessary menu-bar space.
            store.compactPanelWidth = min(276, screen.frame.width - 32)
            store.compactMenuBarHeight = navigationBarHeight
            store.compactPanelHeight = compactHeight
            return
        }

        // Reject malformed/transitional auxiliary rectangles. In particular,
        // their inner edges must form a plausible central camera gap.
        let measuredSafeGap = right.minX - left.maxX
        guard left.width > 0,
              right.width > 0,
              measuredSafeGap >= 80,
              measuredSafeGap <= 308
        else { return }

        // NSScreen's auxiliary areas describe Apple's conservative menu-bar safe
        // zone, not only the opaque camera housing. It includes roughly 14 pt of
        // unused padding on each side on notched MacBooks. Reclaim that padding so
        // labels approach the visible hardware while retaining a small hard floor.
        let hardwareGap = max(CompactGeometryPolicy.minimumNotchGap, measuredSafeGap - 28)

        // Menu extras are separate layer-25 windows. Their closest leading edge is
        // the real-time right boundary available to the island. This reacts to
        // hidden/shown status items without requesting Accessibility permission.
        // A missing layer-25 menu item sample is not permission to consume the
        // entire right auxiliary area. Keep the prior width until the next
        // reliable 0.6 s sample rather than stretching to the screen edge.
        guard let rightBoundary = nearestRightMenuItemX(on: screen, after: right.minX),
              let fittedPanelWidth = CompactGeometryPolicy.fittedNotchedPanelWidth(
                hardwareGap: hardwareGap,
                leftCapacity: left.width - 12,
                rightCapacity: rightBoundary - right.minX - 16,
                screenWidth: screen.frame.width
              )
        else {
            store.displayCutoutMode = .notched
            installFallbackNotchGeometryIfNeeded()
            store.compactMenuBarHeight = navigationBarHeight
            store.compactPanelHeight = compactHeight
            return
        }

        store.displayCutoutMode = .notched
        if abs(store.notchObstructionWidth - hardwareGap) > 0.5 {
            store.notchObstructionWidth = hardwareGap
        }
        if abs(store.compactPanelWidth - fittedPanelWidth) > 0.5 {
            store.compactPanelWidth = fittedPanelWidth
        }
        if abs(store.compactMenuBarHeight - navigationBarHeight) > 0.5 {
            store.compactMenuBarHeight = navigationBarHeight
        }
        if abs(store.compactPanelHeight - compactHeight) > 0.5 {
            store.compactPanelHeight = compactHeight
        }
    }

    private func installFallbackNotchGeometryIfNeeded() {
        guard store.notchObstructionWidth < 80 else { return }
        store.notchObstructionWidth = CompactGeometryPolicy.minimumNotchGap
        store.compactPanelWidth = min(
            CompactGeometryPolicy.maximumNotchedPanelWidth,
            max(store.compactPanelWidth, CompactGeometryPolicy.minimumNotchGap + 180)
        )
    }

    private func desiredCompactHeight() -> CGFloat {
        store.compactMenuBarHeight + store.compactProjectsHeight
    }

    private func menuBarHeight(for screen: NSScreen) -> CGFloat {
        let visibleDifference = screen.frame.maxY - screen.visibleFrame.maxY
        let reportedHeight = max(screen.safeAreaInsets.top, visibleDifference)
        return max(26, min(36, reportedHeight))
    }

    private func nearestRightMenuItemX(on screen: NSScreen, after notchRightEdge: CGFloat) -> CGFloat? {
        guard let rows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        return rows.compactMap { row -> CGFloat? in
            guard let layer = row[kCGWindowLayer as String] as? Int,
                  layer == Int(NSWindow.Level.statusBar.rawValue),
                  let owner = row[kCGWindowOwnerName as String] as? String,
                  owner != "Codex Monitor",
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let xNumber = bounds["X"] as? NSNumber,
                  let widthNumber = bounds["Width"] as? NSNumber,
                  let heightNumber = bounds["Height"] as? NSNumber
            else { return nil }
            let x = CGFloat(xNumber.doubleValue)
            let width = CGFloat(widthNumber.doubleValue)
            let height = CGFloat(heightNumber.doubleValue)
            guard
                  height <= 48,
                  width <= 260,
                  x >= notchRightEdge,
                  x < screen.frame.maxX
            else { return nil }
            return x
        }.min()
    }
}

/// Limits AppKit hit testing to the currently rendered island inside the
/// fixed host window. `acceptsFirstMouse` prevents the first click from being
/// consumed merely to activate a non-key panel.
@MainActor
private final class NotchHostingView: NSHostingView<NotchView> {
    private unowned let store: MonitorStore

    init(rootView: NotchView, store: MonitorStore) {
        self.store = store
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init(rootView: NotchView) {
        fatalError("Use init(rootView:store:)")
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let width = store.visibleIslandWidth
        let height = store.visibleIslandHeight
        let rect = NSRect(
            x: bounds.midX - width / 2,
            y: bounds.maxY - height,
            width: width,
            height: height
        )
        return rect.contains(point) ? super.hitTest(point) : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

}
