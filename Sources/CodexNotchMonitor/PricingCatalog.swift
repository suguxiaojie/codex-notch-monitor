import Foundation

struct CatalogRates: Codable, Equatable {
    let displayName: String?
    let inputPerMillion: Double
    let outputPerMillion: Double
    let cacheCreationPerMillion: Double
    let cacheReadPerMillion: Double

    var isValid: Bool {
        [inputPerMillion, outputPerMillion, cacheCreationPerMillion, cacheReadPerMillion]
            .allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1_000_000 }
    }
}

struct CatalogPayload: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: String
    let models: [String: CatalogRates]
}

enum CatalogFetchResult: Equatable {
    case payload(CatalogPayload)
    case unchanged
    case rejected(String)
}

enum CatalogRefreshResult: Equatable {
    case notNeeded
    case updated
    case unchanged
    case failed
}

/// A small, privacy-preserving price catalog client based on CodexIsland's
/// design. It downloads public model prices only; no account, log, model-use,
/// or token information is added to the request.
enum PricingCatalog {
    static let supportedSchemaVersion = 1
    static let endpoint = URL(
        string: "https://ericjypark.github.io/codex-island-model-catalog/v1/models.json"
    )!
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    static let retryInterval: TimeInterval = 6 * 60 * 60

    private static let lock = NSLock()
    private static var models: [String: CatalogRates] = [:]
    private static var fetchedAt: Date?
    private static var etag: String?
    private static var didLoadCache = false
    private static var refreshInProgress = false
    private static var lastAttemptAt: Date?

    struct CachedCatalog: Codable {
        let payload: CatalogPayload
        let etag: String?
        let fetchedAt: Date
    }

    static var lastFetched: Date? {
        lock.lock()
        defer { lock.unlock() }
        return fetchedAt
    }

    static func rates(for canonical: String) -> CatalogRates? {
        lock.lock()
        defer { lock.unlock() }
        return models[canonical]
    }

    static func cacheURL() -> URL? {
        let manager = FileManager.default
        guard let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = caches.appendingPathComponent(
            "com.coverai.codex-notch-monitor", isDirectory: true
        )
        do {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return nil
        }
        return directory.appendingPathComponent("model-prices.json")
    }

    /// Idempotently restore the last verified catalog before the first cost
    /// scan, so the UI never has to wait for a network request.
    static func prepare(cache: URL? = cacheURL()) {
        lock.lock()
        guard !didLoadCache else {
            lock.unlock()
            return
        }
        didLoadCache = true
        lock.unlock()
        loadFromDisk(from: cache)
    }

    static func interpret(status: Int, data: Data) -> CatalogFetchResult {
        if status == 304 { return .unchanged }
        guard status == 200 else { return .rejected("HTTP \(status)") }
        guard data.count <= 5 * 1_024 * 1_024 else { return .rejected("catalog too large") }
        guard let payload = try? JSONDecoder().decode(CatalogPayload.self, from: data) else {
            return .rejected("malformed JSON")
        }
        guard payload.schemaVersion == supportedSchemaVersion else {
            return .rejected("unsupported schemaVersion \(payload.schemaVersion)")
        }
        guard !payload.models.isEmpty else { return .rejected("empty catalog") }
        guard payload.models.allSatisfy({ !$0.key.isEmpty && $0.value.isValid }) else {
            return .rejected("invalid model rates")
        }
        return .payload(payload)
    }

    static func loadFromDisk(from url: URL? = cacheURL()) {
        guard let url,
              let data = try? Data(contentsOf: url),
              data.count <= 5 * 1_024 * 1_024,
              let cached = try? JSONDecoder().decode(CachedCatalog.self, from: data),
              case .payload(let payload) = interpret(
                status: 200,
                data: (try? JSONEncoder().encode(cached.payload)) ?? Data()
              )
        else { return }
        install(payload: payload, etag: cached.etag, fetchedAt: cached.fetchedAt)
    }

    static func refreshIfNeeded(
        now: Date = Date(),
        cache: URL? = cacheURL(),
        fetch: (URLRequest) async throws -> (Data, URLResponse) = {
            try await URLSession.shared.data(for: $0)
        }
    ) async -> CatalogRefreshResult {
        guard let currentETag = beginRefreshIfNeeded(at: now) else { return .notNeeded }
        defer { finishRefresh() }

        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let currentETag = currentETag.value {
            request.setValue(currentETag, forHTTPHeaderField: "If-None-Match")
        }

        guard let (data, response) = try? await fetch(request),
              let http = response as? HTTPURLResponse
        else { return .failed }

        switch interpret(status: http.statusCode, data: data) {
        case .payload(let payload):
            let responseETag = http.value(forHTTPHeaderField: "ETag")
            install(payload: payload, etag: responseETag, fetchedAt: now)
            persist(payload, etag: responseETag, at: now, to: cache)
            return .updated
        case .unchanged:
            markVerified(at: now)
            touchCache(at: now, to: cache)
            return .unchanged
        case .rejected:
            return .failed
        }
    }

    /// Keep NSLock operations in synchronous helpers. Besides making the
    /// critical section obvious, this remains valid under Swift 6's rule that
    /// an async function may not hold a thread lock across a suspension point.
    private struct RefreshContext { let value: String? }

    private static func beginRefreshIfNeeded(at now: Date) -> RefreshContext? {
        lock.lock()
        defer { lock.unlock() }
        if let last = fetchedAt, now.timeIntervalSince(last) < refreshInterval { return nil }
        if let lastAttemptAt,
           now.timeIntervalSince(lastAttemptAt) >= 0,
           now.timeIntervalSince(lastAttemptAt) < retryInterval {
            return nil
        }
        guard !refreshInProgress else { return nil }
        refreshInProgress = true
        lastAttemptAt = now
        return RefreshContext(value: etag)
    }

    private static func finishRefresh() {
        lock.lock()
        refreshInProgress = false
        lock.unlock()
    }

    private static func install(payload: CatalogPayload, etag newETag: String?, fetchedAt stamp: Date) {
        lock.lock()
        models = Dictionary(uniqueKeysWithValues: payload.models.map {
            ($0.key.lowercased(), $0.value)
        })
        etag = newETag
        fetchedAt = stamp
        lock.unlock()
    }

    private static func markVerified(at stamp: Date) {
        lock.lock()
        fetchedAt = stamp
        lock.unlock()
    }

    private static func persist(
        _ payload: CatalogPayload,
        etag: String?,
        at stamp: Date,
        to url: URL?
    ) {
        guard let url,
              let data = try? JSONEncoder().encode(
                CachedCatalog(payload: payload, etag: etag, fetchedAt: stamp)
              )
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func touchCache(at stamp: Date, to url: URL?) {
        guard let url,
              let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedCatalog.self, from: data)
        else { return }
        persist(cached.payload, etag: cached.etag, at: stamp, to: url)
    }
}
