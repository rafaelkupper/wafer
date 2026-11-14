import Foundation
import WaferCore

extension Notification.Name {
    static let libraryPreferenceDidChange = Notification.Name("LibraryPreferenceStore.libraryPreferenceDidChange")
}

// Safe to share: immutable references to thread-safe UserDefaults and NotificationCenter.
final class LibraryPreferenceStore: @unchecked Sendable {
    static let shared = LibraryPreferenceStore()

    private enum DefaultsKey {
        static let libraryFolderPath = "libraryFolderPath"
        static let libraryAccessPromptShown = "libraryAccessPromptShown"
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
            defaults.removeObject(forKey: DefaultsKey.libraryAccessPromptShown)

            notificationCenter.post(
                name: .libraryPreferenceDidChange,
                object: self,
                userInfo: LibraryPreferenceChange(folderURL: normalizedURL).userInfo
            )
        }
    }

    /// Whether Wafer already asked, once, to choose the saved library folder
    /// again because the App Sandbox could not read it. A new library choice
    /// clears it.
    var hasAskedForLibraryAccess: Bool {
        get { defaults.bool(forKey: DefaultsKey.libraryAccessPromptShown) }
        set {
            if newValue {
                defaults.set(true, forKey: DefaultsKey.libraryAccessPromptShown)
            } else {
                defaults.removeObject(forKey: DefaultsKey.libraryAccessPromptShown)
            }
        }
    }
}
