import Foundation

enum UsageAccountScope {
    static let all = "__all_accounts__"
    static let unknown = "__unknown_account__"
}

struct UsageAccountOption: Identifiable, Equatable {
    let id: String
    let alias: String
    let emailSummary: String?
    let isCurrent: Bool
}

struct UsageAccountContext: Equatable {
    let accounts: [UsageAccountOption]
    let accountIDByThread: [String: String]
}
