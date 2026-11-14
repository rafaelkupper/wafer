import Foundation
import os
import Security
import WaferCore

extension Notification.Name {
    /// Posted on the main thread when a folder grant is added or a document
    /// records a file the App Sandbox does not let Wafer read.
    static let folderAccessDidChange = Notification.Name("FolderAccessStore.folderAccessDidChange")
    /// Posted by the local asset scheme handler when the sandbox scope refuses
    /// an image. The object is the requesting web view; `fileURL` is in userInfo.
    static let localAssetAccessDenied = Notification.Name("FolderAccessStore.localAssetAccessDenied")
}

/// Whether this process runs in the App Sandbox. XCTest and `swift run`
/// processes are not sandboxed, so there every path stays readable.
enum AppSandbox {
    static let isActive: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil)
        else { return false }
        return (value as? Bool) == true
    }()
}

/// The folders and files Wafer may read, captured for work off the main
/// thread. Outside the sandbox it covers every path.
struct FolderAccessScope: Sendable {
    static let unrestricted = FolderAccessScope(roots: nil)

    /// Nil when every path is readable.
    private let roots: [FileContainment]?

    init(roots: [FileContainment]?) {
        self.roots = roots
    }

    func covers(_ url: URL) -> Bool {
        guard let roots else { return true }
        return url.isFileURL && roots.contains { $0.contains(url) }
    }
}

/// The security-scoped bookmark calls the store makes. Tests replace them.
@MainActor
protocol SecurityScopedBookmarking {
    func bookmarkData(for url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool)
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

/// App-scoped security bookmarks (`com.apple.security.files.bookmarks.app-scope`).
struct SystemSecurityScopedBookmarks: SecurityScopedBookmarking {
    func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        // No UI and no mounting at launch: an absent volume leaves the grant
        // unresolved until a later launch.
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

/// Folder grants under the App Sandbox. A file the user opens grants only
/// itself; folders the user chooses (the library, or Grant Access… in a
/// window) are stored as app-scoped security bookmarks, resolved at launch,
/// and kept accessible for the whole session. The store also records which
/// files each document needed but could not read, for the window notice.
@MainActor
final class FolderAccessStore {
    /// Replaced in tests that exercise the sandboxed behavior.
    static var shared = FolderAccessStore()

    static let log = Logger(subsystem: WaferLog.subsystem, category: "access")

    private enum DefaultsKey {
        static let grants = "folderAccessGrants"
    }

    private struct Grant {
        /// The folder's path when the bookmark was last made.
        var path: String
        var bookmark: Data
        /// The resolved URL whose access this store started; stopped when the
        /// grant is superseded.
        var accessURL: URL?
        /// Nil while the bookmark cannot be resolved or accessed.
        var containment: FileContainment?
    }

    let isSandboxed: Bool
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let bookmarks: SecurityScopedBookmarking
    /// The container, its temporary folder, and the app bundle.
    private let alwaysReadable: [FileContainment]
    private var grants: [Grant] = []
    /// Files the user opened this session (Finder, Open, Open Recent).
    private var userSelections: [String: FileContainment] = [:]
    private var hasRestored = false
    /// Linked documents each document shows; replaced on every render.
    private var linkNeeds: [String: Set<URL>] = [:]
    /// Images, link targets, and the document's own file that failed to read.
    private var fileNeeds: [String: Set<URL>] = [:]

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        bookmarks: SecurityScopedBookmarking = SystemSecurityScopedBookmarks(),
        isSandboxed: Bool = AppSandbox.isActive,
        alwaysReadableRoots: [URL] = FolderAccessStore.defaultAlwaysReadableRoots()
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.bookmarks = bookmarks
        self.isSandboxed = isSandboxed
        self.alwaysReadable = isSandboxed ? alwaysReadableRoots.map { FileContainment(rootDirectory: $0) } : []
    }

    nonisolated static func defaultAlwaysReadableRoots() -> [URL] {
        [
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            Bundle.main.bundleURL,
        ]
    }

    // MARK: Grants

