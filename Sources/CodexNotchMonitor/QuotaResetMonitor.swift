import Foundation

enum QuotaResetReason: String, Codable, Equatable {
    case officialCompleted
    case officialScheduled
    case natural
    case mixed
    case manualCredit
    case userConfirmed
    case unverified

    var title: String {
        switch self {
        case .officialCompleted, .officialScheduled, .mixed: return "Tibo 重置"
        case .natural: return "到期重置"
        case .manualCredit: return "手动重置"
        case .userConfirmed: return "手动重置"
        case .unverified: return "待确认重置"
        }
    }

    var isNotifiable: Bool { self != .unverified }

    var defaultDisplayType: QuotaResetDisplayType? {
        switch self {
        case .officialCompleted, .officialScheduled, .mixed: return .tibo
        case .natural: return .natural
        case .manualCredit, .userConfirmed: return .manual
        case .unverified: return nil
        }
    }
}

enum QuotaResetDisplayType: String, Codable, CaseIterable, Identifiable {
    case tibo
    case natural
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tibo: return "Tibo 重置"
        case .natural: return "到期重置"
        case .manual: return "手动重置"
        }
    }

    var representativeReason: QuotaResetReason {
        switch self {
        case .tibo: return .officialCompleted
        case .natural: return .natural
        case .manual: return .userConfirmed
        }
    }
}

struct QuotaResetConfirmationCandidate: Identifiable, Equatable {
    let id: String
    let detectedAt: Date
    let changes: [QuotaResetChange]
}

struct QuotaResetChange: Codable, Equatable {
    let bucketID: String
    let bucketName: String
    let windowDurationMinutes: Int?
    let previousRemainingPercent: Int
    let currentRemainingPercent: Int

    var windowLabel: String {
        RateLimitWindow(
            usedPercent: 0,
            windowDurationMinutes: windowDurationMinutes,
            resetsAt: nil
        ).windowLabel
    }
}

struct QuotaResetEvent: Codable, Identifiable, Equatable {
    let id: String
    let detectedAt: Date
    let reason: QuotaResetReason
    let changes: [QuotaResetChange]
    let sourcePostID: String?
    let sourceURL: String?
    var userDisplayType: QuotaResetDisplayType?

    init(
        id: String,
        detectedAt: Date,
        reason: QuotaResetReason,
        changes: [QuotaResetChange],
        sourcePostID: String?,
        sourceURL: String?,
        userDisplayType: QuotaResetDisplayType? = nil
    ) {
        self.id = id
        self.detectedAt = detectedAt
        self.reason = reason
        self.changes = changes
        self.sourcePostID = sourcePostID
        self.sourceURL = sourceURL
        self.userDisplayType = userDisplayType
    }

    var displayReason: QuotaResetReason {
        userDisplayType?.representativeReason ?? reason
    }
}

struct QuotaResetEvaluation {
    let events: [QuotaResetEvent]
    let needsFeedRefresh: Bool
}

/// Detects quota recovery from consecutive server snapshots. A jump to 100%
/// is only notification-worthy when the old reset deadline or a recent Tibo
/// post corroborates it. Unverified jumps are retained briefly for a delayed
/// feed refresh, which prevents account switches and transient API responses
/// from producing misleading banners.
final class QuotaResetMonitor {
    private struct WindowSnapshot: Codable, Equatable {
        let id: String
        let bucketID: String
        let bucketName: String
        let windowDurationMinutes: Int?
        let remainingPercent: Int
        let resetsAt: Date?
    }

    private struct Snapshot: Codable {
        let capturedAt: Date
        let contextSignature: String
        let windows: [WindowSnapshot]
    }

    private struct Pending: Codable {
        let detectedAt: Date
        let changes: [QuotaResetChange]
    }

    private struct State: Codable {
        var snapshot: Snapshot?
        var pending: [Pending]
        var history: [QuotaResetEvent]
        var manualResetRequestedAt: Date?
    }

    private let stateURL: URL
    private var state: State

    init(stateURL: URL = AppPaths.supportDirectory.appendingPathComponent("quota-reset-state.json")) {
        self.stateURL = stateURL
        self.state = Self.load(from: stateURL) ?? State(
            snapshot: nil,
            pending: [],
            history: [],
            manualResetRequestedAt: nil
        )
    }

    var history: [QuotaResetEvent] { state.history }

