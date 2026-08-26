import Foundation

struct CodexResetRadarProfile: Codable, Equatable {
    let handle: String
    let name: String
    let followers: Int?
}

struct CodexResetRadarSignal: Codable, Equatable {
    let tweetId: String
    let summary: String
    let at: String
    let url: String
    let kind: String
    let active: Bool
    let localizedSummary: String?
    let translationStatus: String?

    var date: Date? { TiboFeedDate.parse(at) }
    var displayText: String { localizedSummary?.nonEmpty ?? summary }
}

struct CodexResetRadarTweet: Codable, Identifiable, Equatable {
    let id: String
    let url: String
    let text: String
    let at: String
    let isReply: Bool?
    let replyingTo: String?
    let kind: String
    let replies: Int?
    let reposts: Int?
    let likes: Int?
    let tiboLane: String?
    let explicitResetClaim: Bool?
    let resetVerificationStatus: String?
    let localizedText: String?
    let translationStatus: String?

    var date: Date? { TiboFeedDate.parse(at) }
    var displayText: String { localizedText?.nonEmpty ?? text }
}

struct CodexResetOfficialWindow: Codable, Equatable {
    let label: String?
    let startAt: String?
    let endAt: String?
    let timeZone: String?
    let targetKind: String?
    let targetAt: String?

    var effectiveAt: String? { targetAt ?? startAt }
}

struct CodexResetTimelineEvent: Codable, Identifiable, Equatable {
    let id: String
    let date: String
    let type: String
    let group: String
    let summary: String
    let url: String
    let announcedAt: String
    let effectiveAt: String?
    let officialWindow: CodexResetOfficialWindow?
    let preview: Bool
    let scope: String?
    let confidence: String
    let source: String
    let sourceLabel: String?
    let resetKind: String?
    let bankedState: String?
    let audience: [String]?
    let announcementState: String?
    let observationResult: String?
    let resetVerificationStatus: String?
    let localizedSummary: String?
    let translationStatus: String?

    var announcedDate: Date? { TiboFeedDate.parse(announcedAt) }
    var displayText: String { localizedSummary?.nonEmpty ?? summary }
}

struct CodexResetForecastProbabilities: Codable, Equatable {
    let rounded24H: Int?
    let rounded48H: Int?
}

struct CodexResetForecast: Codable, Equatable {
    let mode: String
    let updatedAt: String
    let probabilities: CodexResetForecastProbabilities
    let confidence: String
    let confidenceNote: String?
    let lastResetAt: String?
    let ageDays: Double?
    let translationStatus: String?

    var updatedDate: Date? { TiboFeedDate.parse(updatedAt) }
}

struct CodexResetRadarSnapshot: Codable, Equatable {
    let fetchedAt: String
    let timelineUpdatedAt: String
    let source: String
    let stale: Bool
    let contentAgeDays: Double?
    let profile: CodexResetRadarProfile
    let signal: CodexResetRadarSignal?
    let tweets: [CodexResetRadarTweet]
    let timelineEvents: [CodexResetTimelineEvent]
    let forecast: CodexResetForecast
    let evidenceFeed: TiboFeed

    var fetchedDate: Date? { TiboFeedDate.parse(fetchedAt) }
}

enum CodexResetPinnedSignalState: Equatable {
    case confirmed
    case fulfilled
    case activePreview
    case expired
    case pending
}

struct CodexResetPinnedSignalResolution: Equatable {
    let state: CodexResetPinnedSignalState
    let signalEvent: CodexResetTimelineEvent?
    let evidenceEvent: CodexResetTimelineEvent?
    let isLocallyConfirmed: Bool
}

enum CodexResetRadarError: LocalizedError {
    case invalidResponse(String)
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case let .invalidResponse(endpoint): return "\(endpoint) 返回了无效响应"
        case let .rejected(reason): return "雷达数据不可用：\(reason)"
        }
    }
}

final class CodexResetRadarService {
    static let feedEndpoint = URL(string: "https://codex-reset.com/api/feed?locale=zh")!
    static let timelineEndpoint = URL(string: "https://codex-reset.com/api/timeline?locale=zh")!
    static let forecastEndpoint = URL(string: "https://codex-reset.com/api/forecast?locale=zh")!
    static let refreshInterval: TimeInterval = 3 * 60
    static let staleInterval: TimeInterval = 10 * 60
    static let maximumPayloadSize = 2 * 1_024 * 1_024

