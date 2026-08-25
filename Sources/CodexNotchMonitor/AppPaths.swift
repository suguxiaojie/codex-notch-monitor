import Foundation

enum AppPaths {
    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexNotchMonitor", isDirectory: true)
    }

    static var eventInbox: URL {
        supportDirectory.appendingPathComponent("events", isDirectory: true)
    }

    static var accountContinuityState: URL {
        supportDirectory.appendingPathComponent("account-continuity.json")
    }

    static var continuityBackups: URL {
        supportDirectory.appendingPathComponent("continuity-backups", isDirectory: true)
    }

    static var sidebarCleanupBackups: URL {
        continuityBackups.appendingPathComponent("sidebar-cleanups", isDirectory: true)
    }

    static var pendingSidebarCleanups: URL {
        supportDirectory.appendingPathComponent("pending-sidebar-cleanups.json")
    }

    static var pendingProjectCleanups: URL {
        supportDirectory.appendingPathComponent("pending-project-cleanups.json")
    }

    static var pendingProjectSessionRepairs: URL {
        supportDirectory.appendingPathComponent("pending-project-session-repairs.json")
    }

    static var importedAttachments: URL {
        supportDirectory.appendingPathComponent("imported-attachments", isDirectory: true)
    }

    static func prepareDirectories() throws {
        try FileManager.default.createDirectory(
            at: eventInbox,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: continuityBackups,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: sidebarCleanupBackups,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createDirectory(
            at: importedAttachments,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
