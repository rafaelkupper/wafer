import AppKit

/// One reading surface: a document, its reader, and (via the document) its
/// navigation history.
///
/// Ownership rule: a tab owns its document strongly for as long as the tab
/// exists; the document lifecycle is additionally tracked by
/// `OpenDocumentRegistry`. The `NSDocument.close()` flow empties the
/// document's window-controller list, which is what breaks the
/// document -> host -> tab -> document reference cycle on teardown.
@MainActor
final class DocumentTab {
    let document: MarkdownReaderDocument
    let readerController: WebKitReaderViewController

    init(document: MarkdownReaderDocument, readerController: WebKitReaderViewController) {
        self.document = document
        self.readerController = readerController
    }
}
