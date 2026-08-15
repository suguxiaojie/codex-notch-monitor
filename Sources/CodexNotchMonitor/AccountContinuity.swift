import CryptoKit
import Foundation

struct CodexAccountInfo: Equatable {
    let type: String
    let email: String?
    let planType: String?
    let observedAt: Date

    var maskedEmail: String? {
        Self.mask(email: email)
    }

    static func mask(email: String?) -> String? {
        guard let email, let at = email.firstIndex(of: "@") else { return nil }
        let local = String(email[..<at])
        let domain = String(email[email.index(after: at)...])
        guard !local.isEmpty, !domain.isEmpty else { return nil }
        return "\(local.prefix(1))***@\(domain)"
    }
}

struct ObservedAccount: Equatable {
    let fingerprint: String
    let alias: String
    let info: CodexAccountInfo
}

struct AccountTransition: Equatable {
    let previousAlias: String
    let currentAlias: String
    let detectedAt: Date
}

enum SessionOwnershipConfidence: String, Codable, Equatable {
    case observed
    case baseline
    case unknown
}

struct SessionOwnership: Codable, Equatable {
    let accountFingerprint: String?
    let accountAlias: String?
    let confidence: SessionOwnershipConfidence

    static let unknown = SessionOwnership(
        accountFingerprint: nil,
        accountAlias: nil,
        confidence: .unknown
    )

    static let baseline = SessionOwnership(
        accountFingerprint: nil,
        accountAlias: nil,
        confidence: .baseline
    )
}

final class AccountIdentityService {
    static func parseAccount(from result: [String: Any], now: Date = Date()) -> CodexAccountInfo? {
        guard let account = result["account"] as? [String: Any],
              let type = account["type"] as? String
        else { return nil }
        return CodexAccountInfo(
            type: type,
            email: account["email"] as? String,
            planType: account["planType"] as? String,
            observedAt: now
        )
    }

    func fetch(completion: @escaping (Result<CodexAccountInfo?, Error>) -> Void) {
        CodexAppServerClient.request(
            method: "account/read",
            params: ["refreshToken": false],
            timeout: 12
        ) { result in
            completion(result.map { Self.parseAccount(from: $0) })
        }
    }
}

final class AccountContinuityStore {
    struct Observation: Equatable {
        let account: ObservedAccount
        let transition: AccountTransition?
        let ownershipByThread: [String: SessionOwnership]
    }

    private struct PersistedAccount: Codable, Equatable {
        var alias: String
        var firstSeenAt: Date
        var lastSeenAt: Date
    }

    private struct PersistedOwnership: Codable, Equatable {
        var accountFingerprint: String
        var firstObservedAt: Date
    }

    private struct State: Codable, Equatable {
        var version = 1
        var salt: String
        var currentAccountFingerprint: String?
        var accounts: [String: PersistedAccount] = [:]
        var knownSessionIDs: Set<String> = []
        var sessionOwnership: [String: PersistedOwnership] = [:]
    }

    private let stateURL: URL
    private let lock = NSLock()
    private var state: State

    init(stateURL: URL = AppPaths.accountContinuityState) {
        self.stateURL = stateURL
        if let data = try? Data(contentsOf: stateURL),
           let decoded = try? JSONDecoder.codexMonitor.decode(State.self, from: data),
           decoded.version == 1 {
            state = decoded
        } else {
            state = State(salt: UUID().uuidString)
        }
    }

    func observe(account info: CodexAccountInfo, localSessionIDs: Set<String>) throws -> Observation {
        lock.lock()
        defer { lock.unlock() }

        let fingerprint = Self.fingerprint(for: info, salt: state.salt)
        let previousFingerprint = state.currentAccountFingerprint
        let previousAlias = previousFingerprint.flatMap { state.accounts[$0]?.alias }
        let now = info.observedAt

        if var account = state.accounts[fingerprint] {
            account.lastSeenAt = now
            state.accounts[fingerprint] = account
        } else {
            let alias = "账号 \(state.accounts.count + 1)"
            state.accounts[fingerprint] = PersistedAccount(
                alias: alias,
                firstSeenAt: now,
                lastSeenAt: now
            )
        }

        if state.currentAccountFingerprint == nil {
            // Existing sessions predate reliable observation and must remain
            // unknown instead of being guessed as belonging to this account.
            state.knownSessionIDs.formUnion(localSessionIDs)
        } else {
            for id in localSessionIDs.subtracting(state.knownSessionIDs) {
                state.sessionOwnership[id] = PersistedOwnership(
                    accountFingerprint: fingerprint,
                    firstObservedAt: now
                )
            }
            state.knownSessionIDs.formUnion(localSessionIDs)
        }
        state.currentAccountFingerprint = fingerprint
        try saveLocked()

        let currentAlias = state.accounts[fingerprint]?.alias ?? "当前账号"
        let transition: AccountTransition?
        if let previousFingerprint,
           previousFingerprint != fingerprint,
           let previousAlias {
            transition = AccountTransition(
                previousAlias: previousAlias,
                currentAlias: currentAlias,
                detectedAt: now
            )
        } else {
            transition = nil
        }

        return Observation(
            account: ObservedAccount(fingerprint: fingerprint, alias: currentAlias, info: info),
            transition: transition,
            ownershipByThread: ownershipLocked()
        )
    }

    func ownershipByThread() -> [String: SessionOwnership] {
        lock.lock()
        defer { lock.unlock() }
        return ownershipLocked()
    }

    func accountChanged(_ info: CodexAccountInfo) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return state.currentAccountFingerprint != Self.fingerprint(for: info, salt: state.salt)
    }

    func observedAccount(for info: CodexAccountInfo) -> ObservedAccount? {
        lock.lock()
        defer { lock.unlock() }
        let fingerprint = Self.fingerprint(for: info, salt: state.salt)
        guard let account = state.accounts[fingerprint] else { return nil }
        return ObservedAccount(fingerprint: fingerprint, alias: account.alias, info: info)
    }

    func currentAccountAlias() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let fingerprint = state.currentAccountFingerprint else { return nil }
        return state.accounts[fingerprint]?.alias
    }

    private func ownershipLocked() -> [String: SessionOwnership] {
        var result = state.knownSessionIDs.reduce(into: [String: SessionOwnership]()) {
            $0[$1] = .baseline
        }
        state.sessionOwnership.forEach { entry in
            let alias = state.accounts[entry.value.accountFingerprint]?.alias
            result[entry.key] = SessionOwnership(
                accountFingerprint: entry.value.accountFingerprint,
                accountAlias: alias,
                confidence: .observed
            )
        }
        return result
    }

    static func fingerprint(for info: CodexAccountInfo, salt: String) -> String {
        let identity = info.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ?? "\(info.type)|\(info.planType ?? "unknown")"
        let digest = SHA256.hash(data: Data("\(salt)|\(identity)|\(info.type)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func saveLocked() throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder.codexMonitor.encode(state)
        try data.write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
}

private extension JSONEncoder {
    static var codexMonitor: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var codexMonitor: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
