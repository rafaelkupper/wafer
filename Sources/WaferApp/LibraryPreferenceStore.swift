import Foundation
import WaferCore

extension Notification.Name {
    static let libraryPreferenceDidChange = Notification.Name("LibraryPreferenceStore.libraryPreferenceDidChange")
}

final class LibraryPreferenceStore: @unchecked Sendable {
    static let shared = LibraryPreferenceStore()

    private enum DefaultsKey {
        static let libraryFolderPath = "libraryFolderPath"
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

    var libraryFolderURL: URL? {
        get {
            guard let path = defaults.string(forKey: DefaultsKey.libraryFolderPath), !path.isEmpty else {
                return nil
            }

            return FileIdentity.normalized(URL(fileURLWithPath: path, isDirectory: true))
        }
        set {
            let normalizedURL = newValue.map(FileIdentity.normalized)
            guard libraryFolderURL != normalizedURL else {
                return
            }

            if let normalizedURL {
                defaults.set(normalizedURL.path, forKey: DefaultsKey.libraryFolderPath)
            } else {
                defaults.removeObject(forKey: DefaultsKey.libraryFolderPath)
            }

            notificationCenter.post(
                name: .libraryPreferenceDidChange,
                object: self,
                userInfo: ["libraryFolderURL": normalizedURL as Any]
            )
        }
    }
}
