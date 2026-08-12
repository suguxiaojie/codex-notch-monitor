import Foundation

enum CostProvider: String, CaseIterable {
    case codex = "Codex"
}

struct CostTotals: Equatable {
    var dollars: Double = 0
    var tokens: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheTokens: Int = 0
    var series: [Double] = []
}

enum UsagePeriod: String, CaseIterable, Identifiable {
    case day = "日"
    case week = "周"
    case month = "月"

    var id: String { rawValue }
}

struct ProjectUsage: Identifiable, Equatable {
    var id: String { path }
    let name: String
    let path: String
    var tokens: Int
    var sessionCount: Int
}

struct UsageTotals: Equatable {
    var tokens: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheTokens: Int = 0
    var sessionCount: Int = 0
    var projectCount: Int = 0
    var series: [Double] = []
    var projects: [ProjectUsage] = []
}

struct UsageSnapshot: Equatable {
    var day: UsageTotals
    var week: UsageTotals
    var month: UsageTotals

    func totals(for period: UsagePeriod) -> UsageTotals {
        switch period {
        case .day: return day
        case .week: return week
        case .month: return month
        }
    }

    static let empty = UsageSnapshot(
        day: UsageTotals(series: Array(repeating: 0, count: 24)),
        week: UsageTotals(series: Array(repeating: 0, count: 7)),
        month: UsageTotals(series: [])
    )
}

struct ProviderCostTotals: Identifiable, Equatable {
    var id: String { provider.rawValue }
    let provider: CostProvider
    var today: CostTotals
    var month: CostTotals
}

struct CostSnapshot: Equatable {
    var today: CostTotals
    var month: CostTotals
    var providers: [ProviderCostTotals]
    var unknownModels: [String]
    var estimatedModelAliases: [String: String]
    var usage: UsageSnapshot
    var updatedAt: Date

    static let empty = CostSnapshot(
        today: CostTotals(series: Array(repeating: 0, count: 24)),
        month: CostTotals(series: []),
        providers: CostProvider.allCases.map {
            ProviderCostTotals(provider: $0, today: CostTotals(), month: CostTotals())
        },
        unknownModels: [],
        estimatedModelAliases: [:],
        usage: .empty,
        updatedAt: .distantPast
    )
}

private struct TokenUsageEvent {
    let provider: CostProvider
    let timestamp: Date
    let model: String
    let sessionID: String
    let projectPath: String
    let input: Int
    let output: Int
    let cacheCreate: Int
    let cacheRead: Int

    func withProjectPath(_ value: String) -> TokenUsageEvent {
        TokenUsageEvent(
            provider: provider,
            timestamp: timestamp,
            model: model,
            sessionID: sessionID,
            projectPath: URL(fileURLWithPath: value).standardizedFileURL.path,
            input: input,
            output: output,
            cacheCreate: cacheCreate,
            cacheRead: cacheRead
        )
    }
}

final class CostService {
    private let queue = DispatchQueue(label: "CodexNotchMonitor.Cost", qos: .utility)

    init() {
        PricingCatalog.prepare()
    }

    func fetch(
        sessionPathOverrides: [String: String] = [:],
        completion: @escaping (CostSnapshot) -> Void
    ) {
        queue.async {
            let scanned = Self.scanCodex()
            var pathAliases: [String: String] = [:]
            for event in scanned {
                guard let override = sessionPathOverrides[event.sessionID], !override.isEmpty else { continue }
                let normalized = URL(fileURLWithPath: override).standardizedFileURL.path
                if normalized != event.projectPath { pathAliases[event.projectPath] = normalized }
            }
            let events = scanned.map { event in
                if let override = sessionPathOverrides[event.sessionID], !override.isEmpty {
                    return event.withProjectPath(override)
                }
                if let alias = pathAliases[event.projectPath] {
                    return event.withProjectPath(alias)
                }
                return event
            }
            let projectNames = Self.readCodexProjectNames()
            let snapshot = Self.summarize(events, projectNames: projectNames)
            DispatchQueue.main.async { completion(snapshot) }

            // The first result is deliberately local and immediate. Refresh
            // public pricing in the background, then recalculate only when a
            // new catalog was actually installed.
            Task {
                guard await PricingCatalog.refreshIfNeeded() == .updated else { return }
                self.queue.async {
                    let refreshed = Self.summarize(events, projectNames: projectNames)
                    DispatchQueue.main.async { completion(refreshed) }
                }
            }
        }
    }

