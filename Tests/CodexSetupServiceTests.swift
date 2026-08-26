import Foundation

@main
enum CodexSetupServiceTests {
    static func main() throws {
        verifiesHooksStepActions()
        try installsHooksWithoutOverwritingThirdPartyHandlers()
        try refusesInvalidHooksFile()
        try tracksReviewAndFirstRealEvent()
        try preservesReviewAcrossIdenticalReinstall()
        try requiresReviewWhenDefinitionChanges()
        try opensHooksBrowserFromNormalPrompt()
        try preservesNativeStartupReviewInteraction()
        try matchesThinAndUniversalHelpersByCurrentArchitectureIdentity()
        try uninstallsOnlyMonitorHooks()
        print("Codex setup tests: 10/10 passed")
    }

    static func verifiesHooksStepActions() {
        expect(CodexSetupHookState.notInstalled.onboardingStepMode == .install, "not installed should offer install")
        expect(CodexSetupHookState.updateRequired.onboardingStepMode == .install, "outdated definitions should offer update")
        expect(CodexSetupHookState.trustStatusUnknown.onboardingStepMode == .review, "unknown trust should offer status confirmation")
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
        expect(fixture.service.snapshot().hookState == .trustStatusUnknown, "fresh install has unknown Codex trust state")

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
        let expectText = try String(contentsOf: fixture.paths.reviewExpectURL, encoding: .utf8)
        expect(launcherText.contains("/usr/bin/expect"), "review launcher should use a PTY-aware Expect bridge")
        expect(launcherText.contains(fixture.paths.reviewExpectURL.path), "launcher should execute the standalone Expect script")
        expect(expectText.contains("Hooks need review"), "review launcher should preserve the native startup review")
        expect(expectText.contains("Ask Codex to do anything"), "review launcher should detect the normal CLI prompt")
        expect(expectText.contains("/hooks\\r"), "normal CLI should automatically open /hooks")
        expect(expectText.contains("--enable hooks"), "launcher should use the canonical hooks feature")
        expect(expectText.contains("interact"), "review launcher must return keyboard control to the user")
        expect(launcherText.contains(fixture.paths.codexExecutableCandidates[0].path), "review launcher should execute the detected Codex CLI")
        expect(fixture.service.snapshot().hookState == .trustStatusUnknown, "review status is unknown before confirmation")
        expect(fixture.service.markSecurityReviewConfirmed(), "user-confirmed review should store the current installation")
        expect(fixture.service.snapshot().hookState == .waitingForFirstEvent, "review waits for a real event")
        let connectedAt = Date(timeIntervalSince1970: 2_000_000_000)
        fixture.service.recordConnectedEvent(at: connectedAt)
        let connected = fixture.service.snapshot()
        expect(connected.hookState == .connected, "first real event completes setup")
        expect(connected.lastConnectedAt == connectedAt, "connection time should persist")
    }

    static func preservesReviewAcrossIdenticalReinstall() throws {
        let fixture = try makeFixture("same-definition-reinstall")
        _ = try fixture.service.installHooks()
        expect(fixture.service.markSecurityReviewConfirmed(), "current Hook should be confirmable")
        expect(fixture.service.snapshot().hookState == .waitingForFirstEvent, "confirmation should wait for a real event")

        _ = try fixture.service.uninstallHooks()
        expect(fixture.service.snapshot().hookState == .notInstalled, "uninstall should remove monitor Hook handlers")
        _ = try fixture.service.installHooks()
        expect(
            fixture.service.snapshot().hookState == .waitingForFirstEvent,
            "identical reinstall should preserve the reviewed definition"
        )
    }

    static func requiresReviewWhenDefinitionChanges() throws {
        let fixture = try makeFixture("changed-definition-reinstall")
        _ = try fixture.service.installHooks()
        expect(fixture.service.markSecurityReviewConfirmed(), "initial Hook should be confirmable")
        try Data("monitor-helper-v2".utf8).write(to: fixture.paths.sourceHelperURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.paths.sourceHelperURL.path
        )
        _ = try fixture.service.installHooks()
        expect(
            fixture.service.snapshot().hookState == .securityReviewRequired,
            "changed Hook definition should require a new security review"
        )
    }

