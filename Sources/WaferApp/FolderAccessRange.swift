import Darwin
import Foundation
import WaferCore

/// What a folder prompt offers.
enum FolderAccessSuggestion: Equatable {
    /// Offer `folder`; `isWidened` when it lies above the document's own folder.
    case folder(URL, isWidened: Bool)
    /// `file` lies directly in `folder`, which is too broad to offer, so
    /// nothing is suggested.
    case outOfRange(file: URL, folder: URL)
}

/// Which folders a prompt may offer. A document's links and images decide
/// which file needs access, so a prompt never suggests, or opens its panel
/// at, a folder that exposes far more than the document: the home folder
/// or its Library, a volume root, a top-level folder such as /Users, or
/// anything above them. The user can still choose any folder in the panel.
struct FolderAccessRange: Sendable {
    /// How far above the document's own folder a suggestion may widen to
    /// also cover the files the document needs.
    static let maximumWideningLevels = 2

    static let current = FolderAccessRange(homeDirectory: realHomeDirectory())

    /// The user's real home folder. Inside the sandbox `NSHomeDirectory()`
    /// is the app's container.
    let homeDirectory: URL
    /// True for the root of a mounted volume: the startup disk, a drive, a share.
    let isVolumeRoot: @Sendable (URL) -> Bool

    init(homeDirectory: URL, isVolumeRoot: @escaping @Sendable (URL) -> Bool = FolderAccessRange.isMountedVolumeRoot) {
        self.homeDirectory = homeDirectory
        self.isVolumeRoot = isVolumeRoot
    }

    /// True when `folder` is too broad to offer: one of the floors above or
    /// a folder above one.
    func isTooBroad(_ folder: URL) -> Bool {
        let components = Self.canonicalComponents(of: folder)
        // The root and every top-level folder: /Users, /Volumes, /Library, ...
        if components.count <= 2 { return true }
        // Every user's home folder and every volume's root.
        if components.count == 3, components[1] == "users" || components[1] == "volumes" { return true }
        let home = Self.canonicalComponents(of: homeDirectory)
        if home.starts(with: components) || components == home + ["library"] { return true }
        return isVolumeRoot(folder)
    }

    /// The folder to offer for one file: its own folder, unless that is too broad.
    func suggestion(for file: URL) -> FolderAccessSuggestion {
        let folder = FileIdentity.normalized(file).deletingLastPathComponent()
        return isTooBroad(folder) ? .outOfRange(file: file, folder: folder) : .folder(folder, isWidened: false)
    }

    /// The folder to offer a document that needs `files`: its own folder,
    /// widened to the closest folder that also holds the needed files lying
    /// at most `maximumWideningLevels` levels above it, never reaching a
    /// folder too broad to offer. A needed file outside that window gets
    /// only its own folder, and one whose folder is too broad gets nothing.
    /// Nil when nothing can be offered and nothing is needed.
    func suggestion(forDocumentAt documentURL: URL, needing files: [URL]) -> FolderAccessSuggestion? {
        let documentFolder = FileIdentity.normalized(documentURL).deletingLastPathComponent()
        if let widest = widestFolder(forDocumentFolder: documentFolder) {
            let window = FileContainment(rootDirectory: widest)
            let nearby = files.filter { window.contains($0) }
            if !nearby.isEmpty || files.isEmpty {
                var common = documentFolder.pathComponents
                for file in nearby {
                    let folder = FileIdentity.normalized(file).deletingLastPathComponent().pathComponents
                    common = Array(zip(common, folder).prefix { $0 == $1 }.map(\.0))
                }
                var folder = URL(fileURLWithPath: NSString.path(withComponents: common), isDirectory: true)
                // Paths spelled through different symlinks share a shorter
                // prefix; the widest folder still holds every nearby file.
                if !window.contains(folder) { folder = widest }
                return .folder(folder, isWidened: folder.path != documentFolder.path)
            }
        }
        if let file = files.first(where: { !isTooBroad(FileIdentity.normalized($0).deletingLastPathComponent()) }) {
            return .folder(FileIdentity.normalized(file).deletingLastPathComponent(), isWidened: false)
        }
        return files.first.map(suggestion(for:))
    }

    /// The document's folder, or the folder up to `maximumWideningLevels`
    /// levels above it, stopping below the first folder too broad to offer.
    /// Nil when the document's folder is itself too broad.
    func widestFolder(forDocumentFolder documentFolder: URL) -> URL? {
        guard !isTooBroad(documentFolder) else { return nil }
        var widest = documentFolder
        for _ in 0..<Self.maximumWideningLevels {
            let parent = widest.deletingLastPathComponent()
            guard parent.path != widest.path, !isTooBroad(parent) else { break }
            widest = parent
        }
        return widest
    }

    /// Path components for comparing folders: standardized, symlinks
    /// resolved, lowercased (a case-insensitive disk accepts any spelling),
    /// with the startup disk's data volume (`/System/Volumes/Data`) and
    /// `/private` folded into the paths they appear as.
    static func canonicalComponents(of url: URL) -> [String] {
        var components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.map { $0.lowercased() }
        for prefix in [["/", "system", "volumes", "data"], ["/", "private"]]
        where components.count > prefix.count && components.starts(with: prefix) {
            components = ["/"] + components.dropFirst(prefix.count)
        }
        return components
    }

    @Sendable static func isMountedVolumeRoot(_ url: URL) -> Bool {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isVolumeKey]))?.isVolume == true
    }

    static func realHomeDirectory() -> URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
