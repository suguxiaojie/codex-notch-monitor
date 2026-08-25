import Foundation

enum TokenActivityLayout {
    static let columnCount = 16

    static func placeholderCount(for dayCount: Int) -> Int {
        guard dayCount > 0 else { return 0 }
        return (columnCount - dayCount % columnCount) % columnCount
    }

    static func rowCount(for dayCount: Int) -> Int {
        guard dayCount > 0 else { return 0 }
        return (dayCount + placeholderCount(for: dayCount)) / columnCount
    }
}

enum CostActivityScale {
    static func level(dollars: Double, maximum: Double) -> Int {
        guard dollars > 0, maximum > 0 else { return 0 }
        let ratio = dollars / maximum
        if ratio < 0.25 { return 1 }
        if ratio < 0.50 { return 2 }
        if ratio < 0.75 { return 3 }
        return 4
    }
}

enum CostActivityBucketLayout {
    static func groupSize(for rangeDays: Int) -> Int {
        switch rangeDays {
        case 7: return 1
        case 30: return 1
        case 90: return 3
        case 180: return 7
        default: return max(1, rangeDays)
        }
    }

    static func ranges(dayCount: Int, rangeDays: Int) -> [Range<Int>] {
        guard dayCount > 0 else { return [] }
        let size = groupSize(for: rangeDays)
        return stride(from: 0, to: dayCount, by: size).map { start in
            start..<min(dayCount, start + size)
        }
    }
}
