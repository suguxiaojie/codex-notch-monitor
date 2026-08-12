import Foundation

enum ModelPricing {
    typealias Rates = CatalogRates

    /// Codex-only build-time fallback. The daily catalog takes precedence and
    /// can add or update models without requiring an app release.
    private static let seed: [String: Rates] = [
        "gpt-5.6": rates(5, 30, 6.25, 0.50),
        "gpt-5.6-sol": rates(5, 30, 6.25, 0.50),
        "gpt-5.6-terra": rates(2.5, 15, 3.125, 0.25),
        "gpt-5.6-luna": rates(1, 6, 1.25, 0.10),
        "gpt-5.5": rates(5, 30, 5, 0.50),
        "gpt-5.4": rates(2.5, 15, 2.5, 0.25),
        "gpt-5.2": rates(1.75, 14, 1.75, 0.175),
        "gpt-5.1": rates(1.25, 10, 1.25, 0.125),
        "gpt-5": rates(1.25, 10, 1.25, 0.125),
        "gpt-5.3-codex": rates(1.75, 14, 1.75, 0.175),
        "gpt-5.2-codex": rates(1.75, 14, 1.75, 0.175),
        "gpt-5.1-codex": rates(1.25, 10, 1.25, 0.125),
        "gpt-5.1-codex-max": rates(1.25, 10, 1.25, 0.125),
        "gpt-5.1-codex-mini": rates(0.25, 2, 0.25, 0.025),
        "gpt-5-codex": rates(1.25, 10, 1.25, 0.125),
        "gpt-5.4-mini": rates(0.75, 4.5, 0.75, 0.075),
        "gpt-5.4-nano": rates(0.2, 1.25, 0.2, 0.02),
        "gpt-5-mini": rates(0.25, 2, 0.25, 0.025),
        "gpt-5-nano": rates(0.05, 0.4, 0.05, 0.005),
        "gpt-5.5-pro": rates(30, 180, 30, 3),
        "gpt-5.4-pro": rates(30, 180, 30, 3),
        "gpt-5.2-pro": rates(21, 168, 21, 0),
        "gpt-5-pro": rates(15, 120, 15, 0),
    ]

    static func resolvedRates(for rawModel: String) -> Rates? {
        let canonical = canonicalModelName(rawModel)
        return PricingCatalog.rates(for: canonical) ?? seed[canonical]
    }

    static func isInternalAutomaticModel(_ rawModel: String) -> Bool {
        canonicalModelName(rawModel) == "codex-auto-review"
    }

    /// Codex writes automatic review work under a routing name rather than a
    /// public billable model id. Attribute that work to the primary model in
    /// effect beside it in the local timeline, as requested by the user.
    static func billingModel(for rawModel: String, currentPrimaryModel: String?) -> String {
        guard isInternalAutomaticModel(rawModel), let currentPrimaryModel else {
            return rawModel
        }
        return currentPrimaryModel
    }

    static func canonicalModelName(_ rawModel: String) -> String {
        let raw = rawModel.lowercased()
        guard raw.count > 9 else { return raw }
        let suffixStart = raw.index(raw.endIndex, offsetBy: -9)
        let suffix = raw[suffixStart...]
        guard suffix.first == "-", suffix.dropFirst().allSatisfy(\.isNumber) else {
            return raw
        }
        return String(raw[..<suffixStart])
    }

    private static func rates(_ input: Double, _ output: Double, _ create: Double, _ read: Double) -> Rates {
        Rates(
            displayName: nil,
            inputPerMillion: input,
            outputPerMillion: output,
            cacheCreationPerMillion: create,
            cacheReadPerMillion: read
        )
    }
}
