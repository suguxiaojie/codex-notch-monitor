import Foundation
import SwiftUI

enum MonitorRefreshCadence {
    static let quota: TimeInterval = 60
    static let cost: TimeInterval = 300
}

enum IslandPanelLayout {
    static let glanceWidth: CGFloat = 340
    static let expandedWidth: CGFloat = 430
    /// Fixed transparent host height for the narrow glance popover. Detailed
    /// Usage, Cost, activity, and continuity content now lives in Monitor Center.
    static let expandedContentHeight: CGFloat = 500
    static let hostWidth: CGFloat = 460
    static let hostHeight: CGFloat = 560
}

struct RateLimitWindow: Equatable {
    let usedPercent: Int
    let windowDurationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int { max(0, min(100, 100 - usedPercent)) }

    var windowLabel: String {
        guard let minutes = windowDurationMinutes else { return "额度窗口" }
        if minutes >= 10_080 { return "每周额度" }
        if minutes >= 1_440 { return "\(minutes / 1_440) 天额度" }
        if minutes >= 60 { return "\(minutes / 60) 小时额度" }
        return "\(minutes) 分钟额度"
    }
}

enum QuotaResetCountdown {
    static func text(until resetDate: Date, relativeTo now: Date) -> String {
        let remainingSeconds = Int(resetDate.timeIntervalSince(now))
        guard remainingSeconds > 0 else { return "等待额度刷新" }

        let totalMinutes = remainingSeconds / 60
        guard totalMinutes > 0 else { return "即将重置" }

        let totalHours = totalMinutes / 60
        if totalHours >= 24 {
            let days = totalHours / 24
            let hours = totalHours % 24
            return hours > 0
                ? "\(days)天\(hours)小时后重置"
                : "\(days)天后重置"
        }

        if totalHours > 0 {
            let minutes = totalMinutes % 60
            return minutes > 0
                ? "\(totalHours)小时\(minutes)分钟后重置"
                : "\(totalHours)小时后重置"
        }

        return "\(totalMinutes)分钟后重置"
    }
}

enum MenuBarStatusFormatter {
    static func title(
        for window: RateLimitWindow?,
        relativeTo now: Date
    ) -> String {
        guard let window else { return "--" }
        let reset = resetText(window.resetsAt, relativeTo: now)
        return reset.isEmpty
            ? "\(window.remainingPercent)%"
            : "\(window.remainingPercent)% · \(reset)"
    }

    static func resetText(_ resetAt: Date?, relativeTo now: Date) -> String {
        guard let resetAt else { return "" }
        let minutes = max(0, Int(resetAt.timeIntervalSince(now) / 60))
        let hours = minutes / 60
        if hours >= 24 { return "\(hours / 24)天" }
        if hours > 0 { return "\(hours)小时" }
        return "\(max(1, minutes))分"
    }
}

enum MenuBarQuotaIconState: Equatable {
    case loading
    case ready(Int)
    case failed
}

enum MenuBarQuotaIconModel {
    static func state(for quotaState: QuotaState) -> MenuBarQuotaIconState {
        switch quotaState {
        case .loading:
            return .loading
        case let .loaded(buckets, _):
            let bucket = buckets.first(where: { $0.id == "codex" }) ?? buckets.first
            guard let remaining = bucket?.headlineWindow?.remainingPercent else { return .loading }
            return .ready(clamp(remaining))
        case let .failed(_, previous):
            let bucket = previous.first(where: { $0.id == "codex" }) ?? previous.first
            guard let remaining = bucket?.headlineWindow?.remainingPercent else { return .failed }
            return .ready(clamp(remaining))
        }
    }

    static func progress(for remainingPercent: Int) -> Double {
        Double(clamp(remainingPercent)) / 100
    }

    private static func clamp(_ value: Int) -> Int {
        max(0, min(100, value))
    }
}

enum StatusItemCoexistencePolicy {
    static let quotaViewBundleIdentifier = "com.quotaview.menubar"

    static func usesIconOnlyMode(
        runningBundleIdentifiers: Set<String>
    ) -> Bool {
        runningBundleIdentifiers.contains(quotaViewBundleIdentifier)
    }

