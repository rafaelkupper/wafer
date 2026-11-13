import CoreServices
import Foundation
import WaferCore

@MainActor
protocol DirectoryMonitoring: AnyObject {
    var changedPaths: Set<String>? { get }
    func start()
    func stop()
}

extension DirectoryMonitoring {
    var changedPaths: Set<String>? { nil }
}

@MainActor
final class DirectoryChangeMonitor: DirectoryMonitoring {
    private let rootURL: URL
    private let latency: TimeInterval
    private let onChange: () -> Void

    private var stream: FSEventStreamRef?
    private(set) var changedPaths: Set<String>?
    nonisolated(unsafe) private var hasActiveStreamForDeinit = false

    init(
        rootURL: URL,
        latency: TimeInterval = 0.5,
        onChange: @escaping () -> Void
    ) {
        self.rootURL = rootURL
        self.latency = latency
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else {
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, _ in
            guard let info else {
                return
            }

            let monitor = Unmanaged<DirectoryChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
            let eventFlags = Array(UnsafeBufferPointer(start: flags, count: count))
            Task { @MainActor in
                monitor.handleChange(paths: paths, flags: eventFlags)
            }
        }

        guard let createdStream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else {
            return
        }

        stream = createdStream
        hasActiveStreamForDeinit = true
        FSEventStreamSetDispatchQueue(createdStream, DispatchQueue.main)
        FSEventStreamStart(createdStream)
    }

    func stop() {
        guard let stream else {
            return
        }

        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        hasActiveStreamForDeinit = false
    }

    deinit {
        // DirectoryChangeMonitor has an explicit-stop ownership contract. If a
        // caller breaks it, leak the stream rather than risking off-main teardown.
        if hasActiveStreamForDeinit {
            assertionFailure("DirectoryChangeMonitor must be stopped before deinit; leaking FSEventStream instead of tearing it down off-main.")
        }
    }

    private func handleChange(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard stream != nil else { return }
        changedPaths = Self.relevantChanges(paths: paths, flags: flags, rootURL: rootURL)
        guard changedPaths?.isEmpty != true else { return }
        onChange()
    }

    static func relevantChanges(paths: [String], flags: [FSEventStreamEventFlags], rootURL: URL) -> Set<String>? {
        let recoveryFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped)
        if flags.contains(where: { $0 & recoveryFlags != 0 }) { return nil }
        let rootPath = FileIdentity.identity(for: rootURL)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var changes = Set<String>()
        for (index, path) in paths.enumerated() {
            let url = FileIdentity.normalized(URL(fileURLWithPath: path))
            let identity = url.path
            if identity == rootPath { return nil }
            guard identity.hasPrefix(prefix) else { continue }
            let components = identity.dropFirst(prefix.count).split(separator: "/")
            guard !components.contains(where: { $0.hasPrefix(".") || LibraryScanner.skippedDirectoryNames.contains(String($0)) }) else { continue }
            let isDirectory = index < flags.count && flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
            if isDirectory { return nil }
            if AssetResolver.markdownExtensions.contains(url.pathExtension.lowercased()) {
                changes.insert(identity)
            }
        }
        return changes
    }
}
