import AppKit
import SwiftUI

private final class GlancePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class GlanceGlassCompositionView: NSView {
    private let chromeView = GlanceGlassChromeView()
    private let hostedContentView: NSView

    init(contentView: NSView, surfaceOpacity: CGFloat) {
        hostedContentView = contentView
        super.init(frame: .zero)
        chromeView.surfaceOpacity = surfaceOpacity
        wantsLayer = true
        layer?.cornerRadius = GlanceLayout.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        addSubview(chromeView)
        addSubview(contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        chromeView.frame = bounds
        hostedContentView.frame = bounds
    }

    func updateSurfaceOpacity(_ opacity: CGFloat) {
        chromeView.surfaceOpacity = opacity
    }
}

private final class GlanceGlassChromeView: NSView {
    var surfaceOpacity: CGFloat = 0.38 {
        didSet { needsDisplay = true }
    }
    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let radius = min(
            GlanceLayout.cornerRadius,
            min(bounds.width, bounds.height) / 2
        )
        let shape = NSBezierPath(
            roundedRect: bounds,
            xRadius: radius,
            yRadius: radius
        )
        let usesLightAppearance = effectiveAppearance.bestMatch(
            from: [.aqua, .darkAqua]
        ) == .aqua
        let fill = usesLightAppearance
            ? NSColor.white.withAlphaComponent(surfaceOpacity)
            : NSColor.black.withAlphaComponent(surfaceOpacity)
        fill.setFill()
        shape.fill()

        (usesLightAppearance ? NSColor.black : NSColor.white)
            .withAlphaComponent(0.08)
            .setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
    }
}

@MainActor
final class GlanceWindowController: NSObject {
    private let store: MonitorStore
    private let anchorRect: () -> NSRect?
    private let onOpenCenter: (MonitorCenterSection) -> Void
    private var panel: NSPanel!
    private var hostingView: NSHostingView<GlanceView>!
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var preferencesObserver: NSObjectProtocol?
    private var centerSectionObserver: NSObjectProtocol?
    private var shownAt: Date?
    private var isPinnedForPanelSettings = false
    private weak var glassCompositionView: GlanceGlassCompositionView?

