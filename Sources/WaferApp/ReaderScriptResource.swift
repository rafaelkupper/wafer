import Foundation
import WaferCore

/// Static properties at call sites cache each script for the process lifetime.
enum ReaderScriptResource {
    static func load(_ name: String) -> String {
        let packaged = Bundle.main.resourceURL.flatMap {
            Bundle(url: $0.appendingPathComponent("Wafer_WaferApp.bundle", isDirectory: true))
        }
        #if DEBUG
        return load(name, packagedBundle: packaged, fallbackBundle: .module)
        #else
        return load(name, packagedBundle: packaged, fallbackBundle: nil)
        #endif
    }

    static func load(_ name: String, packagedBundle: Bundle?, fallbackBundle: @autoclosure () -> Bundle?) -> String {
        let url = packagedBundle?.url(forResource: name, withExtension: "js", subdirectory: "Scripts")
            ?? fallbackBundle()?.url(forResource: name, withExtension: "js", subdirectory: "Scripts")
        guard let url, let source = try? String(contentsOf: url, encoding: .utf8) else {
            WaferLog.resources.fault("Missing or unreadable reader script: \(name, privacy: .public).js; disabling its reader helpers.")
            return ""
        }
        return source
    }
}
