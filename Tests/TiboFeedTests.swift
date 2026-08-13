import Foundation

@main
enum TiboFeedTests {
    static func main() {
        let valid = Data("""
        {
          "schemaVersion": 1,
          "generatedAt": "2026-08-13T04:27:02.155Z",
          "lastSuccessfulCheckAt": "2026-08-13T04:27:02.155Z",
          "monitor": {"status":"ok","errorCode":null},
          "events": [{
            "kind":"reset_scheduled",
            "announcedAt":"2026-08-13T01:01:37.000Z",
            "effectiveAt":"2026-08-13T02:01:37.000Z",
            "scope":{"plans":["all"],"windows":["unknown"]},
            "source":{"handle":"thsottiaux","postId":"2087706104814023111","url":"https://x.com/thsottiaux/status/2087706104814023111"},
            "confidence":0.97,
            "rationale":"Explicit Codex quota reset schedule.",
            "text":"Landing in the next hour or so."
          }]
        }
        """.utf8)

        guard case let .feed(feed) = TiboFeedService.interpret(status: 200, data: valid) else {
            fail("accept valid feed")
        }
        check(feed.events.count == 1, "decode event")
        check(feed.events[0].announcedDate != nil, "parse fractional ISO date")
        check(feed.events[0].effectiveDate != nil, "parse effective date")
        check(TiboFeedService.interpret(status: 304, data: Data()) == .unchanged, "accept 304")
        check(
            TiboFeedService.interpret(status: 500, data: valid) == .rejected("HTTP 500"),
            "reject HTTP error"
        )

        let wrongSource = Data(String(decoding: valid, as: UTF8.self)
            .replacingOccurrences(of: "thsottiaux", with: "someoneelse").utf8)
        check(
            TiboFeedService.interpret(status: 200, data: wrongSource)
                == .rejected("事件来源校验失败"),
            "reject untrusted account"
        )

        let wrongURL = Data(String(decoding: valid, as: UTF8.self)
            .replacingOccurrences(of: "https://x.com/thsottiaux/status/", with: "https://example.com/").utf8)
        check(
            TiboFeedService.interpret(status: 200, data: wrongURL)
                == .rejected("事件来源校验失败"),
            "reject noncanonical source URL"
        )

        print("Tibo feed tests passed (7 checks).")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fail(label) }
    }

    private static func fail(_ label: String) -> Never {
        fputs("FAILED: \(label)\n", stderr)
        exit(1)
    }
}
