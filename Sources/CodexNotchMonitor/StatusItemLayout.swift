import Foundation

struct StatusItemLayout: Equatable {
    let title: String
    let width: Double

    /// Quota is a stable visual prefix beside its ring. Task content compacts
    /// independently, while quota and status survive every textual level.
    static func taskTitles(status: String, project: String, projectCount: Int,
                           token: String?, quota: String?) -> [String] {
        let others = projectCount > 1 ? " ＋\(projectCount - 1)" : ""
        let identity = project + others
        func joined(_ parts: [String?]) -> String {
            parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if projectCount > 1 {
            return [
                joined([quota, status, identity, token]),
                joined([quota, status, identity]),
                joined([quota, status, token]),
                joined([quota, status + others])
            ]
        }
        return [
            joined([quota, status, identity, token]),
            joined([quota, status, token]),
            joined([quota, status, identity]),
            joined([quota, status])
        ]
    }

    /// A stable reservation based on screen geometry, never the item's moving frame.
    static func budget(menuRegionWidth: Double?, detailed: Bool = false) -> Double {
        guard let width = menuRegionWidth, width.isFinite, width > 0 else { return 120 }
        return max(32, min(detailed ? 420 : 240, width * (detailed ? 0.5 : 0.25)))
    }

    static func projectTitle(status: String, project: String, suffix: String = "",
                             budget: Double, measure: (String) -> Double) -> String? {
        let prefix = status + " · "
        let available = budget - 36 - measure(prefix + suffix)
        let name = truncated(project, width: available, measure: measure)
        guard !name.isEmpty else { return nil }
        return prefix + name + suffix
    }

    static func truncated(_ text: String, width: Double, measure: (String) -> Double) -> String {
        if measure(text) <= width { return text }
        let characters = Array(text)
        var low = 0
        var high = max(0, characters.count - 1)
        while low < high {
            let middle = (low + high + 1) / 2
            if measure(String(characters.prefix(middle)) + "…") <= width { low = middle }
            else { high = middle - 1 }
        }
        guard low > 0 else { return "" }
        return String(characters.prefix(low)) + "…"
    }

    static func resolve(candidates: [String], budget: Double,
                        measure: (String) -> Double) -> Self {
        for title in candidates where !title.isEmpty {
            let width = ceil(measure(title)) + 36 // icon, gap and edge padding
            if width.isFinite, width <= budget {
                return Self(title: title, width: max(32, width))
            }
        }
        return Self(title: "", width: 32)
    }
}

struct StatusItemRotation {
    private(set) var index = 0
    private(set) var pages: [String] = []
    private var identity = ""

    @discardableResult
    mutating func configure(identity: String, pages: [String]) -> Bool {
        let changed = self.identity != identity || self.pages.count != pages.count
        if changed { index = 0 }
        self.identity = identity
        self.pages = pages
        return changed
    }

    mutating func advance(hovered: Bool) -> Bool {
        guard !hovered, pages.count > 1 else { return false }
        index = (index + 1) % pages.count
        return true
    }

    var title: String? { pages.indices.contains(index) ? pages[index] : nil }

    static func fittingPages(_ pages: [String], budget: Double, measure: (String) -> Double) -> [String] {
        var result: [String] = []
        for page in pages where !page.isEmpty && !result.contains(page) {
            if StatusItemLayout.resolve(candidates: [page], budget: budget, measure: measure).title == page {
                result.append(page)
            }
        }
        return result.count > 1 ? result : []
    }
}

/// ControlCenter can move other items after a title is submitted. Retain a
/// smaller capacity once real occlusion is observed; numeric updates must not
/// immediately expand back into the same failed layout.
struct StatusItemCapacity {
    static let recoveryInterval: TimeInterval = 8
    static let failedRecoveryInterval: TimeInterval = 120

    private var context = ""
    private var ceiling: Double?
    private var nextRecoveryAt: Date?
    private var lastVisibleLimit: Double?
    private var isProbingRecovery = false
    private(set) var limit: Double?

    mutating func constrain(_ proposed: Double, context: String) -> Double {
        if self.context != context {
            self.context = context
            limit = nil
            nextRecoveryAt = nil
            lastVisibleLimit = nil
            isProbingRecovery = false
        }
        ceiling = proposed
        if let limit, limit > proposed {
            self.limit = proposed
            lastVisibleLimit = min(lastVisibleLimit ?? proposed, proposed)
        }
        return min(proposed, limit ?? proposed)
    }

    mutating func observe(
        width: Double,
        onMenuBar: Bool,
        occluded: Bool,
        now: Date = Date()
    ) -> Bool {
        guard onMenuBar, width.isFinite, width > 32 else { return false }
        if occluded {
            if isProbingRecovery, let lastVisibleLimit {
                limit = lastVisibleLimit
                isProbingRecovery = false
                nextRecoveryAt = now.addingTimeInterval(Self.failedRecoveryInterval)
                return true
            }
            let next = max(32, width - max(24, width * 0.25))
            guard next < (limit ?? .infinity) else { return false }
            limit = next
            lastVisibleLimit = nil
            isProbingRecovery = false
            nextRecoveryAt = now.addingTimeInterval(Self.recoveryInterval)
            return true
        }
        if isProbingRecovery {
            isProbingRecovery = false
            lastVisibleLimit = limit
            if let limit, let ceiling, limit >= ceiling {
                self.limit = nil
                self.lastVisibleLimit = nil
                nextRecoveryAt = nil
            } else {
                nextRecoveryAt = now.addingTimeInterval(Self.recoveryInterval)
            }
            return false
        }
        guard let limit, let ceiling, limit < ceiling,
              let nextRecoveryAt, now >= nextRecoveryAt
        else { return false }
        let next = min(ceiling, limit + max(24, ceiling * 0.12))
        lastVisibleLimit = limit
        self.limit = next
        isProbingRecovery = true
        self.nextRecoveryAt = nil
        return true
    }

    mutating func reconsiderRecovery(now: Date = Date()) {
        guard limit != nil, !isProbingRecovery else { return }
        nextRecoveryAt = now
    }

    func recoveryDelay(after now: Date = Date()) -> TimeInterval? {
        guard limit != nil, let nextRecoveryAt else { return nil }
        return max(0, nextRecoveryAt.timeIntervalSince(now))
    }
}