    var confirmableRecoveries: [QuotaResetConfirmationCandidate] {
        var seen = Set<String>()
        let candidates = state.pending.map { pending in
            Self.confirmationCandidate(detectedAt: pending.detectedAt, changes: pending.changes)
        } + state.history.compactMap { event in
            guard event.reason == .unverified else { return nil }
            return Self.confirmationCandidate(detectedAt: event.detectedAt, changes: event.changes)
        }
        return candidates
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.detectedAt > $1.detectedAt }
    }

    func confirmUserReset(candidateID: String) -> QuotaResetEvent? {
        if let index = state.pending.firstIndex(where: {
            Self.confirmationCandidate(detectedAt: $0.detectedAt, changes: $0.changes).id == candidateID
        }) {
            let pending = state.pending.remove(at: index)
            let event = record(
                changes: pending.changes,
                reason: .userConfirmed,
                source: nil,
                now: pending.detectedAt
            )
            persist()
            return event
        }

        if let index = state.history.firstIndex(where: { event in
            event.reason == .unverified
                && Self.confirmationCandidate(detectedAt: event.detectedAt, changes: event.changes).id == candidateID
        }) {
            let unverified = state.history.remove(at: index)
            let event = record(
                changes: unverified.changes,
                reason: .userConfirmed,
                source: nil,
                now: unverified.detectedAt
            )
            persist()
            return event
        }
        return nil
    }

    func markManualResetRequested(at date: Date = Date()) {
        state.manualResetRequestedAt = date
        persist()
    }

    func setDisplayType(
        eventID: String,
        displayType: QuotaResetDisplayType?
    ) -> QuotaResetEvent? {
        guard let index = state.history.firstIndex(where: { $0.id == eventID }) else {
            return nil
        }
        let normalizedDisplayType = displayType == state.history[index].reason.defaultDisplayType
            ? nil
            : displayType
        let previous = state.history[index].userDisplayType
        guard previous != normalizedDisplayType else { return state.history[index] }

        do {
            try backupStateBeforeClassificationChange()
            state.history[index].userDisplayType = normalizedDisplayType
            try writeState()
            return state.history[index]
        } catch {
            state.history[index].userDisplayType = previous
            return nil
        }
    }

    func evaluate(buckets: [RateLimitBucket], feed: TiboFeed?, now: Date = Date()) -> QuotaResetEvaluation {
        if let requestedAt = state.manualResetRequestedAt,
           now.timeIntervalSince(requestedAt) > 10 * 60 {
            state.manualResetRequestedAt = nil
        }
        let hasManualResetEvidence = state.manualResetRequestedAt.map {
            now.timeIntervalSince($0) >= -60 && now.timeIntervalSince($0) <= 10 * 60
        } ?? false
        let current = makeSnapshot(buckets: buckets, now: now)
        var events = expirePending(now: now)

        guard let previous = state.snapshot,
              now.timeIntervalSince(previous.capturedAt) <= 6 * 60 * 60,
              previous.contextSignature == current.contextSignature else {
            state.snapshot = current
            persist()
            return QuotaResetEvaluation(events: events, needsFeedRefresh: false)
        }

        let oldByID = Dictionary(uniqueKeysWithValues: previous.windows.map { ($0.id, $0) })
        var changes: [QuotaResetChange] = []
        var naturalEvidence = false

        for window in current.windows {
            guard let old = oldByID[window.id],
                  window.remainingPercent >= 99,
                  old.remainingPercent <= 95,
                  window.remainingPercent - old.remainingPercent >= 5 else { continue }

            changes.append(QuotaResetChange(
                bucketID: window.bucketID,
                bucketName: window.bucketName,
                windowDurationMinutes: window.windowDurationMinutes,
                previousRemainingPercent: old.remainingPercent,
                currentRemainingPercent: window.remainingPercent
            ))
            naturalEvidence = naturalEvidence || isNaturalReset(old: old, current: window, now: now)
        }

        state.snapshot = current
        guard !changes.isEmpty else {
            persist()
            return QuotaResetEvaluation(events: events, needsFeedRefresh: false)
        }

        if hasManualResetEvidence {
            state.manualResetRequestedAt = nil
            if let event = record(changes: changes, reason: .manualCredit, source: nil, now: now) {
                events.append(event)
            }
        } else if let official = matchingOfficialEvent(in: feed, since: previous.capturedAt, now: now) {
            let reason: QuotaResetReason
            if naturalEvidence {
                reason = .mixed
            } else {
                reason = official.kind == .resetCompleted ? .officialCompleted : .officialScheduled
            }
            if let event = record(changes: changes, reason: reason, source: official, now: now) {
                events.append(event)
            }
        } else if naturalEvidence {
            if let event = record(changes: changes, reason: .natural, source: nil, now: now) {
                events.append(event)
            }
        } else {
            state.pending.append(Pending(detectedAt: now, changes: changes))
        }

        persist()
        return QuotaResetEvaluation(events: events, needsFeedRefresh: !state.pending.isEmpty)
    }

    func reconcile(feed: TiboFeed, now: Date = Date()) -> [QuotaResetEvent] {
        var events = expirePending(now: now)
        var remaining: [Pending] = []

        for pending in state.pending {
            if let official = matchingOfficialEvent(in: feed, since: pending.detectedAt.addingTimeInterval(-30 * 60), now: now),
               let event = record(
                    changes: pending.changes,
                    reason: official.kind == .resetCompleted ? .officialCompleted : .officialScheduled,
                    source: official,
                    now: pending.detectedAt
               ) {
                events.append(event)
            } else {
                remaining.append(pending)
            }
        }
        state.pending = remaining
        persist()
        return events
    }

    private func makeSnapshot(buckets: [RateLimitBucket], now: Date) -> Snapshot {
        let signature = buckets
            .map { "\($0.id):\($0.planType ?? "-")" }
            .sorted()
            .joined(separator: "|")
        let windows = buckets.flatMap { bucket in
            bucket.windows.enumerated().map { index, window in
                let duration = window.windowDurationMinutes.map(String.init) ?? "unknown-\(index)"
                return WindowSnapshot(
                    id: "\(bucket.id)|\(duration)",
                    bucketID: bucket.id,
                    bucketName: bucket.name,
                    windowDurationMinutes: window.windowDurationMinutes,
                    remainingPercent: window.remainingPercent,
                    resetsAt: window.resetsAt
                )
            }
        }
        return Snapshot(capturedAt: now, contextSignature: signature, windows: windows)
    }

    private func isNaturalReset(old: WindowSnapshot, current: WindowSnapshot, now: Date) -> Bool {
        guard let oldReset = old.resetsAt else { return false }
        let secondsAfterDeadline = now.timeIntervalSince(oldReset)
        guard secondsAfterDeadline >= -2 * 60, secondsAfterDeadline <= 6 * 60 * 60 else { return false }
        guard let newReset = current.resetsAt, newReset > oldReset, newReset > now else { return false }

        if let duration = old.windowDurationMinutes {
            return newReset.timeIntervalSince(oldReset) >= Double(duration * 60) * 0.5
        }
        return true
    }

    private func matchingOfficialEvent(in feed: TiboFeed?, since: Date, now: Date) -> TiboEvent? {
        guard let feed else { return nil }
        return feed.officialEvidenceEvents(now: now)
            .filter { event in
                switch event.kind {
                case .resetCompleted:
                    guard let announced = event.announcedDate else { return false }
                    return announced >= since.addingTimeInterval(-30 * 60)
                        && announced <= now.addingTimeInterval(30 * 60)
                case .resetScheduled:
                    if let effective = event.effectiveDate {
                        return abs(effective.timeIntervalSince(now)) <= 3 * 60 * 60
                    }
                    guard let announced = event.announcedDate else { return false }
                    return announced >= now.addingTimeInterval(-12 * 60 * 60)
                        && announced <= now.addingTimeInterval(30 * 60)
                default:
                    return false
                }
            }
            .sorted { ($0.announcedDate ?? .distantPast) > ($1.announcedDate ?? .distantPast) }
            .first
    }

    private func expirePending(now: Date) -> [QuotaResetEvent] {
        var expiredEvents: [QuotaResetEvent] = []
        var remaining: [Pending] = []
        for pending in state.pending {
            if now.timeIntervalSince(pending.detectedAt) > 3 * 60 * 60 {
                if let event = record(changes: pending.changes, reason: .unverified, source: nil, now: pending.detectedAt) {
                    expiredEvents.append(event)
                }
            } else {
                remaining.append(pending)
            }
        }
        state.pending = remaining
        return expiredEvents
    }

    private func record(
        changes: [QuotaResetChange],
        reason: QuotaResetReason,
        source: TiboEvent?,
        now: Date
    ) -> QuotaResetEvent? {
        let identities = changes
            .map { "\($0.bucketID)-\($0.windowDurationMinutes ?? -1)" }
            .sorted()
            .joined(separator: "+")
        let evidence = source?.source.postId ?? String(Int(now.timeIntervalSince1970 / 60))
        let id = "\(reason.rawValue)|\(evidence)|\(identities)"
        guard !state.history.contains(where: { $0.id == id }) else { return nil }

        let event = QuotaResetEvent(
            id: id,
            detectedAt: now,
            reason: reason,
            changes: changes,
            sourcePostID: source?.source.postId,
            sourceURL: source?.source.url
        )
        state.history.insert(event, at: 0)
        state.history = Array(state.history.prefix(50))
        return event
    }

    private static func confirmationCandidate(
        detectedAt: Date,
        changes: [QuotaResetChange]
    ) -> QuotaResetConfirmationCandidate {
        let identities = changes
            .map { "\($0.bucketID)-\($0.windowDurationMinutes ?? -1)" }
            .sorted()
            .joined(separator: "+")
        let milliseconds = Int64((detectedAt.timeIntervalSince1970 * 1_000).rounded())
        return QuotaResetConfirmationCandidate(
            id: "quota-recovery|\(milliseconds)|\(identities)",
            detectedAt: detectedAt,
            changes: changes
        )
    }

    private func persist() {
        try? writeState()
    }

    private func writeState() throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    private func backupStateBeforeClassificationChange() throws {
        let directory = stateURL.deletingLastPathComponent()
            .appendingPathComponent("quota-reset-backups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let backupURL = directory.appendingPathComponent(
            "quota-reset-state-before-type-change-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8)).json"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: backupURL, options: .atomic)
    }

    private static func load(from url: URL) -> State? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var decoded = try? decoder.decode(State.self, from: data) else {
            return nil
        }
        for index in decoded.history.indices
        where decoded.history[index].userDisplayType
            == decoded.history[index].reason.defaultDisplayType {
            decoded.history[index].userDisplayType = nil
        }
        return decoded
    }
}