    /// Resolves the stored bookmarks and starts access to each folder. Stale
    /// bookmarks are made again; unresolvable ones are kept for a later
    /// launch (a disconnected drive) but cover nothing now. Runs once.
    func restoreGrants() {
        guard isSandboxed, !hasRestored else { return }
        hasRestored = true
        var changed = false
        for record in defaults.array(forKey: DefaultsKey.grants) ?? [] {
            guard let record = record as? [String: Any], let path = record["path"] as? String,
                  let bookmark = record["bookmark"] as? Data else {
                changed = true
                continue
            }
            var grant = Grant(path: path, bookmark: bookmark)
            do {
                let resolved = try bookmarks.resolve(bookmark)
                if bookmarks.startAccessing(resolved.url) {
                    grant.accessURL = resolved.url
                    grant.containment = FileContainment(rootDirectory: resolved.url)
                    // A moved or renamed folder resolves to its new place.
                    grant.path = FileIdentity.identity(for: resolved.url)
                    if resolved.isStale {
                        grant.bookmark = try bookmarks.bookmarkData(for: resolved.url)
                    }
                    changed = changed || resolved.isStale || grant.path != path
                } else {
                    Self.log.error("Could not access the granted folder \(path, privacy: .private)")
                }
            } catch {
                Self.log.error("Could not restore access to \(path, privacy: .private): \(error.localizedDescription, privacy: .public)")
            }
            grants.append(grant)
        }
        if changed { persistGrants() }
        Self.log.info("Restored access to \(self.grants.filter { $0.containment != nil }.count, privacy: .public) of \(self.grants.count, privacy: .public) granted folders")
    }

