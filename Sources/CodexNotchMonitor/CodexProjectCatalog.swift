import Foundation

/// Codex Desktop keeps both user-renamed project labels and the current
/// thread-to-project ownership in this non-sensitive local state file. The
/// original JSONL cwd is immutable history, so a moved thread must be resolved
/// through `thread-project-assignments` on every refresh.
enum CodexProjectCatalog {
    struct ProjectRemovalResult {
        let data: Data
        let removedProjectIDs: Set<String>
        let removedAssignmentCount: Int
    }

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
        loadState(from: stateURL)
    }

    static func loadState(from url: URL) -> State {
        guard let data = try? Data(contentsOf: url) else { return .empty }
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

    static func removingLocalProject(
        atPath path: String,
        from data: Data
    ) throws -> ProjectRemovalResult {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "CodexProjectCatalog",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Codex 全局项目状态不是有效 JSON 对象"]
            )
        }
        let normalizedPath = normalize(path)
        var projects = root["local-projects"] as? [String: Any] ?? [:]
        var removedIDs = Set<String>()
        for (key, value) in projects {
            guard let project = value as? [String: Any],
                  let roots = project["rootPaths"] as? [String],
                  roots.contains(where: { normalize($0) == normalizedPath })
            else { continue }
            removedIDs.insert(key)
            if let id = project["id"] as? String { removedIDs.insert(id) }
            projects.removeValue(forKey: key)
        }
        guard !removedIDs.isEmpty else {
            return ProjectRemovalResult(
                data: data,
                removedProjectIDs: [],
                removedAssignmentCount: 0
            )
        }
        root["local-projects"] = projects

        var removedAssignments = 0
        if var assignments = root["thread-project-assignments"] as? [String: Any] {
            assignments = assignments.filter { _, value in
                guard let assignment = value as? [String: Any],
                      let projectID = assignment["projectId"] as? String,
                      removedIDs.contains(projectID)
                else { return true }
                removedAssignments += 1
                return false
            }
            root["thread-project-assignments"] = assignments
        }

        for key in ["project-order", "pinned-project-ids"] {
            if let values = root[key] as? [Any] {
                root[key] = values.filter { value in
                    guard let id = value as? String else { return true }
                    return !removedIDs.contains(id)
                }
            }
        }
        if let selected = root["selected-project"] as? [String: Any],
           let projectID = selected["projectId"] as? String,
           removedIDs.contains(projectID) {
            root.removeValue(forKey: "selected-project")
        }
        if let orders = root["sidebar-project-thread-orders"] {
            root["sidebar-project-thread-orders"] = removingProjectReferences(
                from: orders,
                projectIDs: removedIDs
            )
        }
        if let atoms = root["electron-persisted-atom-state"] {
            root["electron-persisted-atom-state"] = removingProjectReferences(
                from: atoms,
                projectIDs: removedIDs
            )
        }

        return ProjectRemovalResult(
            data: try JSONSerialization.data(
                withJSONObject: root,
                options: [.withoutEscapingSlashes]
            ),
            removedProjectIDs: removedIDs,
            removedAssignmentCount: removedAssignments
        )
    }

    private static func removingProjectReferences(
        from value: Any,
        projectIDs: Set<String>
    ) -> Any {
        if let string = value as? String {
            return projectIDs.contains(string) ? NSNull() : string
        }
        if let array = value as? [Any] {
            var cleaned: [Any] = []
            for item in array {
                if let string = item as? String, projectIDs.contains(string) { continue }
                cleaned.append(removingProjectReferences(from: item, projectIDs: projectIDs))
            }
            return cleaned
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                let removesKey = projectIDs.contains(entry.key)
                    || projectIDs.contains(where: { entry.key.hasSuffix(":\($0)") })
                guard !removesKey else { return }
                if let string = entry.value as? String, projectIDs.contains(string) { return }
                result[entry.key] = removingProjectReferences(
                    from: entry.value,
                    projectIDs: projectIDs
                )
            }
        }
        return value
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
