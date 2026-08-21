import Darwin
import Foundation

struct CodexAccountStateStamp: Equatable {
    let exists: Bool
    let modificationDate: Date?
    let fileSize: UInt64?
    let fileNumber: UInt64?

    static func read(at url: URL, fileManager: FileManager = .default) -> Self {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return Self(exists: false, modificationDate: nil, fileSize: nil, fileNumber: nil)
        }
        return Self(
            exists: true,
            modificationDate: attributes[.modificationDate] as? Date,
            fileSize: (attributes[.size] as? NSNumber)?.uint64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }
}

/// Watches only filesystem metadata for Codex's account-state file. The file
/// contents are never opened or read by the monitor.
final class CodexAccountStateWatcher {
    private let directoryURL: URL
    private let stateFileURL: URL
    private let debounceInterval: TimeInterval
    private let queue = DispatchQueue(
        label: "com.coverai.codex-notch-monitor.account-state-watcher",
        qos: .utility
    )
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pendingChange: DispatchWorkItem?
    private var lastStamp: CodexAccountStateStamp
    private var handler: ((Date) -> Void)?
    private var started = false

    init(
        codexHome: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true),
        debounceInterval: TimeInterval = 0.8
    ) {
        directoryURL = codexHome
        stateFileURL = codexHome.appendingPathComponent("auth.json")
        self.debounceInterval = debounceInterval
        lastStamp = CodexAccountStateStamp.read(at: stateFileURL)
    }

    func start(onChange: @escaping (Date) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.started else { return }
            self.started = true
            self.handler = onChange
            self.lastStamp = CodexAccountStateStamp.read(at: self.stateFileURL)
            self.armDirectorySource()
            self.armFileSource()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.pendingChange?.cancel()
            self.pendingChange = nil
            self.directorySource?.cancel()
            self.directorySource = nil
            self.fileSource?.cancel()
            self.fileSource = nil
            self.handler = nil
        }
    }

    private func armDirectorySource() {
        guard directorySource == nil else { return }
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.inspectStateFile(rearmFileSource: true)
        }
        source.setCancelHandler { close(descriptor) }
        directorySource = source
        source.resume()
    }

    private func armFileSource() {
        fileSource?.cancel()
        fileSource = nil
        let descriptor = open(stateFileURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib, .extend],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.inspectStateFile(rearmFileSource: true)
        }
        source.setCancelHandler { close(descriptor) }
        fileSource = source
        source.resume()
    }

    private func inspectStateFile(rearmFileSource: Bool) {
        guard started else { return }
        let previousStamp = lastStamp
        let stamp = CodexAccountStateStamp.read(at: stateFileURL)
        let changed = stamp != previousStamp
        lastStamp = stamp
        if rearmFileSource,
           stamp.exists != previousStamp.exists || stamp.fileNumber != previousStamp.fileNumber {
            armFileSource()
        }
        guard changed else { return }

        pendingChange?.cancel()
        let detectedAt = stamp.modificationDate ?? Date()
        let workItem = DispatchWorkItem { [weak self] in
            self?.handler?(detectedAt)
        }
        pendingChange = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }
}
