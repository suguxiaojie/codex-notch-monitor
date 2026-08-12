import Foundation

final class QuotaService {
    struct ProtocolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private var process: Process?
    private var outputHandle: FileHandle?
    private var inputHandle: FileHandle?
    private var buffer = Data()
    private var completion: ((Result<[RateLimitBucket], Error>) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.coverai.codex-notch-monitor.quota")

    func fetch(completion: @escaping (Result<[RateLimitBucket], Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopCurrentProcess()
            self.completion = completion

            guard let codexURL = Self.resolveCodexExecutable() else {
                self.finish(.failure(ProtocolError(message: "未找到 Codex CLI")))
                return
            }

            let process = Process()
            let stdout = Pipe()
            let stdin = Pipe()
            let stderr = Pipe()
            process.executableURL = codexURL
            process.arguments = ["app-server", "--stdio"]
            process.standardOutput = stdout
            process.standardInput = stdin
            process.standardError = stderr

            self.process = process
            self.outputHandle = stdout.fileHandleForReading
            self.inputHandle = stdin.fileHandleForWriting
            self.buffer.removeAll(keepingCapacity: true)

            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.queue.async { self?.consume(data) }
            }

            do {
                try process.run()
                self.scheduleTimeout()
                self.send([
                    "method": "initialize",
                    "id": 1,
                    "params": [
                        "clientInfo": [
                            "name": "codex-notch-monitor",
                            "title": "Codex Notch Monitor",
                            "version": "0.1.0",
                        ],
                        "capabilities": ["experimentalApi": false],
                    ],
                ])
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }

            if (object["id"] as? Int) == 1, object["result"] != nil {
                send(["method": "initialized", "params": [:]])
                send(["method": "account/rateLimits/read", "id": 2])
            } else if (object["id"] as? Int) == 2 {
                if let error = object["error"] as? [String: Any] {
                    finish(.failure(ProtocolError(message: error["message"] as? String ?? "额度读取失败")))
                    return
                }
                guard let result = object["result"] as? [String: Any] else {
                    finish(.failure(ProtocolError(message: "额度响应格式无效")))
                    return
                }
                finish(.success(Self.parseBuckets(from: result)))
                return
            }
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let inputHandle
        else { return }
        var line = data
        line.append(0x0A)
        do {
            try inputHandle.write(contentsOf: line)
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<[RateLimitBucket], Error>) {
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let callback = completion
        completion = nil
        stopCurrentProcess()
        guard let callback else { return }
        DispatchQueue.main.async { callback(result) }
    }

    private func stopCurrentProcess() {
        outputHandle?.readabilityHandler = nil
        try? inputHandle?.close()
        try? outputHandle?.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        inputHandle = nil
        outputHandle = nil
    }

    private func scheduleTimeout() {
        timeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.completion != nil else { return }
            self.finish(.failure(ProtocolError(message: "额度接口响应超时")))
        }
        timeoutWorkItem = item
        queue.asyncAfter(deadline: .now() + 12, execute: item)
    }

    static func resolveCodexExecutable() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
        for entry in pathEntries {
            let path = String(entry) + "/codex"
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static func parseBuckets(from result: [String: Any]) -> [RateLimitBucket] {
        let multi = result["rateLimitsByLimitId"] as? [String: Any]
        let fallback = result["rateLimits"] as? [String: Any]
        var entries: [(String, [String: Any])] = []

        if let multi {
            entries = multi.compactMap { key, value in
                guard let dictionary = value as? [String: Any] else { return nil }
                return (key, dictionary)
            }
        } else if let fallback {
            entries = [((fallback["limitId"] as? String) ?? "codex", fallback)]
        }

        return entries.map { key, value in
            let credits = value["credits"] as? [String: Any]
            return RateLimitBucket(
                id: key,
                name: (value["limitName"] as? String) ?? (key == "codex" ? "Codex" : key),
                planType: value["planType"] as? String,
                primary: parseWindow(value["primary"]),
                secondary: parseWindow(value["secondary"]),
                creditBalance: credits?["balance"] as? String,
                hasCredits: credits?["hasCredits"] as? Bool ?? false
            )
        }.sorted { lhs, rhs in
            if lhs.id == "codex" { return true }
            if rhs.id == "codex" { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func parseWindow(_ value: Any?) -> RateLimitWindow? {
        guard let dictionary = value as? [String: Any],
              let used = dictionary["usedPercent"] as? Int
        else { return nil }
        let resetTimestamp = dictionary["resetsAt"] as? TimeInterval
        return RateLimitWindow(
            usedPercent: used,
            windowDurationMinutes: dictionary["windowDurationMins"] as? Int,
            resetsAt: resetTimestamp.map(Date.init(timeIntervalSince1970:))
        )
    }
}
