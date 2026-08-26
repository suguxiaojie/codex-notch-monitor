import CryptoKit
import Foundation
import Security

enum CodexSetupHookState: Equatable {
    case checking
    case codexUnavailable
    case helperUnavailable
    case invalidHooksFile
    case notInstalled
    case updateRequired
    case trustStatusUnknown
    case securityReviewRequired
    case waitingForFirstEvent
    case connected

    var title: String {
        switch self {
        case .checking: return "正在检查"
        case .codexUnavailable: return "未找到 Codex"
        case .helperUnavailable: return "Hook Helper 不可用"
        case .invalidHooksFile: return "Hooks 配置无法解析"
        case .notInstalled: return "尚未安装"
        case .updateRequired: return "需要更新 Hook"
        case .trustStatusUnknown: return "待确认 Hooks 状态"
        case .securityReviewRequired: return "需要安全审核"
        case .waitingForFirstEvent: return "等待首条真实消息"
        case .connected: return "连接正常"
        }
    }

    var onboardingStepMode: CodexSetupHooksStepMode {
        switch self {
        case .notInstalled, .updateRequired: return .install
        case .trustStatusUnknown, .securityReviewRequired: return .review
        case .waitingForFirstEvent, .connected: return .advance
        case .codexUnavailable, .helperUnavailable, .invalidHooksFile: return .deferOnly
        case .checking: return .checking
        }
    }

    var needsTrustConfirmation: Bool {
        self == .trustStatusUnknown || self == .securityReviewRequired
    }

    var reviewActionTitle: String {
        switch self {
        case .trustStatusUnknown: return "检查 Hooks 状态"
        case .securityReviewRequired: return "去安全审核"
        default: return "打开 Hooks 管理"
        }
    }
}

enum CodexSetupHooksStepMode: Equatable {
    case install
    case review
    case advance
    case deferOnly
    case checking
}

struct CodexSetupSnapshot: Equatable {
    let hookState: CodexSetupHookState
    let codexExecutableURL: URL?
    let sourceHelperURL: URL?
    let installedHelperURL: URL
    let hooksURL: URL
    let installationIdentifier: String?
    let hookDefinitionChanged: Bool
    let lastConnectedAt: Date?
}

struct CodexSetupInstallResult: Equatable {
    let hooksBackupURL: URL?
    let helperBackupURL: URL?
    let hooksURL: URL
    let helperURL: URL
    let installationIdentifier: String
}

enum CodexSetupError: LocalizedError, Equatable {
    case codexUnavailable
    case helperUnavailable
    case invalidHooksFile
    case unsafePath
    case couldNotPrepareLauncher

    var errorDescription: String? {
        switch self {
        case .codexUnavailable: return "未找到可用的 Codex CLI。"
        case .helperUnavailable: return "安装包中缺少 CodexMonitorHook。"
        case .invalidHooksFile: return "现有 hooks.json 无法解析；为保护其他 Hooks，未做修改。"
        case .unsafePath: return "Hook 目标路径不安全，已停止操作。"
        case .couldNotPrepareLauncher: return "无法准备 Codex Hooks 安全审核启动器。"
        }
    }
}

struct CodexSetupPaths {
    let codexHome: URL
    let supportDirectory: URL
    let sourceHelperURL: URL
    let codexExecutableCandidates: [URL]

    static func live(bundleURL: URL = Bundle.main.bundleURL) -> Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Self(
            codexHome: ProcessInfo.processInfo.environment["CODEX_HOME"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? home.appendingPathComponent(".codex", isDirectory: true),
            supportDirectory: AppPaths.supportDirectory,
            sourceHelperURL: bundleURL
                .appendingPathComponent("Contents/Helpers/CodexMonitorHook"),
            codexExecutableCandidates: [
                URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
                URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            ]
        )
    }

    var hooksURL: URL { codexHome.appendingPathComponent("hooks.json") }
    var helperDirectory: URL {
        supportDirectory.appendingPathComponent("Helpers", isDirectory: true)
    }
    var installedHelperURL: URL {
        helperDirectory.appendingPathComponent("CodexMonitorHook")
    }
    var backupDirectory: URL {
        supportDirectory.appendingPathComponent("setup-backups", isDirectory: true)
    }
    var launcherDirectory: URL {
        supportDirectory.appendingPathComponent("Launchers", isDirectory: true)
    }
    var reviewResultURL: URL {
        launcherDirectory.appendingPathComponent("CodexMonitorHookReviewComplete")
    }
    var reviewExpectURL: URL {
        launcherDirectory.appendingPathComponent("Open Codex Hooks Review.expect")
    }
}