    private struct Cache: Codable {
        let snapshot: CodexResetRadarSnapshot
        let fetchedAt: Date
    }

    private struct FeedResponse: Decodable {
        let version: Int
        let fetchedAt: String
        let source: String
        let sourceScope: String
        let stale: Bool
        let contentAgeDays: Double?
        let profile: CodexResetRadarProfile
        let signal: CodexResetRadarSignal?
        let tweets: [CodexResetRadarTweet]
    }

    private struct TimelineResponse: Decodable {
        let updatedAt: String
        let events: [CodexResetTimelineEvent]
    }

    private let session: URLSession
    private let cacheURL: URL
    private let lock = NSLock()
    private var cache: Cache?

    init(
        session: URLSession = .shared,
        cacheURL: URL = AppPaths.supportDirectory.appendingPathComponent("codex-reset-radar.json")
    ) {
        self.session = session
        self.cacheURL = cacheURL
        self.cache = Self.loadCache(from: cacheURL)
    }

    var cachedSnapshot: CodexResetRadarSnapshot? {
        lock.withRadarLock { cache?.snapshot }
    }

    var cachedAt: Date? {
        lock.withRadarLock { cache?.fetchedAt }
    }

    static func resolvePinnedSignal(
        _ signal: CodexResetRadarSignal,
        timelineEvents: [CodexResetTimelineEvent],
        locallyConfirmedPostIDs: Set<String> = [],
        now: Date = Date()
    ) -> CodexResetPinnedSignalResolution {
        let signalEvent = timelineEvents.first { $0.id == signal.tweetId }
        let directLocalConfirmation = locallyConfirmedPostIDs.contains(signal.tweetId)
        if directLocalConfirmation
            || (signalEvent?.preview == false
                && signalEvent?.source == "archive"
                && signalEvent?.confidence == "high") {
            return CodexResetPinnedSignalResolution(
                state: .confirmed,
                signalEvent: signalEvent,
                evidenceEvent: signalEvent,
                isLocallyConfirmed: directLocalConfirmation
            )
        }

        if signalEvent?.preview == true,
           let fulfillment = matchingFulfillment(
               for: signal,
               signalEvent: signalEvent,
               timelineEvents: timelineEvents,
               locallyConfirmedPostIDs: locallyConfirmedPostIDs
           ) {
            return CodexResetPinnedSignalResolution(
                state: .fulfilled,
                signalEvent: signalEvent,
                evidenceEvent: fulfillment,
                isLocallyConfirmed: locallyConfirmedPostIDs.contains(fulfillment.id)
            )
        }

        if signalEvent?.preview == true {
            let deadline = pinnedSignalDeadline(signal: signal, event: signalEvent)
            return CodexResetPinnedSignalResolution(
                state: signal.active && now <= deadline ? .activePreview : .expired,
                signalEvent: signalEvent,
                evidenceEvent: nil,
                isLocallyConfirmed: false
            )
        }

        return CodexResetPinnedSignalResolution(
            state: signal.active ? .pending : .expired,
            signalEvent: signalEvent,
            evidenceEvent: nil,
            isLocallyConfirmed: false
        )
    }

    private static func matchingFulfillment(
        for signal: CodexResetRadarSignal,
        signalEvent: CodexResetTimelineEvent?,
        timelineEvents: [CodexResetTimelineEvent],
        locallyConfirmedPostIDs: Set<String>
    ) -> CodexResetTimelineEvent? {
        guard let signalDate = signal.date else { return nil }
        let deadline = pinnedSignalDeadline(signal: signal, event: signalEvent)
        return timelineEvents
            .filter { event in
                guard event.id != signal.tweetId,
                      event.type == "reset",
                      event.preview == false,
                      event.resetVerificationStatus != "rejected",
                      let eventDate = event.announcedDate,
                      eventDate >= signalDate,
                      eventDate <= deadline else { return false }
                let scopeMatches = signalEvent?.scope == nil
                    || event.scope == nil
                    || signalEvent?.scope == event.scope
                let hasEvidence = locallyConfirmedPostIDs.contains(event.id)
                    || (event.source == "archive" && event.confidence == "high")
                return scopeMatches && hasEvidence
            }
            .min { lhs, rhs in
                (lhs.announcedDate ?? .distantFuture)
                    < (rhs.announcedDate ?? .distantFuture)
            }
    }

