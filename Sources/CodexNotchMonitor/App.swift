import AppKit
import SwiftUI

@main
struct CodexNotchMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = MonitorStore()
    private var windowController: NotchWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        windowController = NotchWindowController(store: store)
        windowController?.show()
        installStatusItem()
        store.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        store.refreshNotificationStatus()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "Codex Monitor")
        let menu = NSMenu()
        menu.addItem(withTitle: "显示或收起", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "刷新额度", action: #selector(refreshQuota), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "访问 CoverAI 官网", action: #selector(openCoverAI), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Codex Monitor", action: #selector(quit), keyEquivalent: "q")
        for menuItem in menu.items { menuItem.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func togglePanel() {
        store.isExpanded.toggle()
        windowController?.show()
    }

    @objc private func refreshQuota() {
        store.refreshQuota()
    }

    @objc private func openCoverAI() {
        CoverAILinks.open(.appMenu)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
