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

enum ActivityHeatmapScale {
    static func level(value: Double, maximum: Double) -> Int {
        guard value > 0, maximum > 0 else { return 0 }
        let ratio = value / maximum
        if ratio < 0.25 { return 1 }
        if ratio < 0.50 { return 2 }
        if ratio < 0.75 { return 3 }
        return 4
    }
}

enum ActivityHeatmapPalette {
    static func opacity(for level: Int) -> Double {
        switch level {
        case 0: return 0.12
        case 1: return 0.28
        case 2: return 0.44
        case 3: return 0.62
        default: return 0.82
        }
    }
}

enum CostActivityScale {
    static func level(dollars: Double, maximum: Double) -> Int {
        ActivityHeatmapScale.level(value: dollars, maximum: maximum)
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
