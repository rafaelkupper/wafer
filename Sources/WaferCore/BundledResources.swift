import Foundation

/// Finds SwiftPM resources in packaged apps, extensions, and development hosts.
/// Missing resources are packaging defects; callers must supply their fallback.
public enum BundledResources {
    public static func resourceURL(named name: String, bundleName: String) -> URL? {
        resourceURL(named: name, bundleName: bundleName, searchDirectories: searchDirectories)
    }

    static func resourceURL(named name: String, bundleName: String, searchDirectories: [URL]) -> URL? {
        let leaf = (name as NSString).lastPathComponent
        let candidates = name == leaf ? [name] : [name, leaf]
        for directory in searchDirectories {
            guard let bundle = Bundle(url: directory.appendingPathComponent(bundleName + ".bundle")) else { continue }
            for candidate in candidates {
                let path = candidate as NSString
                if let url = bundle.url(forResource: path.deletingPathExtension, withExtension: path.pathExtension) {
                    return url
                }
                if let url = bundle.resourceURL?.appendingPathComponent(candidate),
                   FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        WaferLog.resources.fault("Missing bundled resource \(bundleName, privacy: .public)/\(name, privacy: .public); using the caller's fallback.")
        return nil
    }

    private static let searchDirectories: [URL] = {
        var directories = [Bundle.main.resourceURL].compactMap { $0 }
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
            ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            directories.append(URL(fileURLWithPath: override))
        }
        #endif
        directories += [Bundle(for: ResourceBundleAnchor.self).resourceURL,
                        Bundle.main.bundleURL].compactMap { $0 }
        #if DEBUG
        directories.append(Bundle.main.bundleURL.deletingLastPathComponent())
        #endif
        return directories
    }()
}

private final class ResourceBundleAnchor: NSObject {}
