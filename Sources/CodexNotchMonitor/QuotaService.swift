import Foundation

final class QuotaService {
    func fetch(completion: @escaping (Result<[RateLimitBucket], Error>) -> Void) {
        CodexAppServerClient.request(
            method: "account/rateLimits/read",
            timeout: 12
        ) { result in
            completion(result.map(Self.parseBuckets))
        }
    }

    static func resolveCodexExecutable() -> URL? {
        CodexAppServerClient.resolveCodexExecutable()
    }

    static func parseBuckets(from result: [String: Any]) -> [RateLimitBucket] {
        let multi = result["rateLimitsByLimitId"] as? [String: Any]
        let fallback = result["rateLimits"] as? [String: Any]
        var entries: [(String, [String: Any])] = []

        if let multi {
            entries = multi.compactMap { key, value in
                guard let dictionary = value as? [String: Any] else { return nil }
                return (key, dictionary)
            }
        } else if let fallback {
            entries = [((fallback["limitId"] as? String) ?? "codex", fallback)]
        }

        return entries.map { key, value in
            let credits = value["credits"] as? [String: Any]
            return RateLimitBucket(
                id: key,
                name: (value["limitName"] as? String) ?? (key == "codex" ? "Codex" : key),
                planType: value["planType"] as? String,
                primary: parseWindow(value["primary"]),
                secondary: parseWindow(value["secondary"]),
                creditBalance: credits?["balance"] as? String,
                hasCredits: credits?["hasCredits"] as? Bool ?? false
            )
        }.sorted { lhs, rhs in
            if lhs.id == "codex" { return true }
            if rhs.id == "codex" { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func parseWindow(_ value: Any?) -> RateLimitWindow? {
        guard let dictionary = value as? [String: Any],
              let used = dictionary["usedPercent"] as? Int
        else { return nil }
        let resetTimestamp = dictionary["resetsAt"] as? TimeInterval
        return RateLimitWindow(
            usedPercent: used,
            windowDurationMinutes: dictionary["windowDurationMins"] as? Int,
            resetsAt: resetTimestamp.map(Date.init(timeIntervalSince1970:))
        )
    }
}
