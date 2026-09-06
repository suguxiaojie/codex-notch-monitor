import AppKit
import SwiftUI

@MainActor
final class ActivitySettingsWindowController: NSObject, NSWindowDelegate {
    private let store: MonitorStore
    private var window: NSWindow?

    init(store: MonitorStore) {
        self.store = store
        super.init()
    }

    func show() {
        if let window {
            present(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(
                origin: .zero,
                size: NSSize(width: 1000, height: 720)
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "灵动岛设置"
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .line
        window.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1)
        window.isOpaque = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.contentMinSize = NSSize(width: 620, height: 620)
        window.setFrameAutosaveName("ActivitySettingsWindow")
        window.delegate = self

        let rootView = MonitorSettingsView(store: store)
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
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        installGlassSurface(in: window, hostingView: hostingView)
        window.center()

        self.window = window
        present(window)
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        publishPreviewVisibility(for: window)
    }

    func windowWillClose(_ notification: Notification) {
        publishPreviewVisibility(false)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        publishPreviewVisibility(false)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        publishPreviewVisibility(for: window)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        publishPreviewVisibility(for: window)
    }

    private func publishPreviewVisibility(for window: NSWindow) {
        publishPreviewVisibility(
            window.isVisible
                && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        )
    }

    private func publishPreviewVisibility(_ isVisible: Bool) {
        NotificationCenter.default.post(
            name: .activitySettingsPreviewVisibilityDidChange,
            object: isVisible
        )
    }

    private func installGlassSurface<Content: View>(
        in window: NSWindow,
        hostingView: NSHostingView<Content>
    ) {
        let frame = NSRect(origin: .zero, size: window.contentLayoutRect.size)

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: frame)
            glass.style = .clear
            glass.tintColor = .clear
            glass.cornerRadius = 12
            glass.contentView = hostingView
            hostingView.frame = glass.bounds
            hostingView.autoresizingMask = [.width, .height]
            window.contentView = glass
            return
        }

        let effect = NSVisualEffectView(frame: frame)
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.alphaValue = 0.72
        hostingView.frame = effect.bounds
        hostingView.autoresizingMask = [.width, .height]
        effect.addSubview(hostingView)
        window.contentView = effect
    }
}
