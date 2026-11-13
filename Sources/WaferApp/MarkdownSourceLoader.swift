import Foundation
import WaferCore

/// One document's loaded source and background reads, including generation
/// checks and reload coalescing. Windows, history, and editing stay with the document.
@MainActor
final class MarkdownSourceLoader {
    typealias Load = @Sendable (_ fileURL: URL) throws -> LoadedMarkdownSource

    /// The source read in progress, if any. A read that is superseded or
    /// abandoned bumps `loadGeneration`, and its completion is discarded.
    enum LoadState: Equatable {
        case idle
        /// Reading the file the document was opened with.
        case opening(URL)
        /// Reading another file to show in place of the current one.
        case navigating(URL)
        /// Re-reading the current file (file monitor or Cmd-R).
        case reloading(URL)

        var url: URL? {
            switch self {
            case .idle:
                nil
            case .opening(let url), .navigating(let url), .reloading(let url):
                url
            }
        }

        /// Back and Forward wait until an open or navigation read finishes.
        var isNavigating: Bool {
            switch self {
            case .opening, .navigating:
                true
            case .idle, .reloading:
                false
            }
        }
    }

    var source: LoadedMarkdownSource?
    private(set) var state = LoadState.idle
    private var loadGeneration = 0
    /// A reload requested during a read; true if any request was explicit.
    var deferredReload: Bool?
    private let load: Load

    init(load: @escaping Load) {
        self.load = load
    }

    /// All app-driven source reads, decoding, and hashing run off the main
    /// thread. `state` names the read; a superseding read or close discards
    /// both successful and failed results.
    func read(
        _ state: LoadState,
        completion: @escaping @MainActor (Result<LoadedMarkdownSource, Error>) -> Void
    ) {
        guard let url = state.url else { return }
        loadGeneration += 1
        let generation = loadGeneration
        self.state = state
        let loader = load
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try loader(url) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.loadGeneration == generation else { return }
                self.state = .idle
                completion(result)
            }
        }
    }

    /// Discards the read in progress, if any.
    func abandon() {
        loadGeneration += 1
        state = .idle
    }

    /// Nil success means the fingerprint is unchanged. Explicit reloads
    /// return the source even then, so the document can refresh its assets.
    func reload(
        fileURL: URL?, forceRender: Bool,
        completion: @escaping @MainActor (Result<LoadedMarkdownSource?, Error>) -> Void
    ) {
        guard state == .idle else {
            deferredReload = (deferredReload ?? false) || forceRender
            return
        }
        guard let fileURL else { return }
        read(.reloading(fileURL)) { [weak self] result in
            guard let self else { return }
            completion(result.map { loaded in
                forceRender || loaded.fingerprint != self.source?.fingerprint ? loaded : nil
            })
        }
    }

    /// The largest Markdown file Wafer opens, 32 MB as Finder counts it: far
    /// above real notes and generated references, and small enough that
    /// parsing, rendering, and the editor stay usable. Larger files are
    /// refused as a whole, never read, shown, or edited in part.
    nonisolated static let maximumSourceByteCount = 32_000_000

    /// The production source loader: reads, decodes, and fingerprints a file.
    nonisolated static func loadSource(from fileURL: URL) throws -> LoadedMarkdownSource {
        let data: Data
        do {
            data = try BoundedFileReader.read(from: fileURL, maximumByteCount: maximumSourceByteCount)
        } catch BoundedFileReader.ReadError.tooLarge {
            throw tooLargeError(for: fileURL)
        }
        return try decodeSource(data)
    }

    nonisolated static func decodeSource(_ data: Data, fileURL: URL? = nil) throws -> LoadedMarkdownSource {
        guard data.count <= maximumSourceByteCount else { throw tooLargeError(for: fileURL) }
        guard let decoded = MarkdownTextFormat.decode(data) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }

        return LoadedMarkdownSource(
            sourceText: decoded.text,
            fingerprint: FileFingerprint.sha256Hex(for: data),
            format: decoded.format
        )
    }

    /// "The item X couldn't be opened because it is too large", with the limit.
    nonisolated static func tooLargeError(for fileURL: URL?) -> CocoaError {
        let limit = ByteCountFormatter.string(fromByteCount: Int64(maximumSourceByteCount), countStyle: .file)
        var userInfo: [String: Any] = [
            NSLocalizedRecoverySuggestionErrorKey: "Wafer opens Markdown files up to \(limit).",
        ]
        if let fileURL {
            userInfo[NSURLErrorKey] = fileURL
            userInfo[NSFilePathErrorKey] = fileURL.path
        }
        return CocoaError(.fileReadTooLarge, userInfo: userInfo)
    }
}

/// A file's decoded text, its on-disk format, and the fingerprint of its bytes.
struct LoadedMarkdownSource: Sendable {
    var sourceText: String
    var fingerprint: String
    var format: MarkdownTextFormat = .default
}
