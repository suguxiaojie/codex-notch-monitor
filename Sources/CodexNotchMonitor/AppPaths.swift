import Foundation

enum AppPaths {
    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexNotchMonitor", isDirectory: true)
    }

    static var eventInbox: URL {
        supportDirectory.appendingPathComponent("events", isDirectory: true)
    }

    static func prepareDirectories() throws {
        try FileManager.default.createDirectory(
            at: eventInbox,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
