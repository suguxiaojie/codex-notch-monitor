import Foundation
import SwiftUI

enum IslandPanelLayout {
    static let expandedWidth: CGFloat = 430
    /// Fits the normal maximum Usage composition (project card, three live
    /// actions, and two quota buckets) without requiring an initial scroll.
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