    init(
        store: MonitorStore,
        anchorRect: @escaping () -> NSRect? = { nil },
        onOpenCenter: @escaping (MonitorCenterSection) -> Void
    ) {
        self.store = store
        self.anchorRect = anchorRect
        self.onOpenCenter = onOpenCenter
        super.init()
        createPanel()
        observeOutsideClicks()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: .glanceSurfaceOpacityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let opacity = notification.object as? Double
            Task { @MainActor in
                if let opacity {
                    self?.glassCompositionView?.updateSurfaceOpacity(CGFloat(opacity))
                } else {
                    self?.updateSurfaceOpacity()
                }
            }
        }
        centerSectionObserver = NotificationCenter.default.addObserver(
            forName: .monitorCenterSectionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let section = notification.object as? MonitorCenterSection else { return }
            Task { @MainActor in self?.handleMonitorCenterSection(section) }
        }
    }

    deinit {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        if let centerSectionObserver { NotificationCenter.default.removeObserver(centerSectionObserver) }
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        reposition()
        store.isGlancePresented = true
        shownAt = Date()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        makePanelKeyForGlassPresentation()
        installGlassSurface()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                self.panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        store.isGlancePresented = false
        shownAt = nil
        isPinnedForPanelSettings = false
        panel.orderOut(nil)
    }

    private func handleMonitorCenterSection(_ section: MonitorCenterSection) {
        if section == .panelSettings {
            isPinnedForPanelSettings = true
            if panel.isVisible {
                reposition()
                panel.orderFrontRegardless()
                makePanelKeyForGlassPresentation()
            } else {
                show()
            }
            return
        }
        guard isPinnedForPanelSettings else { return }
        hide()
    }

    private func createPanel() {
        let availableHeight = (NSScreen.main?.visibleFrame.height ?? GlanceLayout.height) - 16
        let size = NSSize(
            width: GlanceLayout.width,
            height: min(GlanceLayout.height, max(230, availableHeight))
        )
        panel = GlancePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow

        let root = GlanceView(
            store: store,
            onQuit: { NSApp.terminate(nil) },
            onOpenCenter: { [weak self] section in
                if section == .panelSettings {
                    self?.isPinnedForPanelSettings = true
                } else {
                    self?.hide()
                }
                self?.onOpenCenter(section)
            },
            onPreferredHeightChange: { [weak self] height in
                self?.updatePreferredHeight(height)
            }
        )
        hostingView = NSHostingView(rootView: root)
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        installGlassSurface()
    }

    private func updatePreferredHeight(_ requestedHeight: CGFloat) {
        guard panel != nil else { return }
        let availableHeight = (targetScreen()?.visibleFrame.height ?? GlanceLayout.height) - 16
        let height = min(
            GlanceLayout.height,
            min(max(230, availableHeight), max(230, requestedHeight))
        )
        guard abs(panel.frame.height - height) > 0.5 else { return }
        let target = NSRect(
            x: panel.frame.minX,
            y: panel.frame.maxY - height,
            width: GlanceLayout.width,
            height: height
        )
        guard panel.isVisible else {
            panel.setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
    }

    private func installGlassSurface() {
        guard panel != nil, hostingView != nil else { return }
        hostingView.removeFromSuperview()
        let size = panel.contentView?.bounds.size ?? panel.frame.size
        let surface = makeGlassSurface(size: size, contentView: hostingView)
        surface.frame = NSRect(origin: .zero, size: size)
        surface.autoresizingMask = [.width, .height]
        panel.contentView = surface
    }

    private func makeGlassSurface(size: NSSize, contentView: NSView) -> NSView {
        let frame = NSRect(origin: .zero, size: size)

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            let composition = GlanceGlassCompositionView(
                contentView: contentView,
                surfaceOpacity: currentSurfaceOpacity
            )
            glassCompositionView = composition
            glass.style = .clear
            glass.tintColor = .clear
            glass.cornerRadius = GlanceLayout.cornerRadius
            glass.contentView = composition
            glass.wantsLayer = true
            glass.layer?.cornerRadius = GlanceLayout.cornerRadius
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true
            composition.frame = glass.bounds
            composition.autoresizingMask = [.width, .height]
            return glass
        }

        let fallback = NSVisualEffectView(frame: frame)
        fallback.material = .underWindowBackground
        fallback.blendingMode = .behindWindow
        fallback.state = .active
        fallback.alphaValue = 0.62
        fallback.wantsLayer = true
        fallback.layer?.cornerRadius = GlanceLayout.cornerRadius
        fallback.layer?.cornerCurve = .continuous
        fallback.layer?.masksToBounds = true
        let composition = GlanceGlassCompositionView(
            contentView: contentView,
            surfaceOpacity: currentSurfaceOpacity
        )
        glassCompositionView = composition
        composition.frame = fallback.bounds
        composition.autoresizingMask = [.width, .height]
        fallback.addSubview(composition)
        return fallback
    }

    private var currentSurfaceOpacity: CGFloat {
        CGFloat(GlanceContentPreferences.load().surfaceOpacity)
    }

    private func updateSurfaceOpacity() {
        glassCompositionView?.updateSurfaceOpacity(currentSurfaceOpacity)
    }

    private func makePanelKeyForGlassPresentation() {
        panel.makeKey()
        guard !panel.isKeyWindow else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    private func reposition() {
        guard let screen = targetScreen() else { return }
        let size = panel.frame.size
        let margin: CGFloat = 8
        let anchor = anchorRect()
        let proposedX = anchor.map { $0.midX - size.width / 2 }
            ?? (screen.visibleFrame.maxX - size.width - 18)
        let x = min(
            max(proposedX, screen.visibleFrame.minX + margin),
            screen.visibleFrame.maxX - size.width - margin
        )
        let top = anchor.map { min($0.minY - 5, screen.visibleFrame.maxY - 5) }
            ?? (screen.visibleFrame.maxY - 10)
        panel.setFrameOrigin(NSPoint(
            x: x,
            y: top - size.height
        ))
    }

    private func targetScreen() -> NSScreen? {
        NSScreen.main ?? NSScreen.screens.first
    }

    private func observeOutsideClicks() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self,
                      self.panel.isVisible,
                      self.canDismissFromOutsideClick,
                      !self.isAnchorClick(location),
                      !self.panel.frame.contains(location)
                else { return }
                self.hide()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            let location = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self,
                      self.panel.isVisible,
                      self.canDismissFromOutsideClick,
                      NSApp.modalWindow == nil,
                      !self.isAnchorClick(location),
                      !self.panel.frame.contains(location)
                else { return }
                self.hide()
            }
            return event
        }
    }

    private var canDismissFromOutsideClick: Bool {
        guard !isPinnedForPanelSettings else { return false }
        guard let shownAt else { return false }
        return Date().timeIntervalSince(shownAt) >= 0.25
    }

    private func isAnchorClick(_ location: NSPoint) -> Bool {
        guard let anchor = anchorRect() else { return false }
        return anchor.insetBy(dx: -4, dy: -4).contains(location)
    }
}