    private static func scanCodex() -> [TokenUsageEvent] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
        let calendar = Calendar.current
        let now = Date()
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let weekStart = startOfWeek(containing: now, calendar: calendar)
        let roots = Set([monthStart, weekStart].compactMap { date -> String? in
            let parts = calendar.dateComponents([.year, .month], from: date)
            guard let year = parts.year, let month = parts.month else { return nil }
            return root
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .path
        })
        return roots.flatMap { jsonlFiles(in: URL(fileURLWithPath: $0, isDirectory: true)) }
            .flatMap(parseCodexFile)
    }

    private static func parseCodexFile(_ url: URL) -> [TokenUsageEvent] {
        var model = "gpt-5.4"
        var sessionID = url.deletingPathExtension().lastPathComponent
        var projectPath = "未归类"
        var result: [TokenUsageEvent] = []
        relevantLines(at: url) { row in
            guard let object = try? JSONSerialization.jsonObject(with: row) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any]
            else { return }
            if type == "turn_context", let nextModel = payload["model"] as? String {
                model = nextModel
                return
            }
            if type == "session_meta" {
                sessionID = (payload["session_id"] as? String)
                    ?? (payload["id"] as? String)
                    ?? sessionID
                projectPath = (payload["cwd"] as? String) ?? projectPath
                return
            }
            guard type == "event_msg",
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["last_token_usage"] as? [String: Any],
                  let timestamp = parseDate(object["timestamp"] as? String)
            else { return }
            let totalInput = integer(usage["input_tokens"])
            let cached = integer(usage["cached_input_tokens"])
            let output = integer(usage["output_tokens"])
            guard totalInput + output > 0 else { return }
            result.append(TokenUsageEvent(
                provider: .codex,
                timestamp: timestamp,
                model: model,
                sessionID: sessionID,
                projectPath: projectPath,
                input: max(0, totalInput - cached),
                output: output,
                cacheCreate: integer(usage["cache_write_input_tokens"]),
                cacheRead: cached
            ))
        }
        return result
    }

    private static func relevantLines(at url: URL, body: (Data) -> Void) {
        if let filtered = ripgrepRelevantLines(at: url) {
            for row in filtered.split(separator: 0x0A) where row.count <= 1 << 20 {
                body(Data(row))
            }
            return
        }

        guard let mapped = try? Data(contentsOf: url, options: [.mappedIfSafe]), !mapped.isEmpty else { return }
        let markers = [
            Data(#""type":"session_meta""#.utf8),
            Data(#""type":"turn_context""#.utf8),
            Data(#""type":"token_count""#.utf8),
        ]
        let newline = Data([0x0A])
        let maximumLineBytes = 1 << 20
        var cursor = mapped.startIndex
        while cursor < mapped.endIndex {
            let searchRange = cursor..<mapped.endIndex
            let hits = markers.compactMap {
                mapped.range(of: $0, in: searchRange)?.lowerBound
            }
            guard let hit = hits.min() else { break }
            let before = mapped.startIndex..<hit
            let lineStart = mapped.range(of: newline, options: .backwards, in: before)?.upperBound
                ?? mapped.startIndex
            let lineEnd = mapped.range(of: newline, in: hit..<mapped.endIndex)?.lowerBound
                ?? mapped.endIndex
            if lineEnd - lineStart <= maximumLineBytes {
                body(Data(mapped[lineStart..<lineEnd]))
            }
            cursor = lineEnd < mapped.endIndex ? mapped.index(after: lineEnd) : mapped.endIndex
        }
    }

    /// Codex Desktop already bundles ripgrep. Its SIMD byte search reduces a
    /// multi-gigabyte rollout to only the few megabytes of structural records
    /// we need. The pure-Swift mapped-file path above remains the fallback.
    private static func ripgrepRelevantLines(at url: URL) -> Data? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/rg",
            "/Applications/Codex.app/Contents/Resources/rg",
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [
            "-a", "--no-messages", "--max-columns", "1048576",
            #""type":"(session_meta|turn_context|token_count)""#,
            url.path,
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 || process.terminationStatus == 1 ? data : nil
        } catch {
            return nil
        }
    }

    private static func jsonlFiles(in root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { return nil }
            return url
        }
    }

    /// Codex sidebar project names are user-editable aliases whose filesystem
    /// roots remain unchanged. Read the app's local state without mutating it,
    /// and key aliases by standardized full path so Usage identity is stable.
    private static func readCodexProjectNames() -> [String: String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/.codex-global-state.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["local-projects"] as? [String: Any]
        else { return [:] }
        var result: [String: String] = [:]
        for value in projects.values {
            guard let project = value as? [String: Any],
                  let name = project["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let roots = project["rootPaths"] as? [String]
            else { continue }
            for root in roots where !root.isEmpty {
                result[URL(fileURLWithPath: root).standardizedFileURL.path] = name
            }
        }
        return result
    }

    private static func summarize(
        _ events: [TokenUsageEvent],
        projectNames: [String: String]
    ) -> CostSnapshot {
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? todayStart
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 31
        var today = CostTotals(series: Array(repeating: 0, count: 24))
        var month = CostTotals(series: Array(repeating: 0, count: daysInMonth))
        var providerTotals = Dictionary(uniqueKeysWithValues: CostProvider.allCases.map {
            ($0, ProviderCostTotals(provider: $0, today: CostTotals(), month: CostTotals()))
        })
        var unknown = Set<String>()
        var estimatedAliases: [String: String] = [:]
        let orderedEvents = events.sorted { $0.timestamp < $1.timestamp }
        // If the month begins with an internal task, the first normal model is
        // still a better fallback than pretending the internal route has its
        // own public price.
        var currentPrimaryModel = orderedEvents.first(where: {
            !ModelPricing.isInternalAutomaticModel($0.model) &&
            ModelPricing.resolvedRates(for: $0.model) != nil
        })?.model

        for event in orderedEvents where event.timestamp >= monthStart {
            if !ModelPricing.isInternalAutomaticModel(event.model),
               ModelPricing.resolvedRates(for: event.model) != nil {
                currentPrimaryModel = event.model
            }
            let billingModel = ModelPricing.billingModel(
                for: event.model,
                currentPrimaryModel: currentPrimaryModel
            )
            if billingModel != event.model {
                estimatedAliases[event.model] = billingModel
            }
            let cost = estimatedCost(event, billingModel: billingModel)
            if cost == nil { unknown.insert(event.model) }
            add(event, cost: cost ?? 0, to: &month)
            if let day = calendar.dateComponents([.day], from: event.timestamp).day,
               month.series.indices.contains(day - 1) {
                month.series[day - 1] += cost ?? 0
            }
            if var item = providerTotals[event.provider] {
                add(event, cost: cost ?? 0, to: &item.month)
                if event.timestamp >= todayStart { add(event, cost: cost ?? 0, to: &item.today) }
                providerTotals[event.provider] = item
            }
            if event.timestamp >= todayStart {
                add(event, cost: cost ?? 0, to: &today)
                let hour = calendar.component(.hour, from: event.timestamp)
                if today.series.indices.contains(hour) { today.series[hour] += cost ?? 0 }
            }
        }
        today.series = cumulative(today.series)
        month.series = cumulative(month.series)
        return CostSnapshot(
            today: today,
            month: month,
            providers: CostProvider.allCases.compactMap { providerTotals[$0] },
            unknownModels: unknown.sorted(),
            estimatedModelAliases: estimatedAliases,
            usage: summarizeUsage(events, now: now, calendar: calendar, projectNames: projectNames),
            updatedAt: now
        )
    }

    private static func summarizeUsage(
        _ events: [TokenUsageEvent],
        now: Date,
        calendar: Calendar,
        projectNames: [String: String]
    ) -> UsageSnapshot {
        let todayStart = calendar.startOfDay(for: now)
        let weekStart = startOfWeek(containing: now, calendar: calendar)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? todayStart
        let daysInMonth = calendar.range(of: .day, in: .month, for: now)?.count ?? 31
        return UsageSnapshot(
            day: usageTotals(events, from: todayStart, seriesCount: 24, projectNames: projectNames) { event in
                calendar.component(.hour, from: event.timestamp)
            },
            week: usageTotals(events, from: weekStart, seriesCount: 7, projectNames: projectNames) { event in
                max(0, min(6, calendar.dateComponents([.day], from: weekStart, to: event.timestamp).day ?? 0))
            },
            month: usageTotals(events, from: monthStart, seriesCount: daysInMonth, projectNames: projectNames) { event in
                max(0, (calendar.component(.day, from: event.timestamp)) - 1)
            }
        )
    }

    private static func usageTotals(
        _ events: [TokenUsageEvent],
        from start: Date,
        seriesCount: Int,
        projectNames: [String: String],
        bucket: (TokenUsageEvent) -> Int
    ) -> UsageTotals {
        let filtered = events.filter { $0.timestamp >= start }
        var result = UsageTotals(series: Array(repeating: 0, count: seriesCount))
        var sessions = Set<String>()
        var projectSessions: [String: Set<String>] = [:]
        var projectTokens: [String: Int] = [:]
        for event in filtered {
            let cache = event.cacheCreate + event.cacheRead
            let total = event.input + event.output + cache
            result.tokens += total
            result.inputTokens += event.input
            result.outputTokens += event.output
            result.cacheTokens += cache
            sessions.insert(event.sessionID)
            projectSessions[event.projectPath, default: []].insert(event.sessionID)
            projectTokens[event.projectPath, default: 0] += total
            let index = bucket(event)
            if result.series.indices.contains(index) { result.series[index] += Double(total) }
        }
        result.sessionCount = sessions.count
        result.projectCount = projectTokens.count
        result.projects = projectTokens.map { path, tokens in
            let url = URL(fileURLWithPath: path)
            let fallbackName = path == "未归类" ? path : (url.lastPathComponent.isEmpty ? path : url.lastPathComponent)
            return ProjectUsage(
                name: projectNames[path] ?? fallbackName,
                path: path,
                tokens: tokens,
                sessionCount: projectSessions[path]?.count ?? 0
            )
        }.sorted {
            $0.tokens == $1.tokens ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.tokens > $1.tokens
        }
        return result
    }

    private static func startOfWeek(containing date: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: day) ?? day
    }

    private static func add(_ event: TokenUsageEvent, cost: Double, to total: inout CostTotals) {
        total.dollars += cost
        total.inputTokens += event.input
        total.outputTokens += event.output
        total.cacheTokens += event.cacheCreate + event.cacheRead
        total.tokens += event.input + event.output + event.cacheCreate + event.cacheRead
    }

    private static func estimatedCost(_ event: TokenUsageEvent, billingModel: String) -> Double? {
        guard let rate = ModelPricing.resolvedRates(for: billingModel) else { return nil }
        return (Double(event.input) * rate.inputPerMillion +
                Double(event.output) * rate.outputPerMillion +
                Double(event.cacheCreate) * rate.cacheCreationPerMillion +
                Double(event.cacheRead) * rate.cacheReadPerMillion) / 1_000_000
    }

    private static func cumulative(_ values: [Double]) -> [Double] {
        var total = 0.0
        return values.map { total += $0; return total }
    }

    private static func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return 0
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
