import Darwin
import Foundation
import WaferCore

/// What a folder prompt offers.
enum FolderAccessSuggestion: Equatable {
    /// Offer `folder`; `isWidened` when it lies above the document's own folder.
    case folder(URL, isWidened: Bool)
    /// `file` lies directly in `folder`, which a prompt may not offer, so
    /// nothing is suggested.
    case outOfRange(file: URL, folder: URL)
}

/// Which folders a prompt may offer. A document's links and images decide
/// which file needs access, so a prompt never suggests, widens to, or opens
/// its panel at a folder that exposes far more than the document (the home
/// folder, a volume root, a top-level folder such as /Users, or anything
/// above them), or one that holds settings and secrets rather than
/// documents: a hidden folder (a path component starting with "."), such
/// as ~/.ssh, or anything in the home folder's Library, such as Keychains
/// or Application Support. The cloud drives macOS keeps in the Library are
/// the exception: folders inside iCloud Drive (`Mobile Documents/com~apple~CloudDocs`)
/// and inside a cloud storage provider's folder (`CloudStorage/<provider>`)
/// may be offered, but not those roots, which are whole drives, like a disk.
/// Other apps' iCloud folders in `Mobile Documents` are never offered. The
/// user can still choose any folder in the panel.
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
    /// `homeDirectory` as `canonicalComponents(of:)`, computed once.
    private let homeComponents: [String]

    init(homeDirectory: URL, isVolumeRoot: @escaping @Sendable (URL) -> Bool = FolderAccessRange.isMountedVolumeRoot) {
        self.homeDirectory = homeDirectory
        self.isVolumeRoot = isVolumeRoot
        self.homeComponents = Self.canonicalComponents(of: homeDirectory)
    }

    /// True when a prompt may offer `folder`: it is neither too broad nor a
    /// folder of settings and secrets (see the type's rules).
    func mayOffer(_ folder: URL) -> Bool {
        let components = Self.canonicalComponents(of: folder)
        return !isTooBroad(components) && !holdsSettings(components) && !isVolumeRoot(folder)
    }

    /// The root, every top-level folder (/Users, /Volumes, /Library, ...),
    /// every user's home folder and every volume's root in /Volumes, and
    /// the real home folder or a folder above it.
    private func isTooBroad(_ components: [String]) -> Bool {
        if components.count <= 2 { return true }
        if components.count == 3, components[1] == "users" || components[1] == "volumes" { return true }
        return homeComponents.starts(with: components)
    }

    /// A hidden folder or one inside a hidden folder, or the home folder's
    /// Library or anything in it, except folders inside its cloud drives.
    private func holdsSettings(_ components: [String]) -> Bool {
        if components.contains(where: { $0.hasPrefix(".") }) { return true }
        let library = homeComponents + ["library"]
        guard components.starts(with: library) else { return false }
        // Both cloud roots are two levels down; only folders below them hold documents.
        let inLibrary = components.dropFirst(library.count)
        let isInsideCloudDrive = inLibrary.count > 2
            && (inLibrary.starts(with: ["mobile documents", "com~apple~clouddocs"]) || inLibrary.first == "cloudstorage")
        return !isInsideCloudDrive
    }

    /// The folder to offer for one file: its own folder, unless a prompt may not offer it.
    func suggestion(for file: URL) -> FolderAccessSuggestion {
        let folder = FileIdentity.normalized(file).deletingLastPathComponent()
        return mayOffer(folder) ? .folder(folder, isWidened: false) : .outOfRange(file: file, folder: folder)
    }

    /// The folder to offer a document that needs `files`: its own folder,
    /// widened to the closest folder that also holds the needed files lying
    /// at most `maximumWideningLevels` levels above it, never reaching a
    /// folder a prompt may not offer. A needed file outside that window gets
    /// only its own folder, and one whose folder may not be offered gets
    /// nothing. Nil when nothing can be offered and nothing is needed.
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
        if let file = files.first(where: { mayOffer(FileIdentity.normalized($0).deletingLastPathComponent()) }) {
            return .folder(FileIdentity.normalized(file).deletingLastPathComponent(), isWidened: false)
        }
        return files.first.map(suggestion(for:))
    }

    /// The document's folder, or the folder up to `maximumWideningLevels`
    /// levels above it, stopping below the first folder a prompt may not
    /// offer. Nil when the document's folder itself may not be offered.
    func widestFolder(forDocumentFolder documentFolder: URL) -> URL? {
        guard mayOffer(documentFolder) else { return nil }
        var widest = documentFolder
        for _ in 0..<Self.maximumWideningLevels {
            let parent = widest.deletingLastPathComponent()
            guard parent.path != widest.path, mayOffer(parent) else { break }
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
