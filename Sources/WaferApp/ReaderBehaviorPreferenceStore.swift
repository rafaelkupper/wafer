import Foundation

extension Notification.Name {
    static let readerBehaviorPreferenceDidChange = Notification.Name("ReaderBehaviorPreferenceStore.readerBehaviorPreferenceDidChange")
}

final class ReaderBehaviorPreferenceStore: @unchecked Sendable {
    static let shared = ReaderBehaviorPreferenceStore()

    private enum DefaultsKey {
        static let automaticallyReloadsDocuments = "automaticallyReloadsDocuments"
        static let loadsRemoteImages = "loadsRemoteImages"
    }

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    var automaticallyReloadsDocuments: Bool {
        get {
            defaults.object(forKey: DefaultsKey.automaticallyReloadsDocuments) == nil
                ? true
                : defaults.bool(forKey: DefaultsKey.automaticallyReloadsDocuments)
        }
        set {
            guard automaticallyReloadsDocuments != newValue else {
                return
            }

            defaults.set(newValue, forKey: DefaultsKey.automaticallyReloadsDocuments)
            notificationCenter.post(
                name: .readerBehaviorPreferenceDidChange,
                object: self,
                userInfo: ["automaticallyReloadsDocuments": newValue]
            )
        }
    }

    var loadsRemoteImages: Bool {
        get {
            defaults.object(forKey: DefaultsKey.loadsRemoteImages) == nil
                ? true
                : defaults.bool(forKey: DefaultsKey.loadsRemoteImages)
        }
        set {
            guard loadsRemoteImages != newValue else {
                return
            }

            defaults.set(newValue, forKey: DefaultsKey.loadsRemoteImages)
            notificationCenter.post(
                name: .readerBehaviorPreferenceDidChange,
                object: self,
                userInfo: ["loadsRemoteImages": newValue]
            )
        }
    }
}
