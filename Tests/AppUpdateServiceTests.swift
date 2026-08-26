import Foundation

@main
enum AppUpdateServiceTests {
    static func main() throws {
        check(AppSemanticVersion("1.5.1")! > AppSemanticVersion("1.5.0")!, "patch comparison")
        check(AppSemanticVersion("1.5.10")! > AppSemanticVersion("1.5.9")!, "numeric comparison")
        check(AppSemanticVersion("2.0.0")! > AppSemanticVersion("1.99.99")!, "major comparison")
        check(AppSemanticVersion("1.5")! == AppSemanticVersion("v1.5.0")!, "missing zero components")
        check(AppSemanticVersion("1.6.0-rc1") == nil, "reject prerelease version syntax")
        check(AppSemanticVersion("latest") == nil, "reject nonnumeric version")

        let release = try AppUpdateService.decodeRelease(validReleaseData())
        check(release.tagName == "v1.6.0", "decode latest release tag")
        check(release.assets.count == 3, "decode release assets")

        let upToDate = AppUpdateService.makeStatus(
            release: release,
            currentVersion: "1.6.0",
            currentBuild: "12",
            architecture: .arm64,
            checkedAt: Date()
        )
        check(upToDate.phase == .upToDate, "equal version is current")

        let available = AppUpdateService.makeStatus(
            release: release,
            currentVersion: "1.5.0",
            currentBuild: "11",
            architecture: .arm64,
            checkedAt: Date()
        )
        check(available.phase == .updateAvailable, "newer release is available")

        let development = AppUpdateService.makeStatus(
            release: release,
            currentVersion: "1.7.0",
            currentBuild: "13",
            architecture: .arm64,
            checkedAt: Date()
        )
        check(development.phase == .developmentBuild, "newer local version is development build")
        check(available.asset?.name.hasSuffix("-arm64.dmg") == true, "Apple Silicon selects arm64")
        check(
            AppUpdateService.selectAsset(for: release, architecture: .x86_64)?
                .name.hasSuffix("-x86_64.dmg") == true,
            "Intel selects x86_64"
        )
        check(
            AppUpdateService.selectAsset(for: release, architecture: .unknown)?
                .name.hasSuffix("-universal.dmg") == true,
            "unknown architecture falls back to universal"
        )

        var malicious = release.assets[0]
        malicious = AppReleaseAsset(
            name: malicious.name,
            label: malicious.label,
            state: malicious.state,
            contentType: malicious.contentType,
            size: malicious.size,
            digest: malicious.digest,
            browserDownloadURL: "https://example.com/evil.dmg"
        )
        check(!AppUpdateService.isValidAsset(malicious, for: release), "reject external download URL")
        check(!AppUpdateService.isValidSHA256Digest("sha256:1234"), "reject short digest")
        check(
            AppUpdateService.isValidSHA256Digest("sha256:" + String(repeating: "a", count: 64)),
            "accept valid sha256 digest"
        )

        let request = AppUpdateService.makeRequest(etag: "etag-1", currentVersion: "1.5.0")
        check(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json", "GitHub accept header")
        check(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2026-03-10", "GitHub API version header")
        check(request.value(forHTTPHeaderField: "If-None-Match") == "etag-1", "ETag request header")

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        check(AppUpdateService.shouldCheckAutomatically(lastCheckedAt: nil, now: now), "no cache checks immediately")
        check(
            !AppUpdateService.shouldCheckAutomatically(
                lastCheckedAt: now.addingTimeInterval(-60),
                now: now
            ),
            "recent check is reused"
        )
        check(
            AppUpdateService.shouldCheckAutomatically(
                lastCheckedAt: now.addingTimeInterval(-25 * 60 * 60),
                now: now
            ),
            "stale check refreshes"
        )
        let suite = "AppUpdateServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let service = AppUpdateService(
            cacheURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("app-update-\(UUID().uuidString).json"),
            defaults: defaults
        )
        check(service.shouldNotify(version: "1.6.0", now: now), "new version can notify")
        service.markNotified(version: "1.6.0")
        check(!service.shouldNotify(version: "1.6.0", now: now), "same version notifies once")
        let deferredUntil = service.deferNotification(version: "1.7.0", now: now)
        check(!service.shouldNotify(version: "1.7.0", now: now), "deferred version stays quiet")
        check(service.shouldNotify(version: "1.7.0", now: deferredUntil.addingTimeInterval(1)), "defer expires")

        try expectDecodeFailure(
            replacing: #""draft":false"#,
            with: #""draft":true"#,
            label: "reject draft"
        )
        try expectDecodeFailure(
            replacing: #""prerelease":false"#,
            with: #""prerelease":true"#,
            label: "reject prerelease"
        )
        try expectDecodeFailure(
            replacing: "https://github.com/suguxiaojie/codex-notch-monitor/releases/tag/v1.6.0",
            with: "https://example.com/v1.6.0",
            label: "reject external release page"
        )

        do {
            _ = try AppUpdateService.decodeRelease(
                Data(repeating: 0, count: AppUpdateService.maximumPayloadSize + 1)
            )
            fail("reject oversized payload")
        } catch let error as AppUpdateError {
            check(error == .payloadTooLarge, "reject oversized payload")
        }

        let releaseWithoutMatchingAsset = AppRelease(
            tagName: release.tagName,
            name: release.name,
            body: release.body,
            draft: false,
            prerelease: false,
            publishedAt: release.publishedAt,
            htmlURL: release.htmlURL,
            assets: []
        )
        let missingAsset = AppUpdateService.makeStatus(
            release: releaseWithoutMatchingAsset,
            currentVersion: "1.5.0",
            currentBuild: "11",
            architecture: .arm64,
            checkedAt: now
        )
        check(missingAsset.phase == .updateAvailable, "version update survives missing asset")
        check(missingAsset.asset == nil && missingAsset.message != nil, "missing asset falls back to release page")

        let fallback = try AppUpdateService.releaseFromLatestPage(
            finalURL: URL(string: "https://github.com/suguxiaojie/codex-notch-monitor/releases/tag/v1.6.0")!
        )
        check(fallback.tagName == "v1.6.0", "latest page fallback extracts tag")
        check(fallback.assets.count == 2, "latest page fallback creates two architecture assets")
        check(
            AppUpdateService.selectAsset(for: fallback, architecture: .arm64)?
                .name.hasSuffix("-arm64.dmg") == true,
            "latest page fallback selects arm64"
        )
        do {
            _ = try AppUpdateService.releaseFromLatestPage(
                finalURL: URL(string: "https://example.com/releases/tag/v1.6.0")!
            )
            fail("reject external latest page redirect")
        } catch {
            check(true, "reject external latest page redirect")
        }

        print("App update tests: 41/41 passed")
    }

    private static func expectDecodeFailure(
        replacing source: String,
        with replacement: String,
        label: String
    ) throws {
        let original = String(decoding: validReleaseData(), as: UTF8.self)
        do {
            _ = try AppUpdateService.decodeRelease(
                Data(original.replacingOccurrences(of: source, with: replacement).utf8)
            )
            fail(label)
        } catch {
            check(true, label)
        }
    }

    private static func validReleaseData() -> Data {
        Data("""
        {
          "tag_name":"v1.6.0",
          "name":"Codex Notch Monitor v1.6.0",
          "body":"Release notes.",
          "draft":false,
          "prerelease":false,
          "published_at":"2026-08-27T00:00:00Z",
          "html_url":"https://github.com/suguxiaojie/codex-notch-monitor/releases/tag/v1.6.0",
          "assets":[
            {
              "name":"CodexNotchMonitor-v1.6.0-arm64.dmg",
              "label":"Apple Silicon (arm64)",
              "state":"uploaded",
              "content_type":"application/x-apple-diskimage",
              "size":5458361,
              "digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "browser_download_url":"https://github.com/suguxiaojie/codex-notch-monitor/releases/download/v1.6.0/CodexNotchMonitor-v1.6.0-arm64.dmg"
            },
            {
              "name":"CodexNotchMonitor-v1.6.0-x86_64.dmg",
              "label":"Intel Mac (x86_64)",
              "state":"uploaded",
              "content_type":"application/x-apple-diskimage",
              "size":5585536,
              "digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "browser_download_url":"https://github.com/suguxiaojie/codex-notch-monitor/releases/download/v1.6.0/CodexNotchMonitor-v1.6.0-x86_64.dmg"
            },
            {
              "name":"CodexNotchMonitor-v1.6.0-universal.dmg",
              "label":"Universal 2",
              "state":"uploaded",
              "content_type":"application/x-apple-diskimage",
              "size":7000000,
              "digest":"sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
              "browser_download_url":"https://github.com/suguxiaojie/codex-notch-monitor/releases/download/v1.6.0/CodexNotchMonitor-v1.6.0-universal.dmg"
            }
          ]
        }
        """.utf8)
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fail(label) }
    }

    private static func fail(_ label: String) -> Never {
        fputs("FAILED: \(label)\n", stderr)
        exit(1)
    }
}
