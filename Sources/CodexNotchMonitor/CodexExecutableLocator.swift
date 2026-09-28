import Foundation

enum CodexExecutableLocator {
    static let bundledCandidatePaths = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/opt/homebrew/bin/codex",
        "/usr/local/bin/codex",
    ]

    static func candidateURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var seen = Set<String>()
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/codex" }
        return (bundledCandidatePaths + pathCandidates).compactMap { path in
            guard seen.insert(path).inserted else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    static func resolve(
        candidates: [URL] = candidateURLs(),
        fileManager: FileManager = .default
    ) -> URL? {
        candidates.first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }
}
