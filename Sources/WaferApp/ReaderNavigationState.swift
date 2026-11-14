import Foundation

/// Authorizes one app-owned load and completes it once both WebKit and the
/// scripted renderers are ready. No WebKit objects enter this state machine.
struct ReaderNavigationState {
    private(set) var id = UUID()
    private var pendingReaderLoadURL: URL?
    private(set) var awaitingContentReady = false
    private var didFinish = false
    private(set) var didComplete = false
    private var themeUpdateID: UUID?

    var isReady: Bool { didComplete && !awaitingContentReady && themeUpdateID == nil }

    mutating func reset(awaitsContentReady: Bool) {
        id = UUID()
        themeUpdateID = nil
        awaitingContentReady = awaitsContentReady
        didFinish = false
        didComplete = false
    }

    mutating func authorizeLoad(baseURL: URL?) -> URL {
        var components = URLComponents(url: baseURL ?? URL(string: "wafer-reader://document/")!, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "wafer-navigation", value: id.uuidString)]
        let url = components.url!
        pendingReaderLoadURL = url
        return url
    }

    mutating func allowsNavigation(to url: URL, currentURL: URL?, isMainFrame: Bool, isOther: Bool) -> Bool {
        guard isMainFrame, isOther else { return false }
        if url == pendingReaderLoadURL {
            pendingReaderLoadURL = nil
            return true
        }
        var target = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var current = currentURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let hasFragment = target?.fragment != nil
        target?.fragment = nil
        current?.fragment = nil
        return hasFragment && target?.url == current?.url
    }

    mutating func navigationFinished() -> Bool {
        didFinish = true
        return completeIfReady()
    }

    mutating func contentReady(id: String) -> Bool {
        guard id == self.id.uuidString, awaitingContentReady else { return false }
        awaitingContentReady = false
        return completeIfReady()
    }

    private mutating func completeIfReady() -> Bool {
        guard didFinish, !awaitingContentReady, !didComplete else { return false }
        didComplete = true
        return true
    }

    mutating func beginThemeUpdate() -> UUID {
        let updateID = UUID()
        themeUpdateID = updateID
        return updateID
    }

    mutating func finishThemeUpdate(id: UUID) -> Bool {
        guard themeUpdateID == id else { return false }
        themeUpdateID = nil
        return true
    }
}
