import Foundation

@main
enum PricingCatalogTests {
    static func main() async {
        let rates = CatalogRates(
            displayName: "Test Model",
            inputPerMillion: 1,
            outputPerMillion: 2,
            cacheCreationPerMillion: 1.25,
            cacheReadPerMillion: 0.1
        )
        let payload = CatalogPayload(
            schemaVersion: 1,
            generatedAt: "2026-08-12T00:00:00Z",
            models: ["test-model": rates]
        )
        let data = try! JSONEncoder().encode(payload)

        check(PricingCatalog.interpret(status: 200, data: data) == .payload(payload), "accept valid catalog")
        check(PricingCatalog.interpret(status: 304, data: Data()) == .unchanged, "accept 304")
        check(PricingCatalog.interpret(status: 500, data: data) == .rejected("HTTP 500"), "reject HTTP error")
        check(PricingCatalog.interpret(status: 200, data: Data("{}".utf8)) == .rejected("malformed JSON"), "reject malformed schema")
        check(ModelPricing.canonicalModelName("GPT-5.3-Codex-20260812") == "gpt-5.3-codex", "strip date suffix")
        check(ModelPricing.resolvedRates(for: "gpt-5.6-sol") != nil, "embedded fallback")
        check(ModelPricing.resolvedRates(for: "codex-auto-review") == nil, "do not invent unknown price")
        check(
            ModelPricing.billingModel(
                for: "codex-auto-review",
                currentPrimaryModel: "gpt-5.6-sol"
            ) == "gpt-5.6-sol",
            "attribute auto review to current primary model"
        )
        check(
            ModelPricing.billingModel(for: "unknown-model", currentPrimaryModel: "gpt-5.6-sol") == "unknown-model",
            "do not alias unrelated unknown models"
        )

        let temporaryCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-notch-catalog-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporaryCache) }
        let response = HTTPURLResponse(
            url: PricingCatalog.endpoint,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["ETag": "test-etag"]
        )!
        let firstRefresh = await PricingCatalog.refreshIfNeeded(
            now: Date(timeIntervalSince1970: 1_800_000_000),
            cache: temporaryCache,
            fetch: { _ in (data, response) }
        )
        check(firstRefresh == .updated, "install downloaded catalog")
        check(FileManager.default.fileExists(atPath: temporaryCache.path), "persist catalog cache")
        check(ModelPricing.resolvedRates(for: "test-model") == rates, "remote catalog takes precedence")

        print("Pricing catalog tests passed (12 checks).")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else {
            fputs("FAILED: \(label)\n", stderr)
            exit(1)
        }
    }
}
