import Foundation

@main
enum CodexSetupServiceTests {
    static func main() throws {
        verifiesHooksStepActions()
        try installsHooksWithoutOverwritingThirdPartyHandlers()
        try refusesInvalidHooksFile()
        try tracksReviewAndFirstRealEvent()
        try uninstallsOnlyMonitorHooks()
        print("Codex setup tests: 5/5 passed")
    }

    static func verifiesHooksStepActions() {
        expect(CodexSetupHookState.notInstalled.onboardingStepMode == .install, "not installed should offer install")
        expect(CodexSetupHookState.updateRequired.onboardingStepMode == .install, "outdated definitions should offer update")
        expect(CodexSetupHookState.securityReviewRequired.onboardingStepMode == .review, "review state must not offer reinstall")
        expect(CodexSetupHookState.waitingForFirstEvent.onboardingStepMode == .advance, "reviewed state should advance")
        expect(CodexSetupHookState.connected.onboardingStepMode == .advance, "connected state should advance")
        expect(CodexSetupHookState.invalidHooksFile.onboardingStepMode == .deferOnly, "invalid config must fail closed")
    }

    private struct Fixture {
        let root: URL
        let paths: CodexSetupPaths
        let defaults: UserDefaults
        let service: CodexSetupService
    }

    private static func makeFixture(_ name: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-setup-\(name)-\(UUID().uuidString)", isDirectory: true)
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let support = root.appendingPathComponent("Application Support/CodexNotchMonitor", isDirectory: true)
        let sourceHelper = root.appendingPathComponent("bundle/CodexMonitorHook")
        let codex = root.appendingPathComponent("ChatGPT/codex")
        try FileManager.default.createDirectory(
            at: sourceHelper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: codex.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/zsh\nexit 0\n".utf8).write(to: sourceHelper)
        try Data("#!/bin/zsh\nexit 0\n".utf8).write(to: codex)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: sourceHelper.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: codex.path
        )
        let paths = CodexSetupPaths(
            codexHome: codexHome,
            supportDirectory: support,
            sourceHelperURL: sourceHelper,
            codexExecutableCandidates: [codex]
        )
        let suite = "CodexSetupServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return Fixture(
            root: root,
            paths: paths,
            defaults: defaults,
            service: CodexSetupService(
                paths: paths,
                defaults: defaults,
                enforceLivePathSafety: false
            )
        )
    }

    static func installsHooksWithoutOverwritingThirdPartyHandlers() throws {
        let fixture = try makeFixture("install")
        try FileManager.default.createDirectory(
            at: fixture.paths.codexHome,
            withIntermediateDirectories: true
        )
        let thirdParty: [String: Any] = [
            "type": "command",
            "command": "/usr/bin/node /tmp/existing-hook.js",
            "timeout": 9,
        ]
        let staleMonitor: [String: Any] = [
            "type": "command",
            "command": "/Applications/CodexNotchMonitor.app/Contents/Helpers/CodexMonitorHook",
            "timeout": 2,
        ]
        let original: [String: Any] = [
            "description": "existing",
            "hooks": [
                "PreToolUse": [
                    ["hooks": [thirdParty]],
                    ["hooks": [staleMonitor]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: original, options: [.prettyPrinted])
            .write(to: fixture.paths.hooksURL)

        let before = fixture.service.snapshot()
        expect(before.hookState == .updateRequired, "stale monitor hooks should require an update")
        let result = try fixture.service.installHooks()
        expect(result.hooksBackupURL != nil, "existing hooks must be backed up")
        expect(
            FileManager.default.isExecutableFile(atPath: result.helperURL.path),
            "helper must be copied to the stable support path"
        )
        let data = try Data(contentsOf: fixture.paths.hooksURL)
        let installed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        expect(
            CodexSetupService.hasCompleteMonitorHooks(
                in: installed,
                command: CodexSetupService.hookCommand(
                    helperURL: fixture.paths.installedHelperURL
                )
            ),
            "all monitor hooks must point to the stable helper"
        )
        let hooks = installed["hooks"] as! [String: Any]
        let preTool = hooks["PreToolUse"] as! [[String: Any]]
        let handlers = preTool.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
        expect(
            handlers.contains { $0["command"] as? String == thirdParty["command"] as? String },
            "third-party hooks must be preserved"
        )
        expect(
            !handlers.contains { ($0["command"] as? String ?? "").hasPrefix("/Applications/CodexNotchMonitor") },
            "stale app-bundle hook must be replaced"
        )
        let monitorCommand = CodexSetupService.hookCommand(
            helperURL: fixture.paths.installedHelperURL
        )
        expect(monitorCommand.hasPrefix("'"), "helper path with spaces must be shell-quoted")
        let execution = Process()
        execution.executableURL = URL(fileURLWithPath: "/bin/zsh")
        execution.arguments = ["-c", monitorCommand]
        try execution.run()
        execution.waitUntilExit()
        expect(execution.terminationStatus == 0, "quoted helper command must execute successfully")
        expect(fixture.service.snapshot().hookState == .securityReviewRequired, "fresh install requires review")

        try Data("monitor-helper-v2".utf8).write(to: fixture.paths.sourceHelperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.paths.sourceHelperURL.path
        )
        let reinstalled = try fixture.service.installHooks()
        expect(reinstalled.helperBackupURL != nil, "helper updates must keep a rollback backup")
        expect(reinstalled.hooksBackupURL != nil, "hook updates must keep a config backup")
    }

    static func refusesInvalidHooksFile() throws {
        let fixture = try makeFixture("invalid")
        try FileManager.default.createDirectory(
            at: fixture.paths.codexHome,
            withIntermediateDirectories: true
        )
        let invalid = Data("{ invalid".utf8)
        try invalid.write(to: fixture.paths.hooksURL)
        do {
            _ = try fixture.service.installHooks()
            expect(false, "invalid hooks file must stop installation")
        } catch let error as CodexSetupError {
            expect(error == .invalidHooksFile, "invalid file should return the precise error")
        }
        let unchanged = try Data(contentsOf: fixture.paths.hooksURL)
        expect(unchanged == invalid, "invalid file must stay untouched")
        expect(
            !FileManager.default.fileExists(atPath: fixture.paths.installedHelperURL.path),
            "helper must not install after validation failure"
        )
    }

    static func tracksReviewAndFirstRealEvent() throws {
        let fixture = try makeFixture("review")
        expect(fixture.service.shouldPresentOnboarding, "first launch should present onboarding")
        fixture.service.markOnboardingCompleted()
        expect(!fixture.service.shouldPresentOnboarding, "dismissed onboarding should stay dismissed")
        fixture.service.resetOnboarding()
        expect(fixture.service.shouldPresentOnboarding, "onboarding should be rerunnable")
        _ = try fixture.service.installHooks()
        let launcher = try fixture.service.prepareSecurityReviewLauncher()
        expect(FileManager.default.isExecutableFile(atPath: launcher.path), "review launcher should be executable")
        let launcherText = try String(contentsOf: launcher, encoding: .utf8)
        expect(!launcherText.contains("/usr/bin/expect"), "review launcher must not wrap the Codex TUI with Expect")
        expect(launcherText.contains(fixture.paths.codexExecutableCandidates[0].path), "review launcher should directly execute Codex")
        expect(fixture.service.snapshot().hookState == .securityReviewRequired, "review is required before trust")
        expect(fixture.service.markSecurityReviewConfirmed(), "user-confirmed review should store the current installation")
        expect(fixture.service.snapshot().hookState == .waitingForFirstEvent, "review waits for a real event")
        let connectedAt = Date(timeIntervalSince1970: 2_000_000_000)
        fixture.service.recordConnectedEvent(at: connectedAt)
        let connected = fixture.service.snapshot()
        expect(connected.hookState == .connected, "first real event completes setup")
        expect(connected.lastConnectedAt == connectedAt, "connection time should persist")
    }

    static func uninstallsOnlyMonitorHooks() throws {
        let fixture = try makeFixture("uninstall")
        _ = try fixture.service.installHooks()
        let data = try Data(contentsOf: fixture.paths.hooksURL)
        var document = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var hooks = document["hooks"] as! [String: Any]
        var groups = hooks["Stop"] as! [[String: Any]]
        groups.append(["hooks": [[
            "type": "command",
            "command": "/tmp/keep-me",
            "timeout": 5,
        ]]])
        hooks["Stop"] = groups
        document["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted])
            .write(to: fixture.paths.hooksURL)

        let backup = try fixture.service.uninstallHooks()
        expect(backup != nil, "uninstall must back up the hooks file")
        let cleanedData = try Data(contentsOf: fixture.paths.hooksURL)
        let cleaned = try JSONSerialization.jsonObject(with: cleanedData) as! [String: Any]
        let cleanedHooks = cleaned["hooks"] as! [String: Any]
        let stopGroups = cleanedHooks["Stop"] as! [[String: Any]]
        let handlers = stopGroups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
        expect(handlers.count == 1, "only the third-party stop hook should remain")
        expect(handlers.first?["command"] as? String == "/tmp/keep-me", "third-party hook must remain")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("Codex setup test failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