    static func effectiveDensity(
        preference: MenuBarInformationDensity,
        quotaViewIsRunning: Bool,
        availableWidth: CGFloat?
    ) -> MenuBarInformationDensity {
        guard preference == .automatic else { return preference }
        if quotaViewIsRunning { return .iconOnly }
        guard let availableWidth else { return .compact }
        if availableWidth >= 190 { return .detailed }
        if availableWidth >= 92 { return .compact }
        return .iconOnly
    }
}

enum OpenAIPlanDisplayName {
    static func resolve(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch normalized {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "prolite", "pro_lite", "pro_5x": return "Pro 5x"
        case "pro", "pro_20x": return "Pro 20x"
        case "team", "self_serve_business_usage_based", "business": return "Business"
        case "enterprise_cbp_usage_based", "enterprise": return "Enterprise"
        case "edu", "education": return "Edu"
        case "api", "api_key": return "API Key"
        default: return nil
        }
    }
}

enum MenuBarActivityFormatter {
    static func title(
        phase: TaskPhase,
        projectName: String,
        actionSummary: String,
        projectCount: Int,
        quotaTitle: String
    ) -> String {
        var parts = [phase.menuBarTitle]
        let project = compact(projectName, limit: 9)
        let action = compactAction(actionSummary, phase: phase)
        if !action.isEmpty {
            parts.append(action)
        } else if !project.isEmpty {
            parts.append(project)
        }
        if projectCount > 1 { parts.append("+\(projectCount - 1)") }
        parts.append(compactQuota(quotaTitle))
        return parts.joined(separator: " · ")
    }

    static func tooltip(
        phase: TaskPhase,
        projectName: String,
        actionSummary: String,
        projectCount: Int,
        quotaTitle: String
    ) -> String {
        var lines = [
            "\(phase.title) · \(projectName)",
            actionSummary.replacingOccurrences(of: "\n", with: "；"),
        ]
        if projectCount > 1 { lines.append("同时运行 \(projectCount) 个项目") }
        lines.append("额度 \(quotaTitle)")
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func compactAction(_ value: String, phase: TaskPhase) -> String {
        var result = value
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for prefix in ["正在", "已经", "已"] where result.hasPrefix(prefix) {
            result.removeFirst(prefix.count)
            break
        }
        guard result != phase.title,
              result != phase.menuBarTitle
        else { return "" }
        return compact(result, limit: 15)
    }

    private static func compactQuota(_ value: String) -> String {
        value.split(separator: " ").first.map(String.init) ?? value
    }

    private static func compact(_ value: String, limit: Int) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(max(1, limit - 1))) + "…"
    }
}

struct RateLimitBucket: Identifiable, Equatable {
    let id: String
    let name: String
    let planType: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let creditBalance: String?
    let hasCredits: Bool

    /// Every server-provided window, shortest period first. The App Server may
    /// expose the rolling window as either primary or secondary, so UI logic
    /// must not attach semantic meaning to the field order.
    var windows: [RateLimitWindow] {
        var result: [RateLimitWindow] = []
        for window in [primary, secondary].compactMap({ $0 }) where !result.contains(window) {
            result.append(window)
        }
        return result.sorted { lhs, rhs in
            switch (lhs.windowDurationMinutes, rhs.windowDurationMinutes) {
            case let (left?, right?): return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }
    }

    /// The compact island prioritizes the fastest-resetting constraint; the
    /// expanded panel still shows every window independently.
    var headlineWindow: RateLimitWindow? { windows.first }
}

struct QuotaResetCredit: Identifiable, Equatable {
    let id: String
    let resetType: String
    let status: String
    let grantedAt: Date?
    let expiresAt: Date?
    let title: String?
    let description: String?
}

struct QuotaResetCreditSummary: Equatable {
    let availableCount: Int
    let credits: [QuotaResetCredit]

    func nearestExpiration(relativeTo now: Date) -> Date? {
        let dates = credits.compactMap(\.expiresAt)
        return dates.filter { $0 > now }.min() ?? dates.max()
    }

    func nextRedeemableCredit(relativeTo now: Date) -> QuotaResetCredit? {
        credits
            .filter { credit in
                let status = credit.status.lowercased()
                let statusAllowsUse = !status.contains("expired")
                    && !status.contains("redeemed")
                    && !status.contains("used")
                return statusAllowsUse && (credit.expiresAt == nil || credit.expiresAt! > now)
            }
            .sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (left?, right?): return left < right
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.id < rhs.id
                }
            }
            .first
    }
}

