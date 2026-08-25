import Foundation

struct QuotaFetchSnapshot {
    let buckets: [RateLimitBucket]
    let resetCredits: QuotaResetCreditSummary?
}

final class QuotaService {
    func fetch(completion: @escaping (Result<QuotaFetchSnapshot, Error>) -> Void) {
        CodexAppServerClient.request(
            method: "account/rateLimits/read",
            timeout: 12
        ) { result in
            completion(result.map {
                QuotaFetchSnapshot(
                    buckets: Self.parseBuckets(from: $0),
                    resetCredits: Self.parseResetCredits(from: $0)
                )
            })
        }
    }

    static func resolveCodexExecutable() -> URL? {
        CodexAppServerClient.resolveCodexExecutable()
    }

    func consumeResetCredit(
        creditID: String?,
        idempotencyKey: UUID,
        completion: @escaping (Result<QuotaResetConsumeOutcome, Error>) -> Void
    ) {
        CodexAppServerClient.request(
            method: "account/rateLimitResetCredit/consume",
            params: Self.consumeResetCreditParams(
                creditID: creditID,
                idempotencyKey: idempotencyKey
            ),
            timeout: 20
        ) { result in
            completion(result.flatMap { response in
                Result { try Self.parseConsumeOutcome(from: response) }
            })
        }
    }

    static func consumeResetCreditParams(
        creditID: String?,
        idempotencyKey: UUID
    ) -> [String: Any] {
        var params: [String: Any] = [
            "idempotencyKey": idempotencyKey.uuidString,
        ]
        if let creditID { params["creditId"] = creditID }
        return params
    }

    static func parseConsumeOutcome(
        from response: [String: Any]
    ) throws -> QuotaResetConsumeOutcome {
        guard let rawOutcome = response["outcome"] as? String,
              let outcome = QuotaResetConsumeOutcome(rawValue: rawOutcome)
        else {
            throw CodexAppServerClient.ProtocolError(
                message: "额度重置响应格式无效"
            )
        }
        return outcome
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

    static func parseResetCredits(from result: [String: Any]) -> QuotaResetCreditSummary? {
        guard let value = result["rateLimitResetCredits"] as? [String: Any],
              let availableCount = integer(value["availableCount"]),
              availableCount >= 0
        else { return nil }

        let creditValues = value["credits"] as? [[String: Any]] ?? []
        let credits = creditValues.enumerated().map { index, credit in
            QuotaResetCredit(
                id: credit["id"] as? String ?? "reset-credit-\(index)",
                resetType: credit["resetType"] as? String ?? "unknown",
                status: credit["status"] as? String ?? "unknown",
                grantedAt: timestamp(credit["grantedAt"]).map(Date.init(timeIntervalSince1970:)),
                expiresAt: timestamp(credit["expiresAt"]).map(Date.init(timeIntervalSince1970:)),
                title: credit["title"] as? String,
                description: credit["description"] as? String
            )
        }
        return QuotaResetCreditSummary(
            availableCount: availableCount,
            credits: credits
        )
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

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        return (value as? NSNumber)?.intValue
    }

    private static func timestamp(_ value: Any?) -> TimeInterval? {
        if let value = value as? TimeInterval { return value }
        return (value as? NSNumber)?.doubleValue
    }
}
