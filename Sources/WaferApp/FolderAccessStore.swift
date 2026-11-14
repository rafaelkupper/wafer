import Darwin
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

    /// Resolves `url` once and checks it against every root.
    func covers(_ url: URL) -> Bool {
        guard let roots else { return true }
        guard url.isFileURL else { return false }
        let candidate = FileContainment.Candidate(url)
        return roots.contains { $0.contains(candidate) }
    }
}

/// Whether a grant lets Wafer change files in its folder or only read them.
enum FolderAccessMode: String, Comparable, Sendable {
    case readOnly
    case readWrite

    static func < (lhs: FolderAccessMode, rhs: FolderAccessMode) -> Bool {
        lhs == .readOnly && rhs == .readWrite
    }
}

/// A granted folder, as the Folder Access window lists it.
struct FolderGrantInfo: Equatable, Identifiable {
    let id: String
    /// The folder's current path; a moved folder shows its new place.
    let folderURL: URL
    let mode: FolderAccessMode
    /// False while its bookmark cannot be resolved, such as on a disconnected drive.
    let isAvailable: Bool
    let isLibrary: Bool
}

/// The security-scoped bookmark calls the store makes. Tests replace them.
@MainActor
protocol SecurityScopedBookmarking {
    func bookmarkData(for url: URL, readOnly: Bool) throws -> Data
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool)
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

/// App-scoped security bookmarks (`com.apple.security.files.bookmarks.app-scope`).
struct SystemSecurityScopedBookmarks: SecurityScopedBookmarking {
    /// A read-only bookmark (`securityScopeAllowOnlyReadAccess`) restores
    /// access that lets Wafer read the folder but not change anything in it.
    func bookmarkData(for url: URL, readOnly: Bool) throws -> Data {
        try url.bookmarkData(
            options: readOnly ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess] : [.withSecurityScope],
            includingResourceValuesForKeys: nil, relativeTo: nil
        )
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        // No UI and no mounting: an absent volume leaves the grant unresolved
        // until it mounts.
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
/// and kept accessible for the whole session. Grants for reading a
/// document's images and links are read-only; the library's, and grants
/// asked for while editing, are read-write. The store also records which
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
        /// Stable across launches and moves; the library refers to its grant by it.
        let id: String
        /// The folder's path when the bookmark was last resolved or made.
        var path: String
        var bookmark: Data
        var mode: FolderAccessMode
        /// The library's own grant: stored even inside a broader grant and
        /// never replaced by one, so it follows the library folder.
        var isLibrary = false
        /// The resolved URL whose access this store started; stopped when the
        /// grant is superseded or removed.
        var accessURL: URL?
        /// Nil while the bookmark cannot be resolved or accessed.
        var containment: FileContainment?

        var folderURL: URL { URL(fileURLWithPath: path, isDirectory: true) }

