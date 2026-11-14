import Foundation
import WaferCore

struct AppearancePreferenceChange {
    let selection: AppearanceSelection
    private static let key = "appearanceSelection"

    var userInfo: [AnyHashable: Any] { [Self.key: selection.rawValue] }

    static func value(from notification: Notification) -> Self? {
        guard notification.name == .appearancePreferenceDidChange,
              let rawValue = notification.userInfo?[key] as? String else { return nil }
        return Self(selection: AppearanceSelection(rawValue: rawValue))
    }
}

struct DocumentStatisticPreferenceChange {
    let kind: DocumentStatisticKind
    private static let key = "kind"

    var userInfo: [AnyHashable: Any] { [Self.key: kind.rawValue] }

    static func value(from notification: Notification) -> Self? {
        guard notification.name == .documentStatisticKindDidChange,
              let rawValue = notification.userInfo?[key] as? String,
              let kind = DocumentStatisticKind(rawValue: rawValue) else { return nil }
        return Self(kind: kind)
    }
}

struct LibraryPreferenceChange {
    let folderURL: URL?
    private static let key = "libraryFolderURL"

    var userInfo: [AnyHashable: Any] { [Self.key: folderURL as Any] }

    static func value(from notification: Notification) -> Self? {
        guard notification.name == .libraryPreferenceDidChange,
              notification.userInfo?[key] != nil else { return nil }
        return Self(folderURL: notification.userInfo?[key] as? URL)
    }
}

enum ReaderBehaviorPreferenceChange: Equatable {
    case automaticallyReloadsDocuments(Bool)
    case loadsRemoteImages(Bool)

    private static let reloadKey = "automaticallyReloadsDocuments"
    private static let imagesKey = "loadsRemoteImages"

    var userInfo: [AnyHashable: Any] {
        switch self {
        case .automaticallyReloadsDocuments(let value): [Self.reloadKey: value]
        case .loadsRemoteImages(let value): [Self.imagesKey: value]
        }
    }

    static func value(from notification: Notification) -> Self? {
        guard notification.name == .readerBehaviorPreferenceDidChange else { return nil }
        if let value = notification.userInfo?[reloadKey] as? Bool {
            return .automaticallyReloadsDocuments(value)
        }
        if let value = notification.userInfo?[imagesKey] as? Bool {
            return .loadsRemoteImages(value)
        }
        return nil
    }
}
