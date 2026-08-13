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

        let timelineFixture = Data("""
        {
          "schemaVersion":1,
          "generatedAt":"2026-08-13T11:00:02.869Z",
          "lastSuccessfulCheckAt":"2026-08-13T11:00:02.869Z",
          "monitor":{"status":"ok","errorCode":null},
          "events":[{
            "kind":"reset_completed",
            "announcedAt":"2026-08-11T00:27:44.000Z",
            "effectiveAt":null,
            "scope":{"plans":["all"],"windows":["unknown"]},
            "source":{"handle":"thsottiaux","postId":"2086972802457063486","url":"https://x.com/thsottiaux/status/2086972802457063486"},
            "confidence":0.97,
            "rationale":"Explicit reset.",
            "text":"Hi. It is done."
          }],
          "resetTimeline":{
            "nextSchedule":null,
            "recentNonCompletedPostId":null,
            "fulfilledSchedules":[],
            "manualCompletions":[{
              "id":"manual:latest",
              "completedAt":"2026-08-13T04:35:00.000Z",
              "visibleUntil":"2026-08-23T04:35:00.000Z",
              "representativePostId":"2087706104814023111",
              "schedulePostIds":["2087423996115681767","2087706104814023111"],
              "schedules":[
                {
                  "kind":"reset_scheduled",
                  "announcedAt":"2026-08-12T06:20:37.000Z",
                  "effectiveAt":"2026-08-12T07:00:00.000Z",
                  "scope":{"plans":["all"],"windows":["unknown"]},
                  "source":{"handle":"thsottiaux","postId":"2087423996115681767","url":"https://x.com/thsottiaux/status/2087423996115681767"},
                  "confidence":0.8,
                  "rationale":"Schedule.",
                  "text":"Little surprise for you tomorrow."
                },
                {
                  "kind":"reset_scheduled",
                  "announcedAt":"2026-08-13T01:01:37.000Z",
                  "effectiveAt":"2026-08-13T02:01:37.000Z",
                  "scope":{"plans":["all"],"windows":["unknown"]},
                  "source":{"handle":"thsottiaux","postId":"2087706104814023111","url":"https://x.com/thsottiaux/status/2087706104814023111"},
                  "confidence":0.97,
                  "rationale":"Schedule.",
                  "text":"Landing in the next hour or so."
                }
              ],
              "fulfillmentOrigin":"manual"
            }],
            "suppressedPostIds":["2087423996115681767","2087706104814023111"]
          }
        }
        """.utf8)
        guard case let .feed(timelineFeed) = TiboFeedService.interpret(status: 200, data: timelineFixture) else {
            fail("decode resetTimeline feed")
        }
        let displayAt = TiboFeedDate.parse("2026-08-13T11:05:00.000Z")!
        let displayEvents = timelineFeed.displayEvents(now: displayAt)
        check(displayEvents.count == 2, "manual completion joins ordinary timeline")
        check(displayEvents.first?.isManualCompletion == true, "manual completion is pinned first")
        check(displayEvents.first?.event.source.postId == "2087706104814023111", "representative post is preserved")
        check(displayEvents.first?.supportingSchedules.count == 2, "manual completion retains schedule evidence")
        check(!displayEvents.contains(where: { $0.event.kind == .resetScheduled }), "suppressed schedules do not duplicate")
        check(timelineFeed.officialEvidenceEvents(now: displayAt).first?.kind == .resetCompleted, "manual completion becomes reset evidence")

        print("Tibo feed tests passed (13 checks).")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fail(label) }
    }

    private static func fail(_ label: String) -> Never {
        fputs("FAILED: \(label)\n", stderr)
        exit(1)
    }
}
