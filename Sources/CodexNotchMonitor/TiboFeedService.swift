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

struct TiboFeed: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: String
    let lastSuccessfulCheckAt: String?
    let monitor: TiboFeedMonitor
    let events: [TiboEvent]

    var generatedDate: Date? { TiboFeedDate.parse(generatedAt) }
    var lastSuccessfulCheckDate: Date? { lastSuccessfulCheckAt.flatMap(TiboFeedDate.parse) }
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
        return .feed(feed)
    }

    func fetch(completion: @escaping (Result<(TiboFeed, Date), Error>) -> Void) {
        let existing = lock.withLock { cache }
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag = existing?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified = existing?.lastModified {
            request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
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
