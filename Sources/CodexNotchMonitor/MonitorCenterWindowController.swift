import AppKit
import SwiftUI

enum MonitorCenterLayout {
    static let width: CGFloat = 872
    static let height: CGFloat = 620
    static let sidebarWidth: CGFloat = 216
}

private final class MonitorCenterGlassCompositionView: NSView {
    private let chromeView = MonitorCenterGlassChromeView()
    private let hostedContentView: NSView

    init(contentView: NSView) {
        hostedContentView = contentView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 24
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
}

private final class MonitorCenterGlassChromeView: NSView {
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
        let radius = min(24, min(bounds.width, bounds.height) / 2)
        let shape = NSBezierPath(
            roundedRect: bounds,
            xRadius: radius,
            yRadius: radius
        )
        // Monitor Center intentionally keeps a dark information surface even
        // on a light desktop. Its charts and evidence colors are authored for
        // light text, so an appearance-adaptive white fill destroys contrast.
        // This is a neutral fill only: it does not add backdrop blur or frost.
        // Keep enough ambient context to read as glass, while preventing a
        // light webpage behind the window from washing out cards and labels.
        NSColor.black.withAlphaComponent(0.82).setFill()
        shape.fill()
        NSColor.white
            .withAlphaComponent(0.10)
            .setStroke()
        shape.lineWidth = 0.5
        shape.stroke()
    }
}

@MainActor
final class MonitorCenterWindowController: NSObject, NSWindowDelegate {
    private let store: MonitorStore
    private let onOpenActivitySettings: () -> Void
    private var window: NSWindow?
    private var hostingView: NSHostingView<NotchView>?
    private var exportDirectoryPanel: NSOpenPanel?

    init(
        store: MonitorStore,
        onOpenActivitySettings: @escaping () -> Void
    ) {
        self.store = store
        self.onOpenActivitySettings = onOpenActivitySettings
        super.init()
        store.setExportDirectoryPresenter { [weak self] currentDirectory, completion in
            self?.presentExportDirectoryPanel(
                currentDirectory: currentDirectory,
                completion: completion
            )
        }
        store.setSessionExportDraftPresenter { [weak self] in
            self?.presentSessionExportConfiguration()
        }
    }

    func show(section: MonitorCenterSection) {
        guard section != .settings else {
            onOpenActivitySettings()
            return
        }
        let rootView = NotchView(
            store: store,
            onToggle: {},
            onOpenCenter: { [weak self] requestedSection in
                if requestedSection == .settings {
                    self?.onOpenActivitySettings()
                }
            },
            surface: .center,
            initialSection: section
        )

        if let window {
            let replacement = NSHostingView(rootView: rootView)
            replacement.layer?.backgroundColor = NSColor.clear.cgColor
            window.contentView = replacement
            hostingView = replacement
            present(window)
            installGlassSurface(in: window, hostingView: replacement)
            route(to: section)
            return
        }

        let frame = NSRect(
            origin: .zero,
            size: NSSize(width: MonitorCenterLayout.width, height: MonitorCenterLayout.height)
        )
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Monitor"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hostingView
        window.center()
        self.window = window
        self.hostingView = hostingView
        present(window)
        installGlassSurface(in: window, hostingView: hostingView)
        route(to: section)
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func route(to section: MonitorCenterSection) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .monitorCenterSelectSection,
                object: section
            )
        }
    }

    private func presentExportDirectoryPanel(
        currentDirectory: URL,
        completion: @escaping (URL?) -> Void
    ) {
        guard let window else { return }
        if let exportDirectoryPanel {
            restoreOrdinaryWindow(window)
            exportDirectoryPanel.makeKey()
            return
        }
        restoreOrdinaryWindow(window)
        let panel = NSOpenPanel()
        panel.title = "选择项目导出位置"
        panel.prompt = "选择此文件夹"
        panel.message = "导出文件会保存到所选文件夹；已有同名文件会自动使用新的序号。"
        panel.directoryURL = currentDirectory
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.collectionBehavior.insert(.moveToActiveSpace)
        exportDirectoryPanel = panel
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            self?.exportDirectoryPanel = nil
            completion(response == .OK ? panel?.url : nil)
            self?.restoreOrdinaryWindow(window)
        }
    }

    private func presentSessionExportConfiguration() {
        guard let window else { return }
        restoreOrdinaryWindow(window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            self.restoreOrdinaryWindow(window)
        }
    }

    private func restoreOrdinaryWindow(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.level = .normal
        window.makeKeyAndOrderFront(nil)
    }

    private func installGlassSurface(
        in window: NSWindow,
        hostingView: NSHostingView<NotchView>
    ) {
        hostingView.removeFromSuperview()
        let size = window.contentView?.bounds.size ?? window.frame.size
        let frame = NSRect(origin: .zero, size: size)

        if #available(macOS 26.0, *) {
            let composition = MonitorCenterGlassCompositionView(
                contentView: hostingView
            )
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .clear
            glass.tintColor = .clear
            glass.cornerRadius = 24
            glass.contentView = composition
            glass.wantsLayer = true
            glass.layer?.cornerRadius = 24
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true
            composition.frame = glass.bounds
            composition.autoresizingMask = [.width, .height]
            window.contentView = glass
            return
        }

        let fallback = NSVisualEffectView(frame: frame)
        fallback.material = .underWindowBackground
        fallback.blendingMode = .behindWindow
        fallback.state = .active
        fallback.alphaValue = 0.62
        fallback.wantsLayer = true
        fallback.layer?.cornerRadius = 24
        fallback.layer?.cornerCurve = .continuous
        fallback.layer?.masksToBounds = true
        let composition = MonitorCenterGlassCompositionView(
            contentView: hostingView
        )
        composition.frame = fallback.bounds
        composition.autoresizingMask = [.width, .height]
        fallback.addSubview(composition)
        window.contentView = fallback
    }
}
