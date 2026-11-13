import Foundation

extension String {
    var escapedHTML: String {
        self
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    var escapedHTMLAttribute: String {
        escapedHTML.replacingOccurrences(of: "'", with: "&#39;")
    }

    var escapedJavaScriptString: String {
        self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    var strippingTaskListPrefix: String {
        let prefixes = ["[x] ", "[X] ", "[ ] "]
        for prefix in prefixes where hasPrefix(prefix) {
            return String(dropFirst(prefix.count))
        }
        return self
    }

    var collapsingWhitespace: String {
        replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public extension URL {
    /// The decoded heading ID, suitable for DOM lookup. URL.fragment may be percent encoded.
    var decodedFragment: String? {
        URLComponents(url: self, resolvingAgainstBaseURL: true)?.fragment
    }

    func standardizedFileURLPreservingFragment() -> URL {
        let standardizedURL = standardizedFileURL
        guard let fragment = decodedFragment else {
            return standardizedURL
        }

        var components = URLComponents(url: standardizedURL, resolvingAgainstBaseURL: true)
        components?.fragment = fragment
        return components?.url ?? standardizedURL
    }
}
