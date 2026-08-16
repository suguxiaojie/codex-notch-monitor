import Foundation

final class CodexAppServerClient {
    struct ProtocolError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    final class Session {
        typealias JSON = [String: Any]

        var notificationHandler: ((String, JSON) -> Void)?

        private let queue = DispatchQueue(label: "com.coverai.codex-notch-monitor.app-server.\(UUID().uuidString)")
        private var process: Process?
        private var outputHandle: FileHandle?
        private var inputHandle: FileHandle?
        private var buffer = Data()
        private var nextRequestID = 2
        private var pending: [Int: (Result<JSON, Error>) -> Void] = [:]
        private var timeoutItems: [Int: DispatchWorkItem] = [:]
        private var readyCompletion: ((Result<Void, Error>) -> Void)?
        private var stopped = false

        func start(completion: @escaping (Result<Void, Error>) -> Void) {
            queue.async {
                guard !self.stopped, self.process == nil else {
                    completion(.failure(ProtocolError(message: "Codex App Server 会话不可用")))
                    return
                }
                guard let executable = CodexAppServerClient.resolveCodexExecutable() else {
                    completion(.failure(ProtocolError(message: "未找到 Codex CLI")))
                    return
                }

                let process = Process()
                let stdout = Pipe()
                let stdin = Pipe()
                let stderr = Pipe()
                process.executableURL = executable
                process.arguments = ["app-server", "--stdio"]
                process.standardOutput = stdout
                process.standardInput = stdin
                process.standardError = stderr

                self.process = process
                self.outputHandle = stdout.fileHandleForReading
                self.inputHandle = stdin.fileHandleForWriting
                self.readyCompletion = completion
                stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    self?.queue.async { self?.consume(data) }
                }

                do {
                    try process.run()
                    self.pending[1] = { [weak self] result in
                        guard let self else { return }
                        switch result {
                        case .success:
                            self.sendNotification(method: "initialized", params: [:])
                            let callback = self.readyCompletion
                            self.readyCompletion = nil
                            DispatchQueue.main.async { callback?(.success(())) }
                        case let .failure(error):
                            self.finishReady(.failure(error))
                            self.stop()
                        }
                    }
                    self.scheduleTimeout(id: 1, seconds: 12)
                    self.send([
                        "method": "initialize",
                        "id": 1,
                        "params": [
                            "clientInfo": [
                                "name": "codex-notch-monitor",
                                "title": "Codex Notch Monitor",
                                "version": "1.3.1",
                            ],
                            "capabilities": ["experimentalApi": false],
                        ],
                    ])
                } catch {
                    self.finishReady(.failure(error))
                    self.stop()
                }
            }
        }

        func request(
            method: String,
            params: JSON = [:],
            timeout: TimeInterval = 15,
            completion: @escaping (Result<JSON, Error>) -> Void
        ) {
            queue.async {
                guard !self.stopped, self.process?.isRunning == true else {
                    DispatchQueue.main.async {
                        completion(.failure(ProtocolError(message: "Codex App Server 已停止")))
                    }
                    return
                }
                let id = self.nextRequestID
                self.nextRequestID += 1
                self.pending[id] = { result in
                    DispatchQueue.main.async { completion(result) }
                }
                self.scheduleTimeout(id: id, seconds: timeout)
                self.send(["method": method, "id": id, "params": params])
            }
        }

        func stop() {
            queue.async {
                guard !self.stopped else { return }
                self.stopped = true
                self.outputHandle?.readabilityHandler = nil
                try? self.inputHandle?.close()
                try? self.outputHandle?.close()
                if let process = self.process, process.isRunning { process.terminate() }
                self.process = nil
                self.inputHandle = nil
                self.outputHandle = nil
                for item in self.timeoutItems.values { item.cancel() }
                self.timeoutItems.removeAll()
                let callbacks = self.pending.values
                self.pending.removeAll()
                let error = ProtocolError(message: "Codex App Server 会话已结束")
                callbacks.forEach { $0(.failure(error)) }
                self.finishReady(.failure(error))
            }
        }

        private func consume(_ data: Data) {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard !line.isEmpty,
                      let object = try? JSONSerialization.jsonObject(with: line) as? JSON
                else { continue }

                if let id = object["id"] as? Int, let callback = pending.removeValue(forKey: id) {
                    timeoutItems.removeValue(forKey: id)?.cancel()
                    if let error = object["error"] as? JSON {
                        callback(.failure(ProtocolError(
                            message: error["message"] as? String ?? "Codex App Server 请求失败"
                        )))
                    } else if let result = object["result"] as? JSON {
                        callback(.success(result))
                    } else {
                        callback(.failure(ProtocolError(message: "Codex App Server 响应格式无效")))
                    }
                    continue
                }

                guard let method = object["method"] as? String else { continue }
                let params = object["params"] as? JSON ?? [:]
                notificationHandler?(method, params)
            }
        }

        private func sendNotification(method: String, params: JSON) {
            send(["method": method, "params": params])
        }

        private func send(_ object: JSON) {
            guard let inputHandle,
                  var data = try? JSONSerialization.data(withJSONObject: object)
            else { return }
            data.append(0x0A)
            do {
                try inputHandle.write(contentsOf: data)
            } catch {
                stop()
            }
        }

        private func scheduleTimeout(id: Int, seconds: TimeInterval) {
            let item = DispatchWorkItem { [weak self] in
                guard let self, let callback = self.pending.removeValue(forKey: id) else { return }
                self.timeoutItems.removeValue(forKey: id)
                callback(.failure(ProtocolError(message: "Codex App Server 请求超时")))
                if id == 1 { self.stop() }
            }
            timeoutItems[id] = item
            queue.asyncAfter(deadline: .now() + seconds, execute: item)
        }

        private func finishReady(_ result: Result<Void, Error>) {
            let callback = readyCompletion
            readyCompletion = nil
            guard let callback else { return }
            DispatchQueue.main.async { callback(result) }
        }
    }

    static func request(
        method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval = 15,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        let session = Session()
        session.start { result in
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case .success:
                session.request(method: method, params: params, timeout: timeout) { response in
                    completion(response)
                    session.stop()
                }
            }
        }
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
}
