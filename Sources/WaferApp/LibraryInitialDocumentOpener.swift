import AppKit
import WaferCore

@MainActor
enum LibraryInitialDocumentOpener {
    static func openFirstDocumentIfNoMarkdownWindow(
        files: [LibraryFile],
        hasVisibleMarkdownWindow: () -> Bool = { MarkdownDocumentOpener.hasVisibleMarkdownWindow },
        openDocument: (URL) throws -> Void = { try MarkdownDocumentOpener.open(url: $0) },
        presentError: (Error) -> Void = { NSApp.presentError($0) }
    ) {
        guard !hasVisibleMarkdownWindow() else {
            return
        }

        guard let firstFileURL = files.first?.fileURL else {
            return
        }

        do {
            try openDocument(firstFileURL)
        } catch {
            presentError(error)
        }
    }
}
