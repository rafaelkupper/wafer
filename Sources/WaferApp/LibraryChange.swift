import Foundation
import WaferCore

struct LibraryChange {
    let rootURL: URL?
    let files: [LibraryFile]
    let truncated: Bool
    let isScanning: Bool
    let contentChanged: Bool
    let availabilityChanged: Bool
    let diff: LibraryIndexDiff.Result?

    private enum Key {
        static let rootURL = "rootURL"
        static let files = "files"
        static let truncated = "truncated"
        static let isScanning = "isScanning"
        static let contentChanged = "contentChanged"
        static let availabilityChanged = "availabilityChanged"
        static let diff = "diff"
    }

    var userInfo: [AnyHashable: Any] {
        [
            Key.rootURL: rootURL as Any,
            Key.files: files,
            Key.truncated: truncated,
            Key.isScanning: isScanning,
            Key.contentChanged: contentChanged,
            Key.availabilityChanged: availabilityChanged,
            Key.diff: diff as Any,
        ]
    }

    static func value(from notification: Notification) -> Self? {
        guard notification.name == .libraryDidChange,
              let info = notification.userInfo,
              let files = info[Key.files] as? [LibraryFile],
              let truncated = info[Key.truncated] as? Bool,
              let isScanning = info[Key.isScanning] as? Bool,
              let contentChanged = info[Key.contentChanged] as? Bool,
              let availabilityChanged = info[Key.availabilityChanged] as? Bool else { return nil }
        return Self(
            rootURL: info[Key.rootURL] as? URL, files: files, truncated: truncated,
            isScanning: isScanning, contentChanged: contentChanged,
            availabilityChanged: availabilityChanged, diff: info[Key.diff] as? LibraryIndexDiff.Result
        )
    }
}
