import Foundation

enum TiboEventKind: String, Codable, Equatable {
    case resetCompleted = "reset_completed"
    case resetScheduled = "reset_scheduled"
    case bankedReset = "banked_reset"
    case limitIncrease = "limit_increase"
    case uncertain
}

struct TiboFeedMonitor: Codable, Equatable {
    let status: String
    let errorCode: String?
}

struct TiboEventSource: Codable, Equatable {
    let handle: String
    let postId: String
    let url: String
}

struct TiboEventScope: Codable, Equatable {
    let plans: [String]
    let windows: [String]
}

struct TiboEvent: Codable, Identifiable, Equatable {
    var id: String { source.postId }

    let kind: TiboEventKind
    let announcedAt: String
    let effectiveAt: String?
    let scope: TiboEventScope
    let source: TiboEventSource
    let confidence: Double
    let rationale: String
    let text: String

    var announcedDate: Date? { TiboFeedDate.parse(announcedAt) }
    var effectiveDate: Date? { effectiveAt.flatMap(TiboFeedDate.parse) }
}

struct TiboResetWindow: Codable, Equatable {
    let startAt: String?
    let endAt: String?
    let precision: String?
}

struct TiboNextSchedule: Codable, Equatable {
    let event: TiboEvent
    let window: TiboResetWindow?
}

struct TiboFulfilledSchedule: Codable, Equatable {
    let schedule: TiboEvent
    let window: TiboResetWindow?
    let completionPostId: String?
    let completedAt: String?
    let visibleUntil: String?
}

struct TiboManualCompletion: Codable, Equatable {
    let id: String
    let completedAt: String
    let visibleUntil: String?
    let representativePostId: String?
    let schedulePostIds: [String]?
    let schedules: [TiboEvent]
    let fulfillmentOrigin: String?

    var completedDate: Date? { TiboFeedDate.parse(completedAt) }
    var visibleUntilDate: Date? { visibleUntil.flatMap(TiboFeedDate.parse) }
}

struct TiboResetTimeline: Codable, Equatable {
    let nextSchedule: TiboNextSchedule?
    let recentNonCompletedPostId: String?
    let fulfilledSchedules: [TiboFulfilledSchedule]
    let manualCompletions: [TiboManualCompletion]
    let suppressedPostIds: [String]

    init(
        nextSchedule: TiboNextSchedule? = nil,
        recentNonCompletedPostId: String? = nil,
        fulfilledSchedules: [TiboFulfilledSchedule] = [],
        manualCompletions: [TiboManualCompletion] = [],
        suppressedPostIds: [String] = []
    ) {
        self.nextSchedule = nextSchedule
        self.recentNonCompletedPostId = recentNonCompletedPostId
        self.fulfilledSchedules = fulfilledSchedules
        self.manualCompletions = manualCompletions
        self.suppressedPostIds = suppressedPostIds
    }

    private enum CodingKeys: String, CodingKey {
        case nextSchedule, recentNonCompletedPostId, fulfilledSchedules
        case manualCompletions, suppressedPostIds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        nextSchedule = try values.decodeIfPresent(TiboNextSchedule.self, forKey: .nextSchedule)
        recentNonCompletedPostId = try values.decodeIfPresent(String.self, forKey: .recentNonCompletedPostId)
        fulfilledSchedules = try values.decodeIfPresent([TiboFulfilledSchedule].self, forKey: .fulfilledSchedules) ?? []
        manualCompletions = try values.decodeIfPresent([TiboManualCompletion].self, forKey: .manualCompletions) ?? []
        suppressedPostIds = try values.decodeIfPresent([String].self, forKey: .suppressedPostIds) ?? []
    }
}

struct TiboDisplayEvent: Identifiable, Equatable {
    let id: String
    let event: TiboEvent
    let isManualCompletion: Bool
    let supportingSchedules: [TiboEvent]
}

