import Foundation

struct StatusItemLayout: Equatable {
    let title: String
    let width: Double

    /// Ordered by meaning: drop quota, then token usage, then project identity.
    /// Status survives every textual level; an icon is the final fallback.
    static func taskTitles(status: String, project: String, projectCount: Int,
                           token: String?, quota: String?) -> [String] {
        let others = projectCount > 1 ? " ＋\(projectCount - 1)" : ""
        let identity = project + others
        let shortIdentity = identity
        func joined(_ parts: [String?]) -> String {
            parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return [
            joined([status, identity, token, quota]),
            joined([status, projectCount > 1 ? shortIdentity : nil, token]),
            joined([status, projectCount > 1 ? shortIdentity : nil]),
            status + others
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
    private var context = ""
    private(set) var limit: Double?

    mutating func constrain(_ proposed: Double, context: String) -> Double {
        if self.context != context {
            self.context = context
            limit = nil
        }
        return min(proposed, limit ?? proposed)
    }

    mutating func observe(width: Double, onMenuBar: Bool, occluded: Bool) -> Bool {
        guard onMenuBar, occluded, width.isFinite, width > 32 else { return false }
        let next = max(32, width - max(24, width * 0.25))
        guard next < (limit ?? .infinity) else { return false }
        limit = next
        return true
    }
}
