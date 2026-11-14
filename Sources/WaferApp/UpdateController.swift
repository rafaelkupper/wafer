import AppKit
import Sparkle

/// In-app updates through Sparkle. The feed URL and public key live in
/// `App/Info.plist`; a process without them (tests, `swift run`) gets no
/// updater and disabled menu items.
@MainActor
final class UpdateController: NSObject, NSMenuItemValidation, SPUUpdaterDelegate {
    static let shared = UpdateController()

    private var controller: SPUStandardUpdaterController?
    private var quitsWhenSessionEnds = false
    private let sessionInProgress: (@MainActor () -> Bool)?
    private let hasVisibleWindows: @MainActor () -> Bool
    private let terminate: @MainActor () -> Void

    init(
        bundle: Bundle = .main,
        sessionInProgress: (@MainActor () -> Bool)? = nil,
        hasVisibleWindows: @escaping @MainActor () -> Bool = { NSApp.windows.contains(where: \.isVisible) },
        terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
    ) {
        self.sessionInProgress = sessionInProgress
        self.hasVisibleWindows = hasVisibleWindows
        self.terminate = terminate
        super.init()
        guard bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyDownloadsUpdates = false
        controller.updater.sendsSystemProfile = false
        controller.startUpdater()
        self.controller = controller
    }

    var canCheckForUpdates: Bool {
        controller?.updater.canCheckForUpdates ?? false
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    @objc func toggleAutomaticallyChecksForUpdates(_ sender: NSMenuItem) {
        automaticallyChecksForUpdates.toggle()
        sender.state = automaticallyChecksForUpdates ? .on : .off
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(checkForUpdates(_:)):
            return canCheckForUpdates
        case #selector(toggleAutomaticallyChecksForUpdates(_:)):
            menuItem.state = automaticallyChecksForUpdates ? .on : .off
            return controller != nil
        default:
            return true
        }
    }

    /// Wafer quits when its last window closes, and Sparkle's windows count:
    /// it closes the update prompt before it opens the download progress.
    /// Quitting there would drop the update, so the quit waits for the session.
    func postponesQuitAfterLastWindowClosed() -> Bool {
        guard (sessionInProgress?() ?? controller?.updater.sessionInProgress) == true else {
            return false
        }

        quitsWhenSessionEnds = true
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        updateCycleDidFinish()
    }

    func updateCycleDidFinish() {
        guard quitsWhenSessionEnds else {
            return
        }

        quitsWhenSessionEnds = false
        if !hasVisibleWindows() {
            terminate()
        }
    }
}