enum QuotaResetConsumeOutcome: String, Equatable {
    case reset
    case nothingToReset
    case noCredit
    case alreadyRedeemed
}

enum QuotaState: Equatable {
    case loading
    case loaded([RateLimitBucket], Date)
    case failed(String, previous: [RateLimitBucket])

    var buckets: [RateLimitBucket] {
        switch self {
        case .loading: return []
        case let .loaded(value, _): return value
        case let .failed(_, previous): return previous
        }
    }

    var primaryBucket: RateLimitBucket? {
        buckets.first(where: { $0.id == "codex" }) ?? buckets.first
    }
}

enum TaskPhase: String, Codable {
    case starting
    case working
    case usingTool
    case waitingApproval
    case completed
    case ended
    case failed

    var title: String {
        switch self {
        case .starting: return "正在开始"
        case .working: return "正在思考"
        case .usingTool: return "正在执行工具"
        case .waitingApproval: return "等待你的批准"
        case .completed: return "任务已完成"
        case .ended: return "会话已结束"
        case .failed: return "任务失败"
        }
    }

    var menuBarTitle: String {
        switch self {
        case .starting: return "开始"
        case .working: return "思考"
        case .usingTool: return "工具"
        case .waitingApproval: return "待批准"
        case .completed: return "完成"
        case .ended: return "结束"
        case .failed: return "失败"
        }
    }

    var color: Color {
        switch self {
        case .starting, .working: return .blue
        case .usingTool: return .cyan
        case .waitingApproval: return .orange
        case .completed: return .green
        case .ended: return .gray
        case .failed: return .red
        }
    }

    var isActive: Bool {
        switch self {
        case .starting, .working, .usingTool, .waitingApproval: return true
        case .completed, .ended, .failed: return false
        }
    }

    /// Lower values deserve the user's attention first.
    var attentionPriority: Int {
        switch self {
        case .waitingApproval: return 0
        case .failed: return 1
        case .usingTool: return 2
        case .working: return 3
        case .starting: return 4
        case .completed: return 5
        case .ended: return 6
        }
    }
}

struct HookEvent: Codable {
    let sessionID: String
    let turnID: String?
    let cwd: String
    let hookEventName: String
    let model: String?
    let toolName: String?
    let receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case turnID = "turn_id"
        case cwd
        case hookEventName = "hook_event_name"
        case model
        case toolName = "tool_name"
        case receivedAt = "received_at"
    }
}

struct MonitoredTask: Identifiable, Equatable {
    let id: String
    var turnID: String?
    var projectName: String
    var projectPath: String
    var model: String?
    var toolName: String?
    var phase: TaskPhase
    var updatedAt: Date
}

enum SessionActivityKind: String, Equatable {
    case progress
    case command
    case read
    case search
    case fileChange
    case tool

    var symbol: String {
        switch self {
        case .progress: return "text.bubble.fill"
        case .command: return "terminal.fill"
        case .read: return "book.pages.fill"
        case .search: return "magnifyingglass"
        case .fileChange: return "doc.badge.gearshape"
        case .tool: return "wrench.and.screwdriver.fill"
        }
    }
}

struct SessionActivityItem: Identifiable, Equatable {
    let id: String
    let kind: SessionActivityKind
    let title: String
    var isRunning: Bool
    var updatedAt: Date
}

struct ActiveSessionState: Identifiable, Equatable {
    var id: String { task.id }
    let task: MonitoredTask
    let activities: [SessionActivityItem]
}

struct ActiveProjectState: Identifiable, Equatable {
    let id: String
    let name: String
    let path: String
    let sessions: [ActiveSessionState]
    let task: MonitoredTask
    let activities: [SessionActivityItem]

    var sessionCount: Int { sessions.count }

    /// A project can merge several sessions whose activity arrays are not in
    /// display order. Always select by the event timestamp so an old command
    /// or progress message cannot occupy the compact project card.
    var latestDisplayActivity: SessionActivityItem? {
        activities.max { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            if lhs.isRunning != rhs.isRunning { return !lhs.isRunning && rhs.isRunning }
            return activityDisplayPriority(lhs.kind) < activityDisplayPriority(rhs.kind)
        }
    }

