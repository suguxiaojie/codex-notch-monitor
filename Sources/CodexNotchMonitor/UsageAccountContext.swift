import Foundation

enum UsageAccountScope {
    static let all = "__all_accounts__"
    static let unknown = "__unknown_account__"
}

enum UsageAccountSelection {
    static func currentAccountID(in options: [UsageAccountOption]) -> String? {
        options.first(where: \.isCurrent)?.id
    }
}

struct UsageAccountOption: Identifiable, Equatable {
    let id: String
    let alias: String
    let emailSummary: String?
    let isCurrent: Bool
}

struct UsageAccountObservation: Equatable {
    let accountID: String
    let startsAt: Date
}

struct UsageAccountContext: Equatable {
    let accounts: [UsageAccountOption]
    let accountIDByThread: [String: String]
    let accountTimeline: [UsageAccountObservation]

    func accountID(for sessionID: String, at timestamp: Date) -> String? {
        if let observation = accountTimeline.last(where: { $0.startsAt <= timestamp }) {
            return observation.accountID
        }
        return accountIDByThread[sessionID]
    }
}
