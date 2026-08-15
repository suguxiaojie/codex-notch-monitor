import AppKit
import Foundation
import UserNotifications

enum QuotaNotificationStatus: Equatable {
    case unknown
    case enabled
    case denied
}

final class QuotaResetNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorization(completion: @escaping (QuotaNotificationStatus) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, _ in
            self?.readAuthorizationStatus(completion: completion)
        }
    }

    func refreshAuthorizationStatus(completion: @escaping (QuotaNotificationStatus) -> Void) {
        readAuthorizationStatus(completion: completion)
    }

    @discardableResult
    func openNotificationSettings() -> Bool {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.coverai.codex-notch-monitor",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ]
        for value in candidates {
            if let url = URL(string: value), NSWorkspace.shared.open(url) {
                return true
            }
        }
        return false
    }

    private func readAuthorizationStatus(completion: @escaping (QuotaNotificationStatus) -> Void) {
        center.getNotificationSettings { settings in
            let status: QuotaNotificationStatus
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: status = .enabled
            case .denied: status = .denied
            case .notDetermined: status = .unknown
            @unknown default: status = .unknown
            }
            DispatchQueue.main.async { completion(status) }
        }
    }

    func notify(_ event: QuotaResetEvent) {
        guard event.reason.isNotifiable else { return }
        let content = UNMutableNotificationContent()
        content.title = event.reason.title
        content.body = Self.body(for: event)
        content.sound = .default
        if let sourceURL = event.sourceURL {
            content.userInfo["sourceURL"] = sourceURL
        }
        center.add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
    }

    func notifyAccountSwitch(
        _ transition: AccountTransition,
        projectCount: Int,
        sessionCount: Int,
        recoverableCount: Int
    ) {
        let content = UNMutableNotificationContent()
        content.title = "Codex 账号已切换"
        if recoverableCount == 0 {
            content.body = "\(transition.previousAlias) → \(transition.currentAlias)，已同步 \(projectCount) 个本地项目与 \(sessionCount) 条会话。"
        } else {
            content.body = "\(transition.previousAlias) → \(transition.currentAlias)，发现 \(recoverableCount) 条本地会话待恢复。"
        }
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: "account-switch-\(Int(transition.detectedAt.timeIntervalSince1970))",
            content: content,
            trigger: nil
        ))
    }

    static func body(for event: QuotaResetEvent) -> String {
        let details = event.changes.map { change in
            "\(change.bucketName) \(change.windowLabel)：\(change.previousRemainingPercent)% → \(change.currentRemainingPercent)%"
        }
        return details.joined(separator: "；")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let value = response.notification.request.content.userInfo["sourceURL"] as? String,
           let url = URL(string: value) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