    /// The folders Wafer can read now through stored grants.
    var grantedFolders: [URL] {
        restoreGrants()
        return grants.filter { $0.containment != nil }.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    /// Remembers a folder the user chose in an open panel or dropped on the
    /// app, for this and later launches. A grant inside an existing one adds
    /// nothing; a grant that contains existing ones replaces them. Returns the
    /// documents whose needed files are now readable.
    @discardableResult
    func grantAccess(to folderURL: URL) -> Set<String> {
        guard isSandboxed else { return [] }
        restoreGrants()
        let containment = FileContainment(rootDirectory: folderURL)
        let path = FileIdentity.identity(for: folderURL)
        if grants.contains(where: { $0.containment?.contains(folderURL) == true }) {
            return pruneSatisfiedNeeds()
        }

        do {
            var grant = Grant(path: path, bookmark: try bookmarks.bookmarkData(for: folderURL))
            // Access from the panel lasts until quit; starting the bookmark's
            // own access keeps one rule for every grant.
            if let resolved = try? bookmarks.resolve(grant.bookmark), bookmarks.startAccessing(resolved.url) {
                grant.accessURL = resolved.url
                grant.path = FileIdentity.identity(for: resolved.url)
            }
            grant.containment = containment
            let superseded = grants.filter { containment.contains(URL(fileURLWithPath: $0.path, isDirectory: true)) }
            grants.removeAll { containment.contains(URL(fileURLWithPath: $0.path, isDirectory: true)) }
            grants.append(grant)
            superseded.compactMap(\.accessURL).forEach(bookmarks.stopAccessing)
            persistGrants()
            Self.log.info("Granted access to \(path, privacy: .private), replacing \(superseded.count, privacy: .public) narrower grants")
        } catch {
            // Still readable this session through the panel's own access.
            Self.log.error("Could not remember access to \(path, privacy: .private): \(error.localizedDescription, privacy: .public)")
            userSelections[path] = containment
        }
        return pruneSatisfiedNeeds()
    }

    /// Files the user opened directly. The sandbox lets Wafer read each of
    /// them, and only them, until it quits.
    func noteUserSelected(_ urls: [URL]) {
        guard isSandboxed else { return }
        for url in urls where url.isFileURL {
            userSelections[FileIdentity.identity(for: url)] = FileContainment(rootDirectory: url)
        }
    }

    /// Stops access started for grants. Called when the app terminates.
    func stopAccessingAll() {
        grants.compactMap(\.accessURL).forEach(bookmarks.stopAccessing)
        for index in grants.indices {
            grants[index].accessURL = nil
            grants[index].containment = nil
        }
    }

    // MARK: Coverage

    /// What Wafer may read now. Pass it to background reads.
    var scope: FolderAccessScope {
        guard isSandboxed else { return .unrestricted }
        restoreGrants()
        return FolderAccessScope(roots: alwaysReadable + Array(userSelections.values) + grants.compactMap(\.containment))
    }

    /// True when the sandbox lets Wafer read `url`: it lies in a granted
    /// folder, was opened by the user, or belongs to the app.
    func covers(_ url: URL) -> Bool {
        scope.covers(url)
    }

    // MARK: Needed files

    /// Replaces the linked documents `documentURL` shows that Wafer cannot
    /// read (the Documents sidebar and its summaries).
    func recordLinkedFiles(_ fileURLs: [URL], forDocumentAt documentURL: URL) {
        guard isSandboxed else { return }
        let scope = self.scope
        let key = FileIdentity.identity(for: documentURL)
        let unreadable = Set(fileURLs.filter { !scope.covers($0) }.map(FileIdentity.normalized))
        guard linkNeeds[key, default: []] != unreadable else { return }
        linkNeeds[key] = unreadable.isEmpty ? nil : unreadable
        Self.log.info("\(documentURL.lastPathComponent, privacy: .private) links to \(unreadable.count, privacy: .public) files outside the granted folders")
        postChange()
    }

    /// Records a file `documentURL` failed to read: an image, a link target,
    /// or the document itself on reload.
    func recordUnreadableFile(_ fileURL: URL, forDocumentAt documentURL: URL) {
        guard isSandboxed else { return }
        let file = FileIdentity.normalized(fileURL)
        // A read failed, so a session selection for this file no longer applies.
        if userSelections.removeValue(forKey: FileIdentity.identity(for: file)) == nil, covers(file) {
            return
        }
        guard fileNeeds[FileIdentity.identity(for: documentURL), default: []].insert(file).inserted else { return }
        Self.log.info("\(documentURL.lastPathComponent, privacy: .private) could not read \(file.lastPathComponent, privacy: .private) outside the granted folders")
        postChange()
    }

    /// The files `documentURL` needs that Wafer still cannot read, by path.
    func unreadableFiles(neededByDocumentAt documentURL: URL) -> [URL] {
        guard isSandboxed else { return [] }
        let key = FileIdentity.identity(for: documentURL)
        let scope = self.scope
        return linkNeeds[key, default: []].union(fileNeeds[key, default: []])
            .filter { !scope.covers($0) }
            .sorted { $0.path < $1.path }
    }

    /// The folder to offer: the document's folder, widened to the closest
    /// folder that also holds the files it needs. Folders just below the root
    /// (such as /Users or /Volumes) are never suggested.
    func suggestedFolder(forDocumentAt documentURL: URL) -> URL {
        let documentFolder = FileIdentity.normalized(documentURL).deletingLastPathComponent()
        var common = documentFolder.pathComponents
        for file in unreadableFiles(neededByDocumentAt: documentURL) {
            let folder = file.deletingLastPathComponent().pathComponents
            common = Array(zip(common, folder).prefix { $0 == $1 }.map(\.0))
        }
        guard common.count > 2, common.count < documentFolder.pathComponents.count else {
            return documentFolder
        }
        return URL(fileURLWithPath: NSString.path(withComponents: common), isDirectory: true)
    }

    // MARK: Private

    /// Drops needs that a new grant satisfied and returns their documents.
    private func pruneSatisfiedNeeds() -> Set<String> {
        let scope = self.scope
        var satisfied: Set<String> = []
        func prune(_ needs: inout [String: Set<URL>]) {
            for (key, files) in needs {
                let remaining = files.filter { !scope.covers($0) }
                guard remaining.count != files.count else { continue }
                satisfied.insert(key)
                needs[key] = remaining.isEmpty ? nil : remaining
            }
        }
        prune(&linkNeeds)
        prune(&fileNeeds)
        postChange()
        return satisfied
    }

    private func persistGrants() {
        defaults.set(grants.map { ["path": $0.path, "bookmark": $0.bookmark] as [String: Any] }, forKey: DefaultsKey.grants)
    }

    private func postChange() {
        notificationCenter.post(name: .folderAccessDidChange, object: self)
    }
}
