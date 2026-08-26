import Darwin
import Foundation

enum AppUpdateArchitecture: String, Codable, Equatable {
    case arm64
    case x86_64
    case unknown

    static var current: AppUpdateArchitecture {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0,
           translated == 1 {
            return .arm64
        }
        return .x86_64
        #else
        return .unknown
        #endif
    }

    var displayName: String {
        switch self {
        case .arm64: return "Apple Silicon"
        case .x86_64: return "Intel Mac"
        case .unknown: return "当前 Mac"
        }
    }
}

struct AppSemanticVersion: Comparable, Equatable {
    let components: [Int]

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" { value.removeFirst() }
        guard !value.isEmpty,
              !value.contains("-"),
              !value.contains("+"),
              value.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count) else { return nil }
        let parsed = parts.compactMap { Int($0) }
        guard parsed.count == parts.count, parsed.allSatisfy({ $0 >= 0 }) else { return nil }
        components = parsed
    }

    static func == (lhs: AppSemanticVersion, rhs: AppSemanticVersion) -> Bool {
        !isLess(lhs, rhs) && !isLess(rhs, lhs)
    }

    static func < (lhs: AppSemanticVersion, rhs: AppSemanticVersion) -> Bool {
        isLess(lhs, rhs)
    }

    private static func isLess(_ lhs: AppSemanticVersion, _ rhs: AppSemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

struct AppReleaseAsset: Codable, Equatable {
    let name: String
    let label: String?
    let state: String
    let contentType: String
    let size: Int64
    let digest: String?
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name, label, state, size, digest
        case contentType = "content_type"
        case browserDownloadURL = "browser_download_url"
    }

    var downloadURL: URL? { URL(string: browserDownloadURL) }
}

struct AppRelease: Codable, Equatable {
    let tagName: String
    let name: String
    let body: String
    let draft: Bool
    let prerelease: Bool
    let publishedAt: String?
    let htmlURL: String
    let assets: [AppReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case publishedAt = "published_at"
        case htmlURL = "html_url"
    }

    var version: AppSemanticVersion? { AppSemanticVersion(tagName) }
    var normalizedVersion: String { tagName.first?.lowercased() == "v" ? String(tagName.dropFirst()) : tagName }
    var releaseURL: URL? { URL(string: htmlURL) }
}

enum AppUpdatePhase: String, Codable, Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable
    case developmentBuild
    case failed
}

struct AppUpdateStatus: Equatable {
    let phase: AppUpdatePhase
    let currentVersion: String
    let currentBuild: String
    let release: AppRelease?
    let asset: AppReleaseAsset?
    let checkedAt: Date?
    let message: String?

    static func idle(currentVersion: String, currentBuild: String) -> AppUpdateStatus {
        AppUpdateStatus(
            phase: .idle,
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            release: nil,
            asset: nil,
            checkedAt: nil,
            message: nil
        )
    }

    func checking() -> AppUpdateStatus {
        AppUpdateStatus(
            phase: .checking,
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            release: release,
            asset: asset,
            checkedAt: checkedAt,
            message: nil
        )
    }
}

enum AppUpdateError: LocalizedError, Equatable {
    case invalidResponse(String)
    case noRelease
    case rateLimited
    case payloadTooLarge

    var errorDescription: String? {
        switch self {
        case let .invalidResponse(reason): return "更新信息不可用：\(reason)"
        case .noRelease: return "GitHub 尚未提供可用 Release。"
        case .rateLimited: return "GitHub 请求频率受限，请稍后再试。"
        case .payloadTooLarge: return "GitHub Release 响应异常过大。"
        }
    }
}

final class AppUpdateService {
    static let repository = "suguxiaojie/codex-notch-monitor"
    static let latestReleaseEndpoint = URL(
        string: "https://api.github.com/repos/\(repository)/releases/latest"
    )!
    static let latestReleasePageEndpoint = URL(
        string: "https://github.com/\(repository)/releases/latest"
    )!
    static let releasePagePrefix = "https://github.com/\(repository)/releases/tag/"
    static let releaseDownloadPrefix = "https://github.com/\(repository)/releases/download/"
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
    static let maximumPayloadSize = 2 * 1_024 * 1_024
    static let maximumAssetSize: Int64 = 512 * 1_024 * 1_024