    private static func pinnedSignalDeadline(
        signal: CodexResetRadarSignal,
        event: CodexResetTimelineEvent?
    ) -> Date {
        let evidenceWindowEnd = [
            event?.officialWindow?.endAt,
            event?.officialWindow?.targetAt,
            event?.effectiveAt,
        ]
        .compactMap { $0.flatMap(TiboFeedDate.parse) }
        .first
        if let evidenceWindowEnd {
            return evidenceWindowEnd.addingTimeInterval(12 * 60 * 60)
        }
        return (signal.date ?? .distantPast).addingTimeInterval(48 * 60 * 60)
    }

    func fetch(completion: @escaping (Result<(CodexResetRadarSnapshot, Date), Error>) -> Void) {
        request(Self.feedEndpoint, label: "实时动态") { [weak self] feedResult in
            guard let self else { return }
            switch feedResult {
            case let .failure(error):
                DispatchQueue.main.async { completion(.failure(error)) }
            case let .success(feedData):
                self.request(Self.timelineEndpoint, label: "重置时间轴") { timelineResult in
                    switch timelineResult {
                    case let .failure(error):
                        DispatchQueue.main.async { completion(.failure(error)) }
                    case let .success(timelineData):
                        self.request(Self.forecastEndpoint, label: "雷达预测") { forecastResult in
                            let result = forecastResult.flatMap { forecastData in
                                Result {
                                    try Self.makeSnapshot(
                                        feedData: feedData,
                                        timelineData: timelineData,
                                        forecastData: forecastData
                                    )
                                }
                            }
                            switch result {
                            case let .failure(error):
                                DispatchQueue.main.async { completion(.failure(error)) }
                            case let .success(snapshot):
                                let stamp = Date()
                                let installed = Cache(snapshot: snapshot, fetchedAt: stamp)
                                self.lock.withRadarLock { self.cache = installed }
                                Self.persist(installed, to: self.cacheURL)
                                DispatchQueue.main.async { completion(.success((snapshot, stamp))) }
                            }
                        }
                    }
                }
            }
        }
    }

    static func makeSnapshot(
        feedData: Data,
        timelineData: Data,
        forecastData: Data
    ) throws -> CodexResetRadarSnapshot {
        guard feedData.count <= maximumPayloadSize,
              timelineData.count <= maximumPayloadSize,
              forecastData.count <= maximumPayloadSize else {
            throw CodexResetRadarError.rejected("响应过大")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let feed = try? decoder.decode(FeedResponse.self, from: feedData),
              let timeline = try? decoder.decode(TimelineResponse.self, from: timelineData),
              let forecast = try? decoder.decode(CodexResetForecast.self, from: forecastData)
        else { throw CodexResetRadarError.rejected("JSON 格式错误") }

        guard feed.version == 1,
              feed.source == "x-api",
              feed.sourceScope == "timeline",
              feed.profile.handle == "thsottiaux",
              TiboFeedDate.parse(feed.fetchedAt) != nil,
              TiboFeedDate.parse(timeline.updatedAt) != nil,
              forecast.updatedDate != nil
        else { throw CodexResetRadarError.rejected("来源或时间字段无效") }

        let probabilitiesValid = [
            forecast.probabilities.rounded24H,
            forecast.probabilities.rounded48H,
        ].compactMap { $0 }.allSatisfy { 0...100 ~= $0 }
        guard feed.tweets.count <= 100,
              timeline.events.count <= 300,
              feed.tweets.allSatisfy(validTweet),
              timeline.events.allSatisfy(validTimelineEvent),
              feed.signal.map(validSignal) ?? true,
              probabilitiesValid
        else { throw CodexResetRadarError.rejected("事件范围或来源校验失败") }

        let evidence = makeEvidenceFeed(feed: feed, timeline: timeline)
        return CodexResetRadarSnapshot(
            fetchedAt: feed.fetchedAt,
            timelineUpdatedAt: timeline.updatedAt,
            source: feed.source,
            stale: feed.stale,
            contentAgeDays: feed.contentAgeDays,
            profile: feed.profile,
            signal: feed.signal,
            tweets: feed.tweets,
            timelineEvents: timeline.events,
            forecast: forecast,
            evidenceFeed: evidence
        )
    }

    private func request(
        _ url: URL,
        label: String,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data,
                  !data.isEmpty else {
                completion(.failure(CodexResetRadarError.invalidResponse(label)))
                return
            }
            completion(.success(data))
        }.resume()
    }

