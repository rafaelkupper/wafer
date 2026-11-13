import Foundation

/// Static properties at call sites cache each script for the process lifetime.
enum ReaderScriptResource {
    static func load(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "Scripts"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Missing bundled reader script: \(name).js")
        }
        return source
    }
}