        var record: [String: Any] {
            ["id": id, "path": path, "bookmark": bookmark, "readOnly": mode == .readOnly, "library": isLibrary]
        }
    }

    let isSandboxed: Bool
    /// The folders prompts may offer.
    let range: FolderAccessRange
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let bookmarks: SecurityScopedBookmarking
    private let canOpenForReading: @MainActor (URL) -> Bool
    /// The container, its temporary folder, and the app bundle.
    private let alwaysReadable: [FileContainment]
    /// The container and its temporary folder.
    private let alwaysWritable: [FileContainment]
    private var grants: [Grant] = [] {
        didSet { cachedScope = nil }
    }
    /// Files the user opened this session (Finder, Open, Open Recent).
    private var userSelections: [String: FileContainment] = [:] {
        didSet { cachedScope = nil }
    }
    /// `scope`, built once until the grants or selections change.
    private var cachedScope: FolderAccessScope?
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
        alwaysReadableRoots: [URL] = FolderAccessStore.defaultAlwaysReadableRoots(),
        alwaysWritableRoots: [URL] = FolderAccessStore.defaultAlwaysWritableRoots(),
        range: FolderAccessRange = .current,
        canOpenForReading: @escaping @MainActor (URL) -> Bool = FolderAccessStore.canOpenForReading
    ) {
        self.range = range
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.bookmarks = bookmarks
        self.isSandboxed = isSandboxed
        self.canOpenForReading = canOpenForReading
        self.alwaysReadable = isSandboxed ? alwaysReadableRoots.map { FileContainment(rootDirectory: $0) } : []
        self.alwaysWritable = isSandboxed ? alwaysWritableRoots.map { FileContainment(rootDirectory: $0) } : []
    }

    nonisolated static func defaultAlwaysReadableRoots() -> [URL] {
        defaultAlwaysWritableRoots() + [Bundle.main.bundleURL]
    }

    nonisolated static func defaultAlwaysWritableRoots() -> [URL] {
        [
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
            URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
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
            let id = record["id"] as? String ?? UUID().uuidString
            // Bookmarks stored before grants had a mode were read-write.
            let mode: FolderAccessMode = record["readOnly"] as? Bool == true ? .readOnly : .readWrite
            var grant = Grant(id: id, path: path, bookmark: bookmark, mode: mode, isLibrary: record["library"] as? Bool == true)
            changed = changed || record["id"] == nil || record["readOnly"] == nil
            changed = resolve(&grant) || changed
            grants.append(grant)
        }
        if changed { persistGrants() }
        Self.log.info("Restored access to \(self.grants.filter { $0.containment != nil }.count, privacy: .public) of \(self.grants.count, privacy: .public) granted folders")
    }

    /// Resolves an unresolved grant and starts its access. A moved or
    /// renamed folder resolves to its new place, and a stale bookmark is made
    /// again. Returns true when the stored record changed.
    private func resolve(_ grant: inout Grant) -> Bool {
        let path = grant.path
        do {
            let resolved = try bookmarks.resolve(grant.bookmark)
            guard bookmarks.startAccessing(resolved.url) else {
                Self.log.error("Could not access the granted folder \(path, privacy: .private)")
                return false
            }
            grant.accessURL = resolved.url
            grant.containment = FileContainment(rootDirectory: resolved.url)
            grant.path = FileIdentity.identity(for: resolved.url)
            var changed = grant.path != path
            if resolved.isStale {
                do {
                    grant.bookmark = try bookmarks.bookmarkData(for: resolved.url, readOnly: grant.mode == .readOnly)
                    changed = true
                } catch {
                    // Access works now; the old bookmark is tried again next launch.
                    Self.log.error("Could not refresh the bookmark for \(path, privacy: .private): \(error.localizedDescription, privacy: .public)")
                }
            }
            return changed
        } catch {
            Self.log.error("Could not restore access to \(path, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The folders Wafer can read now through stored grants.
    var grantedFolders: [URL] {
        restoreGrants()
        return grants.filter { $0.containment != nil }.map(\.folderURL)
    }

    /// Every stored grant, including unavailable ones, by path.
    var folderGrants: [FolderGrantInfo] {
        guard isSandboxed else { return [] }
        restoreGrants()
        return grants
            .map { FolderGrantInfo(id: $0.id, folderURL: $0.folderURL, mode: $0.mode, isAvailable: $0.containment != nil, isLibrary: $0.isLibrary) }
            .sorted { $0.folderURL.path.localizedStandardCompare($1.folderURL.path) == .orderedAscending }
    }

    /// Remembers a folder the user chose in an open panel or dropped on the
    /// app, for this and later launches. A grant inside one that allows at
    /// least as much adds nothing; a grant replaces the ones it contains that
    /// allow no more than it does (the library's stays). Choosing a granted
    /// folder again makes its bookmark again. Returns the documents whose
    /// needed files are now readable.
    @discardableResult
    func grantAccess(to folderURL: URL, mode: FolderAccessMode = .readOnly) -> Set<String> {
        guard isSandboxed else { return [] }
        restoreGrants()
        let path = FileIdentity.identity(for: folderURL)
        if grants.contains(where: { ($0.path != path || $0.isLibrary) && $0.mode >= mode && $0.containment?.contains(folderURL) == true }) {
            return pruneSatisfiedNeeds()
        }
        let mode = max(mode, grants.first { $0.path == path && !$0.isLibrary }?.mode ?? mode)
        guard let grant = makeGrant(for: folderURL, mode: mode) else { return pruneSatisfiedNeeds() }
        store(grant)
        return pruneSatisfiedNeeds()
    }

    /// The library folder as a read-write grant of its own: stored even
    /// inside a broader grant and never replaced by one, so its bookmark
    /// follows the folder when it is moved or renamed. A previous library's
    /// grant becomes an ordinary one. Returns the grant's identifier (nil
    /// outside the sandbox or when no bookmark can be made) and the
    /// documents whose needed files are now readable.
    func grantLibraryAccess(to folderURL: URL) -> (grantID: String?, documents: Set<String>) {
        guard isSandboxed else { return (nil, []) }
        restoreGrants()
        let path = FileIdentity.identity(for: folderURL)
        for index in grants.indices where grants[index].isLibrary && grants[index].path != path {
            grants[index].isLibrary = false
        }
        if let existing = grants.first(where: { $0.isLibrary && $0.path == path && $0.containment != nil }) {
            persistGrants()
            return (existing.id, pruneSatisfiedNeeds())
        }
        grants.removeAll { $0.isLibrary && $0.path == path }
        guard let grant = makeGrant(for: folderURL, mode: .readWrite, isLibrary: true) else {
            persistGrants()
            return (nil, pruneSatisfiedNeeds())
        }
        store(grant)
        return (grant.id, pruneSatisfiedNeeds())
    }

    /// Where the grant with this identifier's folder is now: a moved folder
    /// resolves to its new place at launch. Nil when there is no such grant.
    func folderURL(forGrantID id: String) -> URL? {
        restoreGrants()
        return grants.first { $0.id == id }?.folderURL
    }

    /// Close Library: the library's grant stays, as an ordinary grant.
    func releaseLibraryGrant() {
        restoreGrants()
        guard grants.contains(where: \.isLibrary) else { return }
        for index in grants.indices { grants[index].isLibrary = false }
        persistGrants()
    }

    /// Stops access to a granted folder and deletes its bookmark. Documents
    /// keep what they show; reading from the folder again asks for it.
    func revoke(grantID id: String) {
        restoreGrants()
        guard let index = grants.firstIndex(where: { $0.id == id }) else { return }
        let grant = grants.remove(at: index)
        grant.accessURL.map(bookmarks.stopAccessing)
        persistGrants()
        Self.log.info("Removed access to \(grant.path, privacy: .private)")
        postChange()
    }

    /// A new grant for `folderURL`, with its bookmark made and its access
    /// started. When no bookmark can be made, the folder stays readable for
    /// this session through the panel's own access, and nil is returned.
    private func makeGrant(for folderURL: URL, mode: FolderAccessMode, isLibrary: Bool = false) -> Grant? {
        let path = FileIdentity.identity(for: folderURL)
        do {
            var grant = Grant(id: UUID().uuidString, path: path,
                              bookmark: try bookmarks.bookmarkData(for: folderURL, readOnly: mode == .readOnly),
                              mode: mode, isLibrary: isLibrary)
            // Access from the panel lasts until quit; starting the bookmark's
            // own access keeps one rule for every grant.
            if let resolved = try? bookmarks.resolve(grant.bookmark), bookmarks.startAccessing(resolved.url) {
                grant.accessURL = resolved.url
                grant.path = FileIdentity.identity(for: resolved.url)
            }
            grant.containment = FileContainment(rootDirectory: folderURL)
            return grant
        } catch {
            Self.log.error("Could not remember access to \(path, privacy: .private): \(error.localizedDescription, privacy: .public)")
            userSelections[path] = FileContainment(rootDirectory: folderURL)
            return nil
        }
    }

    /// Adds `grant`, replacing the ordinary grants it contains that allow no
    /// more than it does.
    private func store(_ grant: Grant) {
        let containment = grant.containment ?? FileContainment(rootDirectory: grant.folderURL)
        let superseded = grants.filter { !$0.isLibrary && $0.mode <= grant.mode && containment.contains($0.folderURL) }
        grants.removeAll { existing in superseded.contains { $0.id == existing.id } }
        grants.append(grant)
        superseded.compactMap(\.accessURL).forEach(bookmarks.stopAccessing)
        persistGrants()
        Self.log.info("Granted \(grant.mode == .readOnly ? "read-only" : "read-write", privacy: .public) access to \(grant.path, privacy: .private), replacing \(superseded.count, privacy: .public) narrower grants")
    }

    /// Files the user opened directly. The sandbox lets Wafer read each of
    /// them, and only them, until it quits.
    func noteUserSelected(_ urls: [URL]) {
        guard isSandboxed else { return }
        for url in urls where url.isFileURL {
            userSelections[FileIdentity.identity(for: url)] = FileContainment(rootDirectory: url)
        }
    }

    /// A document chosen from Open Recent. AppKit restores access to recent
    /// documents from its own bookmarks, but recents saved without the
    /// sandbox (Wafer 2.1.1) have none, so only a file that opens now counts
    /// as opened by the user. Opening another one asks for its folder.
    func noteRecentDocumentOpened(_ url: URL) {
        guard isSandboxed, url.isFileURL else { return }
        guard canOpenForReading(url) else {
            Self.log.info("The recent document \(url.lastPathComponent, privacy: .private) is not readable without a folder grant")
            return
        }
        noteUserSelected([url])
    }

    /// The sandbox refused to read `fileURL`, so a session selection for it
    /// no longer applies, whatever the store believed.
    func noteReadRefused(_ fileURL: URL) {
        guard isSandboxed,
              userSelections.removeValue(forKey: FileIdentity.identity(for: fileURL)) != nil else { return }
        Self.log.info("Dropped the session access to \(fileURL.lastPathComponent, privacy: .private) after the sandbox refused a read")
    }

    /// Whether the sandbox lets this process open `url` for reading now.
    /// A refusal is reported as a sandbox violation, so call it only where
    /// access is genuinely unknown.
    nonisolated static func canOpenForReading(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
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
        if let cachedScope { return cachedScope }
        let scope = FolderAccessScope(roots: alwaysReadable + Array(userSelections.values) + grants.compactMap(\.containment))
        cachedScope = scope
        return scope
    }

    /// True when the sandbox lets Wafer read `url`: it lies in a granted
    /// folder, was opened by the user, or belongs to the app.
    func covers(_ url: URL) -> Bool {
        scope.covers(url)
    }

    /// True when the sandbox lets Wafer change `url`: the user opened it, it
    /// lies in a read-write grant, or it is in the container.
    func allowsWriting(_ url: URL) -> Bool {
        guard isSandboxed else { return true }
        restoreGrants()
        let candidate = FileContainment.Candidate(url)
        let roots = alwaysWritable + userSelections.values + grants.filter { $0.mode == .readWrite }.compactMap(\.containment)
        return roots.contains { $0.contains(candidate) }
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

    /// The folder to offer for Grant Access… in the document's window: its
    /// own folder, widened within `range` to also hold the files it needs,
    /// or a farther file's own folder (see `FolderAccessRange`).
    func suggestion(forDocumentAt documentURL: URL) -> FolderAccessSuggestion? {
        range.suggestion(forDocumentAt: documentURL, needing: unreadableFiles(neededByDocumentAt: documentURL))
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
        defaults.set(grants.map(\.record), forKey: DefaultsKey.grants)
    }

    private func postChange() {
        notificationCenter.post(name: .folderAccessDidChange, object: self)
    }
}