    private static func makeEvidenceFeed(
        feed: FeedResponse,
        timeline: TimelineResponse
    ) -> TiboFeed {
        let tweets = Dictionary(uniqueKeysWithValues: feed.tweets.map { ($0.id, $0) })
        let events = timeline.events.compactMap { event -> TiboEvent? in
            guard let announced = event.announcedDate else { return nil }
            let tweet = tweets[event.id]
            let kind = evidenceKind(event: event, tweet: tweet)
            let confidence: Double
            switch event.confidence {
            case "high": confidence = 1
            case "medium": confidence = 0.65
            default: confidence = 0.35
            }
            let effectiveAt = event.effectiveAt ?? event.officialWindow?.effectiveAt
            return TiboEvent(
                kind: kind,
                announcedAt: TiboFeedDate.string(announced),
                effectiveAt: effectiveAt,
                scope: TiboEventScope(
                    plans: event.audience?.isEmpty == false ? event.audience! : ["all"],
                    windows: [event.officialWindow?.label ?? "unknown"]
                ),
                source: TiboEventSource(
                    handle: "thsottiaux",
                    postId: event.id,
                    url: event.url
                ),
                confidence: confidence,
                rationale: [event.sourceLabel, event.resetVerificationStatus]
                    .compactMap { $0?.nonEmpty }
                    .joined(separator: " · "),
                text: event.displayText
            )
        }
        return TiboFeed(
            schemaVersion: 1,
            generatedAt: timeline.updatedAt,
            lastSuccessfulCheckAt: feed.fetchedAt,
            monitor: TiboFeedMonitor(status: feed.stale ? "degraded" : "ok", errorCode: nil),
            events: events,
            resetTimeline: nil
        )
    }

    private static func evidenceKind(
        event: CodexResetTimelineEvent,
        tweet: CodexResetRadarTweet?
    ) -> TiboEventKind {
        guard event.resetVerificationStatus != "rejected" else { return .uncertain }
        switch event.type {
        case "credits": return .bankedReset
        case "promo", "boost": return .limitIncrease
        case "reset":
            if event.preview || event.announcementState == "hinted" {
                return .resetScheduled
            }
            if event.source == "archive", event.confidence == "high" {
                return .resetCompleted
            }
            if event.announcementState == "announced",
               tweet?.explicitResetClaim == true {
                return .resetCompleted
            }
            return .uncertain
        default: return .uncertain
        }
    }

    private static func validTweet(_ tweet: CodexResetRadarTweet) -> Bool {
        guard tweet.id.allSatisfy(\.isNumber),
              tweet.date != nil,
              tweet.text.count <= 20_000 else { return false }
        return canonicalXURL(tweet.url, id: tweet.id)
    }

    private static func validTimelineEvent(_ event: CodexResetTimelineEvent) -> Bool {
        guard event.id.allSatisfy(\.isNumber),
              event.announcedDate != nil,
              event.summary.count <= 20_000,
              ["high", "medium", "low"].contains(event.confidence),
              ["live", "archive"].contains(event.source) else { return false }
        return canonicalXURL(event.url, id: event.id)
    }

    private static func validSignal(_ signal: CodexResetRadarSignal) -> Bool {
        signal.tweetId.allSatisfy(\.isNumber)
            && signal.date != nil
            && signal.summary.count <= 20_000
            && canonicalXURL(signal.url, id: signal.tweetId)
    }

    private static func canonicalXURL(_ value: String, id: String) -> Bool {
        value == "https://x.com/thsottiaux/status/\(id)"
    }

    private static func loadCache(from url: URL) -> Cache? {
        guard let data = try? Data(contentsOf: url),
              data.count <= maximumPayloadSize * 2,
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.snapshot.profile.handle == "thsottiaux",
              cache.snapshot.tweets.count <= 100,
              cache.snapshot.timelineEvents.count <= 300,
              cache.snapshot.tweets.allSatisfy(validTweet),
              cache.snapshot.timelineEvents.allSatisfy(validTimelineEvent)
        else { return nil }
        return cache
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

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private extension TiboFeedDate {
    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private extension NSLock {
    func withRadarLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