    static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
    }

    static var bundleBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "--"
    }

    private struct Cache: Codable {
        let release: AppRelease
        let etag: String?
        let checkedAt: Date
    }

    private enum PreferenceKey {
        static let lastNotifiedVersion = "appUpdate.lastNotifiedVersion"
        static let deferredVersion = "appUpdate.deferredVersion"
        static let deferredUntil = "appUpdate.deferredUntil"
    }

    private let session: URLSession
    private let cacheURL: URL
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cache: Cache?

    init(
        session: URLSession = .shared,
        cacheURL: URL = AppPaths.supportDirectory.appendingPathComponent("app-update-cache.json"),
        defaults: UserDefaults = .standard
    ) {
        self.session = session
        self.cacheURL = cacheURL
        self.defaults = defaults
        cache = Self.loadCache(from: cacheURL)
    }

    func cachedStatus(
        currentVersion: String,
        currentBuild: String,
        architecture: AppUpdateArchitecture = .current
    ) -> AppUpdateStatus? {
        lock.lock()
        let cache = cache
        lock.unlock()
        guard let cache else { return nil }
        return Self.makeStatus(
            release: cache.release,
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            architecture: architecture,
            checkedAt: cache.checkedAt
        )
    }

    func check(
        force: Bool,
        currentVersion: String,
        currentBuild: String,
        architecture: AppUpdateArchitecture = .current,
        now: Date = Date(),
        completion: @escaping (Result<AppUpdateStatus, Error>) -> Void
    ) {
        lock.lock()
        let cached = cache
        lock.unlock()
        if !force, let cached,
           !Self.shouldCheckAutomatically(lastCheckedAt: cached.checkedAt, now: now) {
            let status = Self.makeStatus(
                release: cached.release,
                currentVersion: currentVersion,
                currentBuild: currentBuild,
                architecture: architecture,
                checkedAt: cached.checkedAt
            )
            DispatchQueue.main.async { completion(.success(status)) }
            return
        }

        let request = Self.makeRequest(etag: cached?.etag, currentVersion: currentVersion)
        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let http = response as? HTTPURLResponse,
               http.statusCode == 403 || http.statusCode == 429 {
                self.checkLatestReleasePage(
                    currentVersion: currentVersion,
                    currentBuild: currentBuild,
                    architecture: architecture,
                    now: now,
                    completion: completion
                )
                return
            }
            let result: Result<AppUpdateStatus, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                result = self.handleResponse(
                    http,
                    data: data ?? Data(),
                    cached: cached,
                    currentVersion: currentVersion,
                    currentBuild: currentBuild,
                    architecture: architecture,
                    now: now
                )
            } else {
                result = .failure(AppUpdateError.invalidResponse("非 HTTP 响应"))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    func shouldNotify(version: String, now: Date = Date()) -> Bool {
        if defaults.string(forKey: PreferenceKey.lastNotifiedVersion) == version { return false }
        if defaults.string(forKey: PreferenceKey.deferredVersion) == version,
           let deferredUntil = defaults.object(forKey: PreferenceKey.deferredUntil) as? Date,
           deferredUntil > now {
            return false
        }
        return true
    }

    func markNotified(version: String) {
        defaults.set(version, forKey: PreferenceKey.lastNotifiedVersion)
    }

    @discardableResult
    func deferNotification(version: String, now: Date = Date()) -> Date {
        let until = now.addingTimeInterval(24 * 60 * 60)
        defaults.set(version, forKey: PreferenceKey.deferredVersion)
        defaults.set(until, forKey: PreferenceKey.deferredUntil)
        return until
    }

    static func shouldCheckAutomatically(lastCheckedAt: Date?, now: Date = Date()) -> Bool {
        guard let lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= automaticCheckInterval
    }

    static func makeRequest(etag: String?, currentVersion: String) -> URLRequest {
        var request = URLRequest(url: latestReleaseEndpoint)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("CodexNotchMonitor/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    static func decodeRelease(_ data: Data) throws -> AppRelease {
        guard data.count <= maximumPayloadSize else { throw AppUpdateError.payloadTooLarge }
        guard let release = try? JSONDecoder().decode(AppRelease.self, from: data) else {
            throw AppUpdateError.invalidResponse("JSON 格式错误")
        }
        guard release.draft == false, release.prerelease == false else {
            throw AppUpdateError.invalidResponse("不是正式 Release")
        }
        guard release.version != nil else {
            throw AppUpdateError.invalidResponse("版本号无效")
        }
        guard release.htmlURL.hasPrefix(releasePagePrefix + release.tagName) else {
            throw AppUpdateError.invalidResponse("Release 地址不属于指定仓库")
        }
        guard release.body.count <= 200_000 else {
            throw AppUpdateError.invalidResponse("更新说明过长")
        }
        return release
    }

    static func makeStatus(
        release: AppRelease,
        currentVersion: String,
        currentBuild: String,
        architecture: AppUpdateArchitecture,
        checkedAt: Date
    ) -> AppUpdateStatus {
        guard let local = AppSemanticVersion(currentVersion), let remote = release.version else {
            return AppUpdateStatus(
                phase: .failed,
                currentVersion: currentVersion,
                currentBuild: currentBuild,
                release: release,
                asset: nil,
                checkedAt: checkedAt,
                message: "无法比较当前版本与 GitHub Release。"
            )
        }
        if remote > local {
            let asset = selectAsset(for: release, architecture: architecture)
            return AppUpdateStatus(
                phase: .updateAvailable,
                currentVersion: currentVersion,
                currentBuild: currentBuild,
                release: release,
                asset: asset,
                checkedAt: checkedAt,
                message: asset == nil ? "未找到适用于此 Mac 的 DMG，请打开 Release 页面。" : nil
            )
        }
        return AppUpdateStatus(
            phase: remote == local ? .upToDate : .developmentBuild,
            currentVersion: currentVersion,
            currentBuild: currentBuild,
            release: release,
            asset: nil,
            checkedAt: checkedAt,
            message: nil
        )
    }

    static func selectAsset(
        for release: AppRelease,
        architecture: AppUpdateArchitecture
    ) -> AppReleaseAsset? {
        let preferredSuffix: String
        switch architecture {
        case .arm64: preferredSuffix = "-arm64.dmg"
        case .x86_64: preferredSuffix = "-x86_64.dmg"
        case .unknown: preferredSuffix = "-universal.dmg"
        }
        let validAssets = release.assets.filter {
            isValidAsset($0, for: release) || isValidInferredAsset($0, for: release)
        }
        return validAssets.first { $0.name.hasSuffix(preferredSuffix) }
            ?? validAssets.first { $0.name.hasSuffix("-universal.dmg") }
    }

    static func isValidAsset(_ asset: AppReleaseAsset, for release: AppRelease) -> Bool {
        guard asset.state == "uploaded",
              asset.contentType == "application/x-apple-diskimage",
              asset.size > 0,
              asset.size <= maximumAssetSize,
              asset.name.hasSuffix(".dmg"),
              asset.name.contains("-\(release.tagName)-"),
              !asset.name.contains("/"),
              asset.browserDownloadURL.hasPrefix(releaseDownloadPrefix + release.tagName + "/"),
              let digest = asset.digest,
              isValidSHA256Digest(digest) else { return false }
        return true
    }

    static func releaseFromLatestPage(finalURL: URL) throws -> AppRelease {
        let value = finalURL.absoluteString
        guard value.hasPrefix(releasePagePrefix) else {
            throw AppUpdateError.invalidResponse("Latest Release 重定向地址无效")
        }
        let tag = String(value.dropFirst(releasePagePrefix.count))
        guard !tag.isEmpty,
              !tag.contains("/"),
              AppSemanticVersion(tag) != nil else {
            throw AppUpdateError.invalidResponse("Latest Release 版本号无效")
        }
        let version = tag.first?.lowercased() == "v" ? String(tag.dropFirst()) : tag
        let assetNames = [
            "CodexNotchMonitor-v\(version)-arm64.dmg",
            "CodexNotchMonitor-v\(version)-x86_64.dmg",
        ]
        let assets = assetNames.map { name in
            AppReleaseAsset(
                name: name,
                label: nil,
                state: "inferred",
                contentType: "application/x-apple-diskimage",
                size: 0,
                digest: nil,
                browserDownloadURL: releaseDownloadPrefix + tag + "/" + name
            )
        }
        return AppRelease(
            tagName: tag,
            name: "Codex Notch Monitor \(tag)",
            body: "GitHub API 请求受限，已通过公开 Latest Release 页面确认版本。请打开 Release 页面查看完整更新说明和文件校验值。",
            draft: false,
            prerelease: false,
            publishedAt: nil,
            htmlURL: releasePagePrefix + tag,
            assets: assets
        )
    }

    static func isValidSHA256Digest(_ value: String) -> Bool {
        guard value.hasPrefix("sha256:") else { return false }
        let hex = value.dropFirst("sha256:".count)
        return hex.count == 64 && hex.allSatisfy { character in
            character.isNumber || ("a"..."f").contains(character.lowercased())
        }
    }

    private static func isValidInferredAsset(
        _ asset: AppReleaseAsset,
        for release: AppRelease
    ) -> Bool {
        guard asset.state == "inferred",
              asset.contentType == "application/x-apple-diskimage",
              asset.size == 0,
              asset.digest == nil,
              !asset.name.contains("/"),
              asset.browserDownloadURL == releaseDownloadPrefix + release.tagName + "/" + asset.name
        else { return false }
        return asset.name == "CodexNotchMonitor-\(release.tagName)-arm64.dmg"
            || asset.name == "CodexNotchMonitor-\(release.tagName)-x86_64.dmg"
    }

    private func checkLatestReleasePage(
        currentVersion: String,
        currentBuild: String,
        architecture: AppUpdateArchitecture,
        now: Date,
        completion: @escaping (Result<AppUpdateStatus, Error>) -> Void
    ) {
        var request = URLRequest(url: Self.latestReleasePageEndpoint)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("CodexNotchMonitor/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            let result: Result<AppUpdateStatus, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse,
                      http.statusCode == 200,
                      let finalURL = http.url {
                do {
                    let release = try Self.releaseFromLatestPage(finalURL: finalURL)
                    let installed = Cache(release: release, etag: nil, checkedAt: now)
                    self.installCache(installed)
                    result = .success(Self.makeStatus(
                        release: release,
                        currentVersion: currentVersion,
                        currentBuild: currentBuild,
                        architecture: architecture,
                        checkedAt: now
                    ))
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(AppUpdateError.rateLimited)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private func handleResponse(
        _ response: HTTPURLResponse,
        data: Data,
        cached: Cache?,
        currentVersion: String,
        currentBuild: String,
        architecture: AppUpdateArchitecture,
        now: Date
    ) -> Result<AppUpdateStatus, Error> {
        if response.statusCode == 304 {
            guard let cached else {
                return .failure(AppUpdateError.invalidResponse("304 缺少本地缓存"))
            }
            let refreshed = Cache(release: cached.release, etag: cached.etag, checkedAt: now)
            installCache(refreshed)
            return .success(Self.makeStatus(
                release: refreshed.release,
                currentVersion: currentVersion,
                currentBuild: currentBuild,
                architecture: architecture,
                checkedAt: now
            ))
        }
        if response.statusCode == 404 { return .failure(AppUpdateError.noRelease) }
        if response.statusCode == 403 || response.statusCode == 429 {
            return .failure(AppUpdateError.rateLimited)
        }
        guard response.statusCode == 200 else {
            return .failure(AppUpdateError.invalidResponse("HTTP \(response.statusCode)"))
        }
        do {
            let release = try Self.decodeRelease(data)
            let installed = Cache(
                release: release,
                etag: response.value(forHTTPHeaderField: "ETag"),
                checkedAt: now
            )
            installCache(installed)
            return .success(Self.makeStatus(
                release: release,
                currentVersion: currentVersion,
                currentBuild: currentBuild,
                architecture: architecture,
                checkedAt: now
            ))
        } catch {
            return .failure(error)
        }
    }

    private func installCache(_ value: Cache) {
        lock.lock()
        cache = value
        lock.unlock()
        Self.persist(value, to: cacheURL)
    }

    private static func loadCache(from url: URL) -> Cache? {
        guard let data = try? Data(contentsOf: url),
              data.count <= maximumPayloadSize,
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.release.version != nil,
              cache.release.htmlURL.hasPrefix(releasePagePrefix + cache.release.tagName)
        else { return nil }
        return cache
    }

    private static func persist(_ value: Cache, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}
