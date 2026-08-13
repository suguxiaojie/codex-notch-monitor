import Foundation

/// Codex Desktop keeps both user-renamed project labels and the current
/// thread-to-project ownership in this non-sensitive local state file. The
/// original JSONL cwd is immutable history, so a moved thread must be resolved
/// through `thread-project-assignments` on every refresh.
enum CodexProjectCatalog {
    struct Assignment: Equatable {
        let projectID: String
        let projectName: String
        let path: String
    }

    struct State: Equatable {
        let namesByPath: [String: String]
        let assignmentsByThread: [String: Assignment]

        static let empty = State(namesByPath: [:], assignmentsByThread: [:])
    }

    private static var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/.codex-global-state.json")
    }

    static func loadNamesByPath() -> [String: String] {
        loadState().namesByPath
    }

    static func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL) else { return .empty }
        return state(from: data)
    }

    static func namesByPath(from data: Data) -> [String: String] {
        state(from: data).namesByPath
    }

    static func state(from data: Data) -> State {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["local-projects"] as? [String: Any]
        else { return .empty }

        var namesByPath: [String: String] = [:]
        var projectDetails: [String: (name: String, roots: [String])] = [:]
        for (projectKey, value) in projects {
            guard let project = value as? [String: Any],
                  let rawName = project["name"] as? String,
                  let roots = project["rootPaths"] as? [String]
            else { continue }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let projectID = (project["id"] as? String) ?? projectKey
            let normalizedRoots = roots.filter { !$0.isEmpty }.map(normalize)
            projectDetails[projectID] = (name, normalizedRoots)
            for rootPath in normalizedRoots {
                namesByPath[rootPath] = name
            }
        }

        var assignments: [String: Assignment] = [:]
        let rawAssignments = root["thread-project-assignments"] as? [String: Any] ?? [:]
        for (threadID, value) in rawAssignments {
            guard let assignment = value as? [String: Any],
                  assignment["projectKind"] as? String == "local",
                  let projectID = assignment["projectId"] as? String,
                  let project = projectDetails[projectID]
            else { continue }
            let explicitPath = (assignment["cwd"] as? String)
                ?? (assignment["path"] as? String)
                ?? project.roots.first
            guard let explicitPath, !explicitPath.isEmpty else { continue }
            assignments[threadID] = Assignment(
                projectID: projectID,
                projectName: project.name,
                path: normalize(explicitPath)
            )
        }
        return State(namesByPath: namesByPath, assignmentsByThread: assignments)
    }

    static func displayName(for path: String, namesByPath: [String: String]) -> String? {
        guard !path.isEmpty else { return nil }
        let normalized = normalize(path)
        if let exact = namesByPath[normalized] { return exact }
        return namesByPath
            .filter { normalized.hasPrefix($0.key + "/") }
            .max { $0.key.count < $1.key.count }?
            .value
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
