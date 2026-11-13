import Foundation
import WaferCore

extension Notification.Name {
    static let documentStatisticKindDidChange = Notification.Name("DocumentStatisticPreferenceStore.documentStatisticKindDidChange")
}

// Safe to share: immutable references to thread-safe UserDefaults and NotificationCenter.
final class DocumentStatisticPreferenceStore: @unchecked Sendable {
    static let shared = DocumentStatisticPreferenceStore()

    private enum DefaultsKey {
        static let selectedKind = "documentStatisticKind"
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

    var selectedKind: DocumentStatisticKind {
        get {
            guard
                let rawValue = defaults.string(forKey: DefaultsKey.selectedKind),
                let kind = DocumentStatisticKind(rawValue: rawValue)
            else {
                return .words
            }

            return kind
        }
        set {
            guard selectedKind != newValue else {
                return
            }

            defaults.set(newValue.rawValue, forKey: DefaultsKey.selectedKind)
            notificationCenter.post(name: .documentStatisticKindDidChange, object: self, userInfo: DocumentStatisticPreferenceChange(kind: newValue).userInfo)
        }
    }
}