    var detailedActionSummary: String {
        guard let primary = latestDisplayActivity else { return task.phase.title }
        let primaryTitle = displayTitle(primary)
        let runningOthers = activities
            .filter { $0.id != primary.id && $0.isRunning }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return activityDisplayPriority($0.kind) > activityDisplayPriority($1.kind)
            }
        guard let secondary = runningOthers.first else { return primaryTitle }
        let remaining = runningOthers.count - 1
        let suffix = remaining > 0 ? " · 另有 \(remaining) 个" : ""
        return "\(primaryTitle)\n同时：\(displayTitle(secondary))\(suffix)"
    }

    private func displayTitle(_ activity: SessionActivityItem) -> String {
        if activity.kind == .progress
            || activity.title.hasPrefix("正在")
            || activity.title.hasPrefix("已")
            || activity.title.hasPrefix("等待") {
            return activity.title
        }
        return (activity.isRunning ? "正在" : "已") + activity.title
    }

    private func activityDisplayPriority(_ kind: SessionActivityKind) -> Int {
        switch kind {
        case .progress: return 0
        case .command, .read, .search, .fileChange, .tool: return 1
        }
    }
}

enum CompactProjectLayout {
    static func contentHeight(for projectCount: Int) -> CGFloat {
        switch projectCount {
        case ...0: return 0
        case 1: return 22
        case 2: return 38
        default: return 62
        }
    }

    static func directProjectCount(for projectCount: Int) -> Int {
        projectCount > 4 ? 3 : max(0, projectCount)
    }

    static func reconcileOrder(existing: [String], discovered: [String]) -> [String] {
        let live = Set(discovered)
        var result = existing.filter { live.contains($0) }
        result.append(contentsOf: discovered.filter { !result.contains($0) })
        return result
    }
}

/// Pure geometry rules shared by the window controller and smoke tests. Screen
/// APIs can briefly lose their auxiliary notch areas while the menu bar is
/// rebuilding; every accepted value must therefore remain inside the fixed
/// SwiftUI host instead of allowing one bad sample to stretch the island.
enum CompactGeometryPolicy {
    static let minimumNotchGap: CGFloat = 140
    static let minimumWingWidth: CGFloat = 105
    static let maximumWingWidth: CGFloat = 190
    static let maximumNotchedPanelWidth: CGFloat = IslandPanelLayout.expandedWidth

    static func fittedNotchedPanelWidth(
        hardwareGap: CGFloat,
        leftCapacity: CGFloat,
        rightCapacity: CGFloat,
        screenWidth: CGFloat
    ) -> CGFloat? {
        guard hardwareGap >= 80,
              hardwareGap <= 280,
              leftCapacity >= minimumWingWidth,
              rightCapacity >= minimumWingWidth,
              screenWidth > 64
        else { return nil }

        let wingWidth = min(maximumWingWidth, leftCapacity, rightCapacity)
        let measured = min(
            screenWidth - 32,
            maximumNotchedPanelWidth,
            hardwareGap + wingWidth * 2
        )
        guard measured >= hardwareGap + minimumWingWidth * 2 else { return nil }
        return floor(measured / 2) * 2
    }
}

enum HookEventMapper {
    static func phase(for eventName: String) -> TaskPhase {
        switch eventName {
        case "SessionStart", "UserPromptSubmit": return .starting
        case "PreToolUse": return .usingTool
        case "PostToolUse": return .working
        case "PermissionRequest": return .waitingApproval
        case "Stop", "SubagentStop": return .completed
        case "SessionEnd": return .ended
        default: return .working
        }
    }

    static func task(from event: HookEvent) -> MonitoredTask {
        let url = URL(fileURLWithPath: event.cwd)
        let name = url.lastPathComponent.isEmpty ? event.cwd : url.lastPathComponent
        return MonitoredTask(
            id: event.sessionID,
            turnID: event.turnID,
            projectName: name,
            projectPath: event.cwd,
            model: event.model,
            toolName: event.toolName,
            phase: phase(for: event.hookEventName),
            updatedAt: event.receivedAt
        )
    }
}

extension Date {
    var compactRelativeText: String {
        let seconds = max(0, Int(Date().timeIntervalSince(self)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3_600) 小时前" }
        return "\(seconds / 86_400) 天前"
    }
}
