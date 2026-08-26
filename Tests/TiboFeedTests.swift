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

        radarSnapshotDecodesAndMapsEvidence()
        radarSnapshotRejectsUntrustedSource()
        radarSnapshotRejectsInvalidForecast()
        pinnedSignalResolutionTracksPreviewFulfillment()

        print("Tibo feed tests passed (30 checks).")
    }

    private static func radarSnapshotDecodesAndMapsEvidence() {
        let fixture = radarFixture()
        do {
            let snapshot = try CodexResetRadarService.makeSnapshot(
                feedData: fixture.feed,
                timelineData: fixture.timeline,
                forecastData: fixture.forecast
            )
            check(snapshot.profile.handle == "thsottiaux", "decode radar profile")
            check(snapshot.tweets.count == 3, "decode live tweets")
            check(snapshot.timelineEvents.count == 3, "decode timeline events")
            check(snapshot.forecast.probabilities.rounded24H == 20, "decode 24h forecast")
            let kinds = Dictionary(uniqueKeysWithValues: snapshot.evidenceFeed.events.map {
                ($0.source.postId, $0.kind)
            })
            check(kinds["2091688655828246890"] == .resetCompleted, "archive reset becomes completed evidence")
            check(kinds["2090964822422949999"] == .bankedReset, "banked credit stays separate")
            check(kinds["2087706104814023111"] == .uncertain, "rejected candidate cannot confirm reset")
        } catch {
            fail("decode codex-reset radar snapshot: \(error.localizedDescription)")
        }
    }

    private static func radarSnapshotRejectsUntrustedSource() {
        let fixture = radarFixture()
        let badFeed = Data(String(decoding: fixture.feed, as: UTF8.self)
            .replacingOccurrences(of: "https://x.com/thsottiaux/status/2092058556707344708", with: "https://example.com/2092058556707344708")
            .utf8)
        do {
            _ = try CodexResetRadarService.makeSnapshot(
                feedData: badFeed,
                timelineData: fixture.timeline,
                forecastData: fixture.forecast
            )
            fail("reject untrusted radar URL")
        } catch {
            check(true, "reject untrusted radar URL")
        }
    }

    private static func radarSnapshotRejectsInvalidForecast() {
        let fixture = radarFixture()
        let invalid = Data(String(decoding: fixture.forecast, as: UTF8.self)
            .replacingOccurrences(of: #""rounded_24h":20"#, with: #""rounded_24h":120"#)
            .utf8)
        do {
            _ = try CodexResetRadarService.makeSnapshot(
                feedData: fixture.feed,
                timelineData: fixture.timeline,
                forecastData: invalid
            )
            fail("reject invalid forecast range")
        } catch {
            check(true, "reject invalid forecast range")
        }
    }

    private static func pinnedSignalResolutionTracksPreviewFulfillment() {
        let signalDate = "2026-08-23T06:29:05.000Z"
        let signal = CodexResetRadarSignal(
            tweetId: "2091412393368945027",
            summary: "Reset will land tomorrow.",
            at: signalDate,
            url: "https://x.com/thsottiaux/status/2091412393368945027",
            kind: "signal",
            active: false,
            localizedSummary: "重置将在明天到达。",
            translationStatus: "translated"
        )
        let preview = radarTimelineEvent(
            id: signal.tweetId,
            announcedAt: signalDate,
            preview: true,
            confidence: "medium",
            source: "live",
            officialWindow: CodexResetOfficialWindow(
                label: "around 2 PM PT",
                startAt: "2026-08-23T20:00:00.000Z",
                endAt: "2026-08-23T22:00:00.000Z",
                timeZone: "America/Los_Angeles",
                targetKind: "center",
                targetAt: "2026-08-23T21:00:00.000Z"
            ),
            announcementState: "hinted",
            verificationStatus: "pending"
        )
        let fulfillment = radarTimelineEvent(
            id: "2091688655828246890",
            announcedAt: "2026-08-24T00:46:51.000Z",
            preview: false,
            confidence: "high",
            source: "archive",
            announcementState: "announced"
        )
        let resolved = CodexResetRadarService.resolvePinnedSignal(
            signal,
            timelineEvents: [fulfillment, preview],
            now: TiboFeedDate.parse("2026-08-26T00:00:00.000Z")!
        )
        check(resolved.state == .fulfilled, "inactive preview links to later archived reset")
        check(resolved.evidenceEvent?.id == fulfillment.id, "fulfilled preview uses later evidence post")
        check(resolved.isLocallyConfirmed == false, "archive-only fulfillment is not local quota proof")

        let locallyVerified = CodexResetRadarService.resolvePinnedSignal(
            signal,
            timelineEvents: [fulfillment, preview],
            locallyConfirmedPostIDs: [fulfillment.id],
            now: TiboFeedDate.parse("2026-08-26T00:00:00.000Z")!
        )
        check(locallyVerified.isLocallyConfirmed, "matching later post retains local quota proof")

        let expired = CodexResetRadarService.resolvePinnedSignal(
            signal,
            timelineEvents: [preview],
            now: TiboFeedDate.parse("2026-08-26T00:00:00.000Z")!
        )
        check(expired.state == .expired, "inactive preview without evidence expires")

        let activeSignal = CodexResetRadarSignal(
            tweetId: signal.tweetId,
            summary: signal.summary,
            at: signal.at,
            url: signal.url,
            kind: signal.kind,
            active: true,
            localizedSummary: signal.localizedSummary,
            translationStatus: signal.translationStatus
        )
        let active = CodexResetRadarService.resolvePinnedSignal(
            activeSignal,
            timelineEvents: [preview],
            now: TiboFeedDate.parse("2026-08-23T21:00:00.000Z")!
        )
        check(active.state == .activePreview, "active preview remains a waiting announcement")

        let directlyConfirmed = CodexResetRadarService.resolvePinnedSignal(
            signal,
            timelineEvents: [preview],
            locallyConfirmedPostIDs: [signal.tweetId],
            now: TiboFeedDate.parse("2026-08-26T00:00:00.000Z")!
        )
        check(directlyConfirmed.state == .confirmed, "exact local post evidence confirms signal")

        let lateUnrelatedReset = radarTimelineEvent(
            id: "2099999999999999999",
            announcedAt: "2026-08-25T14:15:00.000Z",
            preview: false,
            confidence: "high",
            source: "archive",
            announcementState: "announced"
        )
        let outsideWindow = CodexResetRadarService.resolvePinnedSignal(
            signal,
            timelineEvents: [lateUnrelatedReset, preview],
            now: TiboFeedDate.parse("2026-08-26T00:00:00.000Z")!
        )
        check(outsideWindow.state == .expired, "later unrelated reset cannot fulfill old preview")
    }

    private static func radarTimelineEvent(
        id: String,
        announcedAt: String,
        preview: Bool,
        confidence: String,
        source: String,
        officialWindow: CodexResetOfficialWindow? = nil,
        announcementState: String? = nil,
        verificationStatus: String? = nil
    ) -> CodexResetTimelineEvent {
        CodexResetTimelineEvent(
            id: id,
            date: String(announcedAt.prefix(10)),
            type: "reset",
            group: "reset",
            summary: preview ? "Reset preview." : "Reset fulfilled.",
            url: "https://x.com/thsottiaux/status/\(id)",
            announcedAt: announcedAt,
            effectiveAt: nil,
            officialWindow: officialWindow,
            preview: preview,
            scope: "global",
            confidence: confidence,
            source: source,
            sourceLabel: source == "archive" ? "Verified archive" : "Live radar feed",
            resetKind: nil,
            bankedState: nil,
            audience: [],
            announcementState: announcementState,
            observationResult: preview ? "unknown" : "confirmed",
            resetVerificationStatus: verificationStatus,
            localizedSummary: nil,
            translationStatus: nil
        )
    }

    private static func radarFixture() -> (feed: Data, timeline: Data, forecast: Data) {
        let feed = Data("""
        {
          "version":1,
          "fetched_at":"2026-08-25T10:37:46.000Z",
          "source":"x-api",
          "source_scope":"timeline",
          "stale":false,
          "content_age_days":0.2,
          "profile":{"handle":"thsottiaux","name":"Tibo","followers":332050},
          "signal":{
            "tweet_id":"2091688655828246890","summary":"Reset propagated.",
            "at":"2026-08-24T00:46:51.000Z",
            "url":"https://x.com/thsottiaux/status/2091688655828246890",
            "kind":"candidate","active":true,
            "localized_summary":"重置已传播到账户。","translation_status":"translated"
          },
          "tweets":[
            {
              "id":"2092058556707344708","url":"https://x.com/thsottiaux/status/2092058556707344708",
              "text":"Plus 5h limit returns tomorrow.","at":"2026-08-25T01:16:43.000Z","kind":"limits",
              "replies":10,"reposts":20,"likes":30,"tibo_lane":"reset_related",
              "explicit_reset_claim":false,"localized_text":"Plus 将恢复 5 小时限额。"
            },
            {
              "id":"2091688655828246890","url":"https://x.com/thsottiaux/status/2091688655828246890",
              "text":"Reset propagated.","at":"2026-08-24T00:46:51.000Z","kind":"candidate",
              "tibo_lane":"reset_announcement","explicit_reset_claim":true,
              "localized_text":"重置已传播到账户。"
            },
            {
              "id":"2087706104814023111","url":"https://x.com/thsottiaux/status/2087706104814023111",
              "text":"Reset soon.","at":"2026-08-13T01:01:37.000Z","kind":"signal",
              "tibo_lane":"reset_related","explicit_reset_claim":false
            }
          ]
        }
        """.utf8)
        let timeline = Data("""
        {
          "updated_at":"2026-08-25T10:38:17.784Z",
          "events":[
            {
              "id":"2091688655828246890","date":"2026-08-24","type":"reset","group":"reset",
              "summary":"Reset propagated.","url":"https://x.com/thsottiaux/status/2091688655828246890",
              "announced_at":"2026-08-24T00:46:51.000Z","preview":false,"scope":"global",
              "confidence":"high","source":"archive","source_label":"Verified archive","reset_kind":"hard",
              "audience":["codex","chatgpt_work"],"localized_summary":"重置已传播到账户。"
            },
            {
              "id":"2090964822422949999","date":"2026-08-22","type":"credits","group":"credits",
              "summary":"Banked reset landed.","url":"https://x.com/thsottiaux/status/2090964822422949999",
              "announced_at":"2026-08-22T00:50:36.000Z","preview":false,"scope":"global",
              "confidence":"high","source":"archive","source_label":"Verified archive","reset_kind":"banked",
              "banked_state":"available","audience":["codex"]
            },
            {
              "id":"2087706104814023111","date":"2026-08-13","type":"reset","group":"reset",
              "summary":"Reset soon.","url":"https://x.com/thsottiaux/status/2087706104814023111",
              "announced_at":"2026-08-13T01:01:37.000Z","preview":true,"scope":"global",
              "confidence":"medium","source":"live","source_label":"Live radar feed",
              "reset_verification_status":"rejected"
            }
          ]
        }
        """.utf8)
        let forecast = Data("""
        {
          "mode":"model","updated_at":"2026-08-25T10:38:17.778Z",
          "probabilities":{"rounded_24h":20,"rounded_48h":40},
          "confidence":"low","confidence_note":"Experimental.",
          "last_reset_at":"2026-08-24T00:46:51.000Z","age_days":1.4,
          "translation_status":"translated"
        }
        """.utf8)
        return (feed, timeline, forecast)
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fail(label) }
    }

    private static func fail(_ label: String) -> Never {
        fputs("FAILED: \(label)\n", stderr)
        exit(1)
    }
}