struct TiboFeed: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: String
    let lastSuccessfulCheckAt: String?
    let monitor: TiboFeedMonitor
    let events: [TiboEvent]
    let resetTimeline: TiboResetTimeline?

    init(
        schemaVersion: Int,
        generatedAt: String,
        lastSuccessfulCheckAt: String?,
        monitor: TiboFeedMonitor,
        events: [TiboEvent],
        resetTimeline: TiboResetTimeline? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.lastSuccessfulCheckAt = lastSuccessfulCheckAt
        self.monitor = monitor
        self.events = events
        self.resetTimeline = resetTimeline
    }

    var generatedDate: Date? { TiboFeedDate.parse(generatedAt) }
    var lastSuccessfulCheckDate: Date? { lastSuccessfulCheckAt.flatMap(TiboFeedDate.parse) }

    func displayEvents(now: Date = Date()) -> [TiboDisplayEvent] {
        let suppressed = Set(resetTimeline?.suppressedPostIds ?? [])
        var result: [TiboDisplayEvent] = []

        for manual in resetTimeline?.manualCompletions ?? [] {
            guard let completed = manual.completedDate,
                  completed <= now,
                  manual.visibleUntilDate.map({ now <= $0 }) ?? true,
                  let representative = manual.schedules.first(where: {
                      $0.source.postId == manual.representativePostId
                  }) ?? manual.schedules.first
            else { continue }
            let event = TiboEvent(
                kind: .resetCompleted,
                announcedAt: manual.completedAt,
                effectiveAt: manual.completedAt,
                scope: representative.scope,
                source: representative.source,
                confidence: representative.confidence,
                rationale: "Confirmed without an X completion post.",
                text: representative.text
            )
            result.append(TiboDisplayEvent(
                id: manual.id,
                event: event,
                isManualCompletion: true,
                supportingSchedules: manual.schedules
            ))
        }

        var ordinary = events.filter { !suppressed.contains($0.source.postId) }
        if let next = resetTimeline?.nextSchedule?.event,
           !suppressed.contains(next.source.postId),
           !ordinary.contains(where: { $0.source.postId == next.source.postId }) {
            ordinary.append(next)
        }
        for event in ordinary {
            let supporting = (resetTimeline?.fulfilledSchedules ?? [])
                .filter { $0.completionPostId == event.source.postId }
                .map(\.schedule)
            result.append(TiboDisplayEvent(
                id: "event:\(event.source.postId)",
                event: event,
                isManualCompletion: false,
                supportingSchedules: supporting
            ))
        }

        var seen = Set<String>()
        return result
            .sorted { lhs, rhs in
                let leftFuture = lhs.event.kind == .resetScheduled
                    && (lhs.event.effectiveDate ?? .distantPast) > now
                let rightFuture = rhs.event.kind == .resetScheduled
                    && (rhs.event.effectiveDate ?? .distantPast) > now
                if leftFuture != rightFuture { return leftFuture }
                if leftFuture, rightFuture {
                    return (lhs.event.effectiveDate ?? .distantFuture)
                        < (rhs.event.effectiveDate ?? .distantFuture)
                }
                return (lhs.event.announcedDate ?? .distantPast)
                    > (rhs.event.announcedDate ?? .distantPast)
            }
            .filter { seen.insert($0.id).inserted }
    }

    func officialEvidenceEvents(now: Date = Date()) -> [TiboEvent] {
        displayEvents(now: now).map(\.event)
    }
}

enum TiboFeedDate {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let ordinary: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        fractional.date(from: value) ?? ordinary.date(from: value)
    }
}

enum TiboFeedInterpretation: Equatable {
    case feed(TiboFeed)
    case unchanged
    case rejected(String)
}

enum TiboFeedError: LocalizedError {
    case invalidResponse
    case notModifiedWithoutCache
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "动态服务返回了无效响应"
        case .notModifiedWithoutCache: return "动态服务没有返回可用内容"
        case let .rejected(reason): return "动态数据不可用：\(reason)"
        }
    }
}

final class TiboFeedService {
    static let endpoint = URL(string: "https://www.codexrunway.com/api/status.json")!
    static let refreshInterval: TimeInterval = 30 * 60
    static let staleInterval: TimeInterval = 3 * 60 * 60
    static let supportedSchemaVersion = 1
    static let maximumPayloadSize = 1 * 1_024 * 1_024

    private struct Cache: Codable {
        let feed: TiboFeed
        let etag: String?
        let lastModified: String?
        let fetchedAt: Date
    }

    private let session: URLSession
    private let cacheURL: URL
    private let lock = NSLock()
    private var cache: Cache?

    init(
        session: URLSession = .shared,
        cacheURL: URL = AppPaths.supportDirectory.appendingPathComponent("tibo-feed.json")
    ) {
        self.session = session
        self.cacheURL = cacheURL
        self.cache = Self.loadCache(from: cacheURL)
    }

