import Foundation
import CoreFoundation

/// Pure rollout projection. Cumulative totals already include cached input and
/// reasoning output; adding those breakdowns again would double count usage.
struct TurnTokenState: Equatable {
    private(set) var turnID: String?
    private(set) var total: Int?
    private(set) var isCompleted = false
    private var cumulative: Int?
    private var baseline: Int?
    private var sawStart = false
    private var invalidated = false
    private var pendingStart = false

    mutating func consume(type: String, payload: [String: Any]) {
        if type == "turn_context" {
            begin(payload["turn_id"] as? String, explicit: false)
            return
        }
        guard type == "event_msg" else { return }
        switch payload["type"] as? String {
        case "task_started":
            if payload["turn_id"] as? String == nil { pendingStart = true }
            begin(payload["turn_id"] as? String, explicit: true)
        case "token_count":
            guard let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any],
                  let value = Self.count(usage["total_tokens"])
            else { return }
            if let eventTurn = payload["turn_id"] as? String, eventTurn != turnID { return }
            if let previous = cumulative, value < previous {
                invalidated = true
                baseline = nil
                total = nil
            }
            // A complete first request proves a zero baseline. A tail that starts
            // mid-turn cannot make that claim and remains explicitly unknown.
            if baseline == nil, !invalidated, sawStart,
               let last = info["last_token_usage"] as? [String: Any],
               Self.count(last["total_tokens"]) == value {
                baseline = 0
            }
            cumulative = value
            if turnID != nil, !invalidated, let baseline, value >= baseline {
                total = value - baseline
            }
        case "task_complete":
            if let id = payload["turn_id"] as? String, id == turnID { isCompleted = true }
        case "turn_aborted":
            isCompleted = false
        default: break
        }
    }

    private mutating func begin(_ id: String?, explicit: Bool) {
        guard let id, !id.isEmpty else { return }
        if id == turnID {
            sawStart = sawStart || explicit
            return
        }
        baseline = (explicit || pendingStart || turnID != nil) ? cumulative : nil
        turnID = id
        isCompleted = false
        total = nil
        sawStart = explicit || pendingStart
        pendingStart = false
        invalidated = false
    }

    private static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue >= 0,
              number.doubleValue < Double(Int.max),
              number.doubleValue.rounded(.down) == number.doubleValue
        else { return nil }
        return number.intValue
    }
}

struct TurnTokenUsage: Equatable {
    let sessionID: String
    let turnID: String
    let total: Int?
    var isCompleted = false

    var label: String {
        guard let total else { return "本轮 Token · 统计不完整" }
        return "本轮 \(MenuBarTokenFormatter.shortCount(total)) Token"
    }
}

enum MenuBarTokenFormatter {
    static func shortCount(_ total: Int) -> String {
        let value = max(0, total)
        if value >= 999_950_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 999_950 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value == 0 { return "0K" }
        if value < 50 { return "<0.1K" }
        return String(format: "%.1fK", Double(value) / 1_000)
    }

    static func title(status: String, project: String?, usage: TurnTokenUsage?, quota: Int?, projectCount: Int = 1) -> String {
        var parts = [quota.map { "\($0)%" } ?? "--", status]
        if let project { parts.append(project) }
        if projectCount > 1 { parts.append("＋\(projectCount - 1)个项目") }
        if let total = usage?.total { parts.append("本轮 \(shortCount(total)) Token") }
        return parts.joined(separator: " · ")
    }
}

struct MenuBarTokenReceipt {
    private var identity: String?
    private(set) var expiresAt: Date?

    mutating func resolve(usage: TurnTokenUsage, now: Date) -> Bool {
        guard usage.isCompleted else { return false }
        let key = usage.sessionID + "/" + usage.turnID
        if key != identity {
            identity = key
            expiresAt = now.addingTimeInterval(6)
        }
        return now < (expiresAt ?? .distantPast)
    }
}