final class CodexSetupService: @unchecked Sendable {
    static let hookEvents = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PermissionRequest",
        "SubagentStart",
        "SubagentStop",
        "Stop",
    ]

    private enum PreferenceKey {
        static let reviewedInstallation = "setup.hooks.reviewedInstallation"
        static let connectedInstallation = "setup.hooks.connectedInstallation"
        static let lastConnectedAt = "setup.hooks.lastConnectedAt"
        static let onboardingCompleted = "setup.onboarding.completed"
    }

    let paths: CodexSetupPaths
    private let defaults: UserDefaults
    private let manager: FileManager
    private let enforceLivePathSafety: Bool
    private let codeIdentityProvider: ((URL) -> Data?)?

    init(
        paths: CodexSetupPaths = .live(),
        defaults: UserDefaults = .standard,
        manager: FileManager = .default,
        enforceLivePathSafety: Bool = true,
        codeIdentityProvider: ((URL) -> Data?)? = nil
    ) {
        self.paths = paths
        self.defaults = defaults
        self.manager = manager
        self.enforceLivePathSafety = enforceLivePathSafety
        self.codeIdentityProvider = codeIdentityProvider
    }

    var shouldPresentOnboarding: Bool {
        !defaults.bool(forKey: PreferenceKey.onboardingCompleted)
    }

    func markOnboardingCompleted() {
        defaults.set(true, forKey: PreferenceKey.onboardingCompleted)
    }

    func resetOnboarding() {
        defaults.removeObject(forKey: PreferenceKey.onboardingCompleted)
    }

    func snapshot() -> CodexSetupSnapshot {
        let codexURL = availableCodexExecutable()
        let sourceHelper = manager.isExecutableFile(atPath: paths.sourceHelperURL.path)
            ? paths.sourceHelperURL
            : nil
        let identifier = sourceHelper.flatMap { installationIdentifier(helperURL: $0) }
        let hooksDocument = loadHooksDocument()
        let hooksInvalid = manager.fileExists(atPath: paths.hooksURL.path)
            && hooksDocument == nil
        let hookInstalled = hooksDocument.map {
            Self.hasCompleteMonitorHooks(
                in: $0,
                command: Self.hookCommand(helperURL: paths.installedHelperURL)
            )
        } ?? false
        let hasExistingMonitorHook = hooksDocument.map(Self.hasAnyMonitorHook) ?? false
        let helperInstalled = manager.isExecutableFile(
            atPath: paths.installedHelperURL.path
        )
        let installedIdentifier = helperInstalled
            ? installationIdentifier(helperURL: paths.installedHelperURL)
            : nil
        let helperMatchesSource = installedIdentifier == identifier
        var reviewed = defaults.string(forKey: PreferenceKey.reviewedInstallation)
        var connected = defaults.string(forKey: PreferenceKey.connectedInstallation)
        if let identifier,
           let sourceHelper,
           hookInstalled,
           helperInstalled,
           helperMatchesSource {
            let legacyIdentifiers = Set([
                legacyInstallationIdentifier(helperURL: sourceHelper),
                legacyInstallationIdentifier(helperURL: paths.installedHelperURL),
            ].compactMap { $0 })
            if let storedReviewed = reviewed, legacyIdentifiers.contains(storedReviewed) {
                defaults.set(identifier, forKey: PreferenceKey.reviewedInstallation)
                reviewed = identifier
            }
            if let storedConnected = connected, legacyIdentifiers.contains(storedConnected) {
                defaults.set(identifier, forKey: PreferenceKey.connectedInstallation)
                connected = identifier
            }
        }
        let reviewedDefinitionChanged = reviewed.map { $0 != identifier } ?? false
        let hookDefinitionChanged = reviewedDefinitionChanged
            || !hookInstalled
            || !helperInstalled

        let state: CodexSetupHookState
        if codexURL == nil {
            state = .codexUnavailable
        } else if sourceHelper == nil || identifier == nil {
            state = .helperUnavailable
        } else if hooksInvalid {
            state = .invalidHooksFile
        } else if hasExistingMonitorHook
            && (!hookInstalled || !helperInstalled || !helperMatchesSource) {
            state = .updateRequired
        } else if !hookInstalled || !helperInstalled || !helperMatchesSource {
            state = .notInstalled
        } else if reviewed == nil {
            state = .trustStatusUnknown
        } else if reviewed != identifier {
            state = .securityReviewRequired
        } else if connected != identifier {
            state = .waitingForFirstEvent
        } else {
            state = .connected
        }

        return CodexSetupSnapshot(
            hookState: state,
            codexExecutableURL: codexURL,
            sourceHelperURL: sourceHelper,
            installedHelperURL: paths.installedHelperURL,
            hooksURL: paths.hooksURL,
            installationIdentifier: identifier,
            hookDefinitionChanged: hookDefinitionChanged,
            lastConnectedAt: defaults.object(forKey: PreferenceKey.lastConnectedAt) as? Date
        )
    }

    func installHooks() throws -> CodexSetupInstallResult {
        guard availableCodexExecutable() != nil else {
            throw CodexSetupError.codexUnavailable
        }
        guard manager.isExecutableFile(atPath: paths.sourceHelperURL.path),
              let identifier = installationIdentifier(helperURL: paths.sourceHelperURL)
        else { throw CodexSetupError.helperUnavailable }
        try validateLiveTargets()

        let document: [String: Any]
        if manager.fileExists(atPath: paths.hooksURL.path) {
            guard let loaded = loadHooksDocument() else {
                throw CodexSetupError.invalidHooksFile
            }
            document = loaded
        } else {
            document = [
                "description": "User-level Codex lifecycle hooks",
                "hooks": [String: Any](),
            ]
        }

        try manager.createDirectory(
            at: paths.codexHome,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.createDirectory(
            at: paths.helperDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.createDirectory(
            at: paths.backupDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let hooksBackup = try backupIfPresent(
            paths.hooksURL,
            prefix: "hooks-before-setup"
        )
        let helperBackup = try backupIfPresent(
            paths.installedHelperURL,
            prefix: "CodexMonitorHook-before-setup"
        )

        let temporaryHelper = paths.helperDirectory
            .appendingPathComponent(".CodexMonitorHook-\(UUID().uuidString)")
        try manager.copyItem(at: paths.sourceHelperURL, to: temporaryHelper)
        try manager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: temporaryHelper.path
        )
        if manager.fileExists(atPath: paths.installedHelperURL.path) {
            _ = try manager.replaceItemAt(
                paths.installedHelperURL,
                withItemAt: temporaryHelper
            )
        } else {
            try manager.moveItem(at: temporaryHelper, to: paths.installedHelperURL)
        }

        let merged = Self.mergeMonitorHooks(
            in: document,
            command: Self.hookCommand(helperURL: paths.installedHelperURL)
        )
        let data = try JSONSerialization.data(
            withJSONObject: merged,
            options: [.prettyPrinted, .sortedKeys]
        ) + Data("\n".utf8)
        let temporaryHooks = paths.codexHome
            .appendingPathComponent(".hooks-\(UUID().uuidString).json")
        try data.write(to: temporaryHooks, options: .atomic)
        try manager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporaryHooks.path
        )
        if manager.fileExists(atPath: paths.hooksURL.path) {
            _ = try manager.replaceItemAt(paths.hooksURL, withItemAt: temporaryHooks)
        } else {
            try manager.moveItem(at: temporaryHooks, to: paths.hooksURL)
        }

        defaults.removeObject(forKey: PreferenceKey.connectedInstallation)
        defaults.removeObject(forKey: PreferenceKey.lastConnectedAt)
        try? manager.removeItem(at: paths.reviewResultURL)

        return CodexSetupInstallResult(
            hooksBackupURL: hooksBackup,
            helperBackupURL: helperBackup,
            hooksURL: paths.hooksURL,
            helperURL: paths.installedHelperURL,
            installationIdentifier: identifier
        )
    }

    func uninstallHooks() throws -> URL? {
        guard !manager.fileExists(atPath: paths.hooksURL.path)
                || loadHooksDocument() != nil
        else { throw CodexSetupError.invalidHooksFile }
        try validateLiveTargets()
        guard let document = loadHooksDocument() else { return nil }
        try manager.createDirectory(
            at: paths.backupDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let backup = try backupIfPresent(
            paths.hooksURL,
            prefix: "hooks-before-uninstall"
        )
        let cleaned = Self.removeMonitorHooks(from: document)
        let data = try JSONSerialization.data(
            withJSONObject: cleaned,
            options: [.prettyPrinted, .sortedKeys]
        ) + Data("\n".utf8)
        try data.write(to: paths.hooksURL, options: .atomic)
        try manager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.hooksURL.path
        )
        defaults.removeObject(forKey: PreferenceKey.connectedInstallation)
        defaults.removeObject(forKey: PreferenceKey.lastConnectedAt)
        return backup
    }

    func prepareSecurityReviewLauncher() throws -> URL {
        guard let codexURL = availableCodexExecutable(),
              installationIdentifier(helperURL: paths.sourceHelperURL) != nil
        else { throw CodexSetupError.codexUnavailable }
        do {
            try manager.createDirectory(
                at: paths.launcherDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let commandURL = paths.launcherDirectory
                .appendingPathComponent("Open Codex Hooks Review.command")
            let expectScript = """
            #!/usr/bin/expect -f
            set timeout 20
            set codex $env(CODEX_MONITOR_CODEX)
            spawn -noecho $codex --enable hooks
            expect {
                -re {Hooks need review} {
                    interact
                }
                -re {Ask Codex to do anything} {
                    send -- "/hooks\\r"
                    after 100
                    interact
                }
                timeout {
                    send_user "\\nCodex Monitor: 如果没有自动进入 Hooks 页面，请输入 /hooks 并按 Enter。\\n"
                    interact
                }
                eof {
                    catch wait result
                    exit 0
                }
            }
            """
            try Data(expectScript.utf8).write(to: paths.reviewExpectURL, options: .atomic)
            try manager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: paths.reviewExpectURL.path
            )
            let command = """
            #!/bin/zsh
            # Codex owns the security-review UI and the user must confirm trust.
            # If Codex already trusts the hooks, open the canonical /hooks browser.
            export CODEX_MONITOR_CODEX=\(Self.shellQuote(codexURL.path))
            if [[ ! -x /usr/bin/expect ]]; then
                exec "$CODEX_MONITOR_CODEX" --enable hooks
            fi
            exec /usr/bin/expect \(Self.shellQuote(paths.reviewExpectURL.path))
            """
            try Data(command.utf8).write(to: commandURL, options: .atomic)
            try manager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: commandURL.path
            )
            return commandURL
        } catch {
            throw CodexSetupError.couldNotPrepareLauncher
        }
    }

    func consumeSecurityReviewResult() -> Bool {
        guard let identifier = installationIdentifier(helperURL: paths.sourceHelperURL),
              let value = try? String(contentsOf: paths.reviewResultURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
              value == "confirmed:\(identifier)"
        else { return false }
        defaults.set(identifier, forKey: PreferenceKey.reviewedInstallation)
        try? manager.removeItem(at: paths.reviewResultURL)
        return true
    }

    func markSecurityReviewConfirmed() -> Bool {
        let current = snapshot()
        guard current.hookState.needsTrustConfirmation,
              let identifier = current.installationIdentifier
        else { return false }
        defaults.set(identifier, forKey: PreferenceKey.reviewedInstallation)
        return true
    }

    func consumeSecurityReviewFailure() -> String? {
        guard let value = try? String(
            contentsOf: paths.reviewResultURL,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines),
        value.hasPrefix("failed:")
        else { return nil }
        try? manager.removeItem(at: paths.reviewResultURL)
        switch value {
        case "failed:prompt-timeout":
            return "等待 Codex 命令提示超时，请重新打开安全审核。"
        case "failed:review-timeout":
            return "未能进入 Codex Hooks 审核页面，请重新尝试。"
        case "failed:trust-not-confirmed":
            return "Codex 未确认 Hook 信任；请重新打开审核菜单后选择信任。"
        default:
            return "Codex Hooks 安全审核未完成，请重新尝试。"
        }
    }

    func recordConnectedEvent(at date: Date = Date()) {
        guard let identifier = installationIdentifier(helperURL: paths.sourceHelperURL),
              defaults.string(forKey: PreferenceKey.reviewedInstallation) == identifier
        else { return }
        defaults.set(identifier, forKey: PreferenceKey.connectedInstallation)
        defaults.set(date, forKey: PreferenceKey.lastConnectedAt)
    }

    private func availableCodexExecutable() -> URL? {
        paths.codexExecutableCandidates.first {
            manager.isExecutableFile(atPath: $0.path)
        }
    }

    private func installationIdentifier(helperURL: URL) -> String? {
        let codeIdentity = codeIdentityProvider?(helperURL)
            ?? Self.codeDirectoryIdentity(helperURL: helperURL)
            ?? (try? Data(contentsOf: helperURL))
        guard let codeIdentity else { return nil }
        return Self.makeInstallationIdentifier(codeIdentity: codeIdentity)
    }

    private func legacyInstallationIdentifier(helperURL: URL) -> String? {
        guard let data = try? Data(contentsOf: helperURL) else { return nil }
        return Self.makeInstallationIdentifier(codeIdentity: data)
    }

    static func makeInstallationIdentifier(codeIdentity: Data) -> String {
        var digestInput = codeIdentity
        digestInput.append(Data(Self.hookEvents.joined(separator: "|").utf8))
        digestInput.append(Data("|timeout=2|schema=1".utf8))
        return SHA256.hash(data: digestInput)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func codeDirectoryIdentity(helperURL: URL) -> Data? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            helperURL as CFURL,
            [],
            &staticCode
        ) == errSecSuccess,
        let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let values = information as? [String: Any],
        let identity = values[kSecCodeInfoUnique as String] as? Data,
        !identity.isEmpty else { return nil }
        return identity
    }

    private func loadHooksDocument() -> [String: Any]? {
        guard manager.fileExists(atPath: paths.hooksURL.path) else { return nil }
        guard let data = try? Data(contentsOf: paths.hooksURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return nil }
        return dictionary
    }

    private func backupIfPresent(_ url: URL, prefix: String) throws -> URL? {
        guard manager.fileExists(atPath: url.path) else { return nil }
        let backup = paths.backupDirectory.appendingPathComponent(
            "\(prefix)-\(Self.timestamp())-\(UUID().uuidString.prefix(8))"
                + (url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)")
        )
        try manager.copyItem(at: url, to: backup)
        return backup
    }

    private func validateLiveTargets() throws {
        guard enforceLivePathSafety else { return }
        let home = manager.homeDirectoryForCurrentUser.standardizedFileURL
        let codexHome = paths.codexHome.standardizedFileURL
        let support = paths.supportDirectory.standardizedFileURL
        guard codexHome.path != home.path,
              support.path != home.path,
              codexHome.path.hasPrefix(home.path + "/"),
              support.path.hasPrefix(home.path + "/")
        else { throw CodexSetupError.unsafePath }
    }

    static func mergeMonitorHooks(
        in document: [String: Any],
        command: String
    ) -> [String: Any] {
        var result = document
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for event in hookEvents {
            let groups = hooks[event] as? [[String: Any]] ?? []
            var filtered = groups.filter { group in
                let handlers = group["hooks"] as? [[String: Any]] ?? []
                return !handlers.contains { handler in
                    String(describing: handler["command"] ?? "")
                        .contains("CodexMonitorHook")
                }
            }
            filtered.append([
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": 2,
                ]],
            ])
            hooks[event] = filtered
        }
        result["hooks"] = hooks
        return result
    }

    static func removeMonitorHooks(from document: [String: Any]) -> [String: Any] {
        var result = document
        guard var hooks = result["hooks"] as? [String: Any] else { return result }
        for event in Array(hooks.keys) {
            guard let value = hooks[event] else { continue }
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { group in
                let handlers = group["hooks"] as? [[String: Any]] ?? []
                return !handlers.contains { handler in
                    String(describing: handler["command"] ?? "")
                        .contains("CodexMonitorHook")
                }
            }
            if kept.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = kept
            }
        }
        result["hooks"] = hooks
        return result
    }

    static func hasCompleteMonitorHooks(
        in document: [String: Any],
        command: String
    ) -> Bool {
        guard let hooks = document["hooks"] as? [String: Any] else { return false }
        return hookEvents.allSatisfy { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return groups.contains { group in
                let handlers = group["hooks"] as? [[String: Any]] ?? []
                return handlers.contains { handler in
                    handler["type"] as? String == "command"
                        && handler["command"] as? String == command
                        && (handler["timeout"] as? Int) == 2
                }
            }
        }
    }

    static func hasAnyMonitorHook(in document: [String: Any]) -> Bool {
        guard let hooks = document["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            guard let groups = value as? [[String: Any]] else { return false }
            return groups.contains { group in
                let handlers = group["hooks"] as? [[String: Any]] ?? []
                return handlers.contains { handler in
                    String(describing: handler["command"] ?? "")
                        .contains("CodexMonitorHook")
                }
            }
        }
    }

    static func hookCommand(helperURL: URL) -> String {
        shellQuote(helperURL.path)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }
}
