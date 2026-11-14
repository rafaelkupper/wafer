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

    private static let payloadKey = "change"

    var userInfo: [AnyHashable: Any] {
        [Self.payloadKey: self]
    }

    static func value(from notification: Notification) -> Self? {
        guard notification.name == .libraryDidChange else { return nil }
        return notification.userInfo?[payloadKey] as? Self
    }
}
