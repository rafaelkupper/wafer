import Darwin
import Dispatch
import Foundation

@MainActor
protocol FileChangeMonitoring: AnyObject {
    func start()
    func stop()
}

@MainActor
final class FileChangeMonitor: FileChangeMonitoring {
    private let fileURL: URL
    private let maximumDeliveryDelay: TimeInterval
    private var firstPendingEventTime: TimeInterval?
    private let debounceInterval: TimeInterval
    private let rearmPollInterval: TimeInterval
    private let scheduler: LibraryRescanScheduler
    private let onChange: () -> Void

    private var isStarted = false
    // Main-actor access, except exclusive teardown in deinit.
    nonisolated(unsafe) private var source: DispatchSourceFileSystemObject?
    private var pendingDebounceWorkItem: DispatchWorkItem?
    private var rearmTimer: Timer?
    private var rearmDelay: TimeInterval = 0

    init(
        fileURL: URL,
        debounceInterval: TimeInterval = 0.25,
        maximumDeliveryDelay: TimeInterval = 1,
        rearmPollInterval: TimeInterval = 0.5,
        scheduler: LibraryRescanScheduler = .main,
        onChange: @escaping () -> Void
    ) {
        self.scheduler = scheduler
        self.fileURL = fileURL
        self.maximumDeliveryDelay = maximumDeliveryDelay
        self.debounceInterval = debounceInterval
        self.rearmPollInterval = rearmPollInterval
        self.onChange = onChange
    }

    func start() {
        guard !isStarted else { return }

        isStarted = true
        if !installSource() {
            startRearmLoop()
        }
    }

    func stop() {
        isStarted = false
        pendingDebounceWorkItem?.cancel()
        pendingDebounceWorkItem = nil
        firstPendingEventTime = nil
        stopRearmLoop()
        tearDownSource()
    }

    deinit { source?.cancel() }

    #if DEBUG
    var rearmDelayForTesting: TimeInterval { rearmDelay }
    func writeEventForTesting() { handleFileEvent(.write) }
    func pollForReappearanceForTesting() { tryRearm() }
    #endif

    private func installSource() -> Bool {
        guard isStarted, source == nil else { return source != nil }

        let fileDescriptor = open(fileURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return false
        }

        let fileSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename, .attrib, .link],
            queue: .main
        )
        fileSource.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                self.handleFileEvent(source.data)
            }
        }
        fileSource.setCancelHandler {
            _ = close(fileDescriptor)
        }

        source = fileSource
        fileSource.resume()
        return true
    }

    private func handleFileEvent(_ event: DispatchSource.FileSystemEvent) {
        guard isStarted else { return }

        if event.contains(.delete) || event.contains(.rename) {
            tearDownSource()
            startRearmLoop()
            return
        }

        scheduleDebouncedChange()
    }

    private func tearDownSource() {
        guard let existingSource = source else { return }

        source = nil
        existingSource.cancel()
    }

    private func startRearmLoop() {
        guard isStarted, rearmTimer == nil else { return }
        rearmDelay = rearmPollInterval
        tryRearm()
    }

    private func scheduleRearm() {
        let timer = Timer.scheduledTimer(withTimeInterval: rearmDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tryRearm() }
        }
        timer.tolerance = rearmDelay / 5
        rearmTimer = timer
    }

    private func stopRearmLoop() {
        rearmTimer?.invalidate()
        rearmTimer = nil
    }

    private func tryRearm() {
        guard isStarted, source == nil else { return }

        stopRearmLoop()
        if installSource() {
            rearmDelay = rearmPollInterval
            scheduleDebouncedChange()
        } else {
            scheduleRearm()
            rearmDelay = min(rearmDelay * 2, max(5, rearmPollInterval))
        }
    }

    private func scheduleDebouncedChange() {
        pendingDebounceWorkItem?.cancel()

        let now = scheduler.now()
        let firstEvent = firstPendingEventTime ?? now
        firstPendingEventTime = firstEvent
        let delay = min(debounceInterval, max(0, firstEvent + maximumDeliveryDelay - now))
        pendingDebounceWorkItem = scheduler.schedule(delay) { [weak self] in
            guard let self, self.isStarted else { return }
            self.pendingDebounceWorkItem = nil
            self.firstPendingEventTime = nil
            self.onChange()
        }
    }
}