    var cachedFeed: TiboFeed? {
        lock.withLock { cache?.feed }
    }

    var cachedAt: Date? {
        lock.withLock { cache?.fetchedAt }
    }

    static func interpret(status: Int, data: Data) -> TiboFeedInterpretation {
        if status == 304 { return .unchanged }
        guard status == 200 else { return .rejected("HTTP \(status)") }
        guard data.count <= maximumPayloadSize else { return .rejected("响应过大") }
        guard let feed = try? JSONDecoder().decode(TiboFeed.self, from: data) else {
            return .rejected("JSON 格式错误")
        }
        guard feed.schemaVersion == supportedSchemaVersion else {
            return .rejected("不支持的 schemaVersion \(feed.schemaVersion)")
        }
        guard feed.generatedDate != nil else { return .rejected("generatedAt 无效") }
        guard ["ok", "degraded", "error"].contains(feed.monitor.status) else {
            return .rejected("监控状态无效")
        }
        guard feed.events.count <= 100 else { return .rejected("事件数量异常") }
        guard feed.events.allSatisfy(isValid) else { return .rejected("事件来源校验失败") }
        if let timeline = feed.resetTimeline {
            let timelineEvents = timeline.fulfilledSchedules.map(\.schedule)
                + timeline.manualCompletions.flatMap(\.schedules)
                + [timeline.nextSchedule?.event].compactMap { $0 }
            guard timeline.manualCompletions.count <= 100,
                  timelineEvents.count <= 300,
                  timelineEvents.allSatisfy(isValid),
                  timeline.manualCompletions.allSatisfy({ $0.completedDate != nil })
            else { return .rejected("重置时间线校验失败") }
        }
        return .feed(feed)
    }

    func fetch(completion: @escaping (Result<(TiboFeed, Date), Error>) -> Void) {
        let existing = lock.withLock { cache }
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // v1.2.0 decoded only `events` and re-encoded its cache without the
        // newer resetTimeline extension. Reusing that cache's validators can
        // yield 304 forever, so perform one unconditional migration fetch.
        if existing?.feed.resetTimeline != nil {
            if let etag = existing?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = existing?.lastModified {
                request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        session.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let self, let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(TiboFeedError.invalidResponse)) }
                return
            }

            switch Self.interpret(status: http.statusCode, data: data ?? Data()) {
            case let .feed(feed):
                let stamp = Date()
                let installed = Cache(
                    feed: feed,
                    etag: http.value(forHTTPHeaderField: "ETag"),
                    lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                    fetchedAt: stamp
                )
                self.lock.withLock { self.cache = installed }
                Self.persist(installed, to: self.cacheURL)
                DispatchQueue.main.async { completion(.success((feed, stamp))) }
            case .unchanged:
                guard let existing else {
                    DispatchQueue.main.async {
                        completion(.failure(TiboFeedError.notModifiedWithoutCache))
                    }
                    return
                }
                let stamp = Date()
                let refreshed = Cache(
                    feed: existing.feed,
                    etag: existing.etag,
                    lastModified: existing.lastModified,
                    fetchedAt: stamp
                )
                self.lock.withLock { self.cache = refreshed }
                Self.persist(refreshed, to: self.cacheURL)
                DispatchQueue.main.async { completion(.success((refreshed.feed, stamp))) }
            case let .rejected(reason):
                DispatchQueue.main.async {
                    completion(.failure(TiboFeedError.rejected(reason)))
                }
            }
        }.resume()
    }

    private static func isValid(_ event: TiboEvent) -> Bool {
        guard event.source.handle == "thsottiaux",
              !event.source.postId.isEmpty,
              event.source.postId.allSatisfy(\.isNumber),
              event.announcedDate != nil,
              event.confidence.isFinite,
              0...1 ~= event.confidence,
              event.text.count <= 20_000
        else { return false }
        return event.source.url == "https://x.com/thsottiaux/status/\(event.source.postId)"
    }

    private static func loadCache(from url: URL) -> Cache? {
        guard let data = try? Data(contentsOf: url), data.count <= maximumPayloadSize,
              let value = try? JSONDecoder().decode(Cache.self, from: data),
              case .feed = interpret(status: 200, data: (try? JSONEncoder().encode(value.feed)) ?? Data())
        else { return nil }
        return value
    }

    private static func persist(_ cache: Cache, to url: URL) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: url, options: [.atomic])
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
