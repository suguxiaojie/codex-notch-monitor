import Foundation

struct RelayEvent: Codable {
    let sessionID: String
    let turnID: String?
    let cwd: String
    let hookEventName: String
    let model: String?
    let toolName: String?
    let receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case turnID = "turn_id"
        case cwd
        case hookEventName = "hook_event_name"
        case model
        case toolName = "tool_name"
        case receivedAt = "received_at"
    }
}

struct IncomingEvent: Decodable {
    let sessionID: String
    let turnID: String?
    let cwd: String
    let hookEventName: String
    let model: String?
    let toolName: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case turnID = "turn_id"
        case cwd
        case hookEventName = "hook_event_name"
        case model
        case toolName = "tool_name"
    }
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let incoming = try? JSONDecoder().decode(IncomingEvent.self, from: input) else {
    exit(0)
}

let event = RelayEvent(
    sessionID: incoming.sessionID,
    turnID: incoming.turnID,
    cwd: incoming.cwd,
    hookEventName: incoming.hookEventName,
    model: incoming.model,
    toolName: incoming.toolName,
    receivedAt: Date()
)

let manager = FileManager.default
let inbox = manager.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CodexNotchMonitor/events", isDirectory: true)
try? manager.createDirectory(
    at: inbox,
    withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700]
)

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
if let data = try? encoder.encode(event) {
    let filename = String(format: "%.3f", Date().timeIntervalSince1970) + "-" + UUID().uuidString + ".json"
    let destination = inbox.appendingPathComponent(filename)
    try? data.write(to: destination, options: [.atomic])
}

exit(0)