    static func matchesThinAndUniversalHelpersByCurrentArchitectureIdentity() throws {
        let fixture = try makeFixture("architecture-identity")
        try FileManager.default.createDirectory(
            at: fixture.paths.codexHome,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fixture.paths.helperDirectory,
            withIntermediateDirectories: true
        )
        try Data("thin-arm64-helper".utf8).write(to: fixture.paths.sourceHelperURL)
        try Data("universal-helper-with-extra-slice".utf8).write(
            to: fixture.paths.installedHelperURL
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.paths.sourceHelperURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.paths.installedHelperURL.path
        )
        let merged = CodexSetupService.mergeMonitorHooks(
            in: ["hooks": [String: Any]()],
            command: CodexSetupService.hookCommand(helperURL: fixture.paths.installedHelperURL)
        )
        try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted])
            .write(to: fixture.paths.hooksURL)

        let sharedCodeIdentity = Data("same-current-architecture-code".utf8)
        let legacyInstalledData = try Data(contentsOf: fixture.paths.installedHelperURL)
        let legacyIdentifier = CodexSetupService.makeInstallationIdentifier(
            codeIdentity: legacyInstalledData
        )
        fixture.defaults.set(legacyIdentifier, forKey: "setup.hooks.reviewedInstallation")
        fixture.defaults.set(legacyIdentifier, forKey: "setup.hooks.connectedInstallation")
        let service = CodexSetupService(
            paths: fixture.paths,
            defaults: fixture.defaults,
            enforceLivePathSafety: false,
            codeIdentityProvider: { _ in sharedCodeIdentity }
        )
        let snapshot = service.snapshot()
        expect(snapshot.hookState == .connected, "same architecture code must not require a Hook update")
        expect(
            fixture.defaults.string(forKey: "setup.hooks.reviewedInstallation")
                == snapshot.installationIdentifier,
            "legacy reviewed identifier should migrate"
        )
        expect(
            fixture.defaults.string(forKey: "setup.hooks.connectedInstallation")
                == snapshot.installationIdentifier,
            "legacy connected identifier should migrate"
        )
    }

    static func opensHooksBrowserFromNormalPrompt() throws {
        let fixture = try makeFixture("review-launcher")
        _ = try fixture.service.installHooks()
        let codexURL = fixture.paths.codexExecutableCandidates[0]
        let receiptURL = fixture.root.appendingPathComponent("normal-prompt-receipt")
        let fakeCodex = """
        #!/bin/zsh
        print -r -- "Ask Codex to do anything"
        IFS= read -r command
        print -r -- "$command" > "$CODEX_SETUP_TEST_RECEIPT"
        """
        try Data(fakeCodex.utf8).write(to: codexURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: codexURL.path
        )

        let launcher = try fixture.service.prepareSecurityReviewLauncher()
        let execution = Process()
        execution.executableURL = launcher
        execution.standardInput = FileHandle.nullDevice
        execution.standardOutput = FileHandle.nullDevice
        execution.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_SETUP_TEST_RECEIPT"] = receiptURL.path
        execution.environment = environment
        try execution.run()
        execution.waitUntilExit()
        let text = (try? String(contentsOf: receiptURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        expect(execution.terminationStatus == 0, "review launcher should exit with the Codex CLI")
        expect(text == "/hooks", "normal CLI prompt should receive the /hooks command")
    }

    static func preservesNativeStartupReviewInteraction() throws {
        let fixture = try makeFixture("native-review-launcher")
        _ = try fixture.service.installHooks()
        let codexURL = fixture.paths.codexExecutableCandidates[0]
        let receiptURL = fixture.root.appendingPathComponent("native-review-receipt")
        let fakeCodex = """
        #!/bin/zsh
        print -r -- "Hooks need review"
        IFS= read -r choice
        print -r -- "$choice" > "$CODEX_SETUP_TEST_RECEIPT"
        """
        try Data(fakeCodex.utf8).write(to: codexURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: codexURL.path
        )

        let launcher = try fixture.service.prepareSecurityReviewLauncher()
        let execution = Process()
        execution.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
        execution.arguments = [
            "-c",
            """
            set timeout 5
            spawn -noecho $env(CODEX_SETUP_TEST_LAUNCHER)
            expect -re {Hooks need review}
            send -- "2\\r"
            expect eof
            """,
        ]
        execution.standardOutput = FileHandle.nullDevice
        execution.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_SETUP_TEST_RECEIPT"] = receiptURL.path
        environment["CODEX_SETUP_TEST_LAUNCHER"] = launcher.path
        execution.environment = environment
        try execution.run()
        execution.waitUntilExit()
        let text = (try? String(contentsOf: receiptURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        expect(execution.terminationStatus == 0, "native review launcher should exit with the Codex CLI")
        expect(text == "2", "native startup review must keep keyboard input interactive")
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
