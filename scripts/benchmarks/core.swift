import Foundation
import WaferCore
import Darwin
setbuf(stdout, nil)
precondition(ReaderTheme.resourceURL(named: "reader-theme.css") != nil)

func measure(_ name: String, repeats: Int = 3, _ body: () throws -> Int) rethrows {
    var samples: [Double] = []
    var checksum = 0
    for _ in 0..<repeats {
        let start = DispatchTime.now().uptimeNanoseconds
        checksum += try autoreleasepool { try body() }
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    print("\(name): ms=\(samples.map { String(format: "%.2f", $0) }.joined(separator: ",")) checksum=\(checksum)")
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("wafer-review-fixtures-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let paragraph = "Paragraph with **bold**, *italic*, `code`, and ordinary search terms for performance review.\n\n"
let note = "# Note title\n\n" + String(repeating: paragraph, count: 40)
for i in 0..<2000 { try note.write(to: root.appendingPathComponent("Note-\(i).md"), atomically: false, encoding: .utf8) }
print("Fixture: 2000 files, \(note.utf8.count) bytes each")
var files: [LibraryFile] = []
measure("scan2000-cold-index", repeats: 3) { let scan = LibraryScanner.scan(rootURL: root); files = scan.files; return scan.files.count }
measure("scan2000-cached", repeats: 5) { LibraryScanner.scan(rootURL: root, existingFiles: files).files.count }
measure("scan2000-one-dirty-file", repeats: 3) { LibraryScanner.scan(rootURL: root, existingFiles: files, changedPaths: [files[0].identity]).files.count }
measure("fullText2000-visible-snippets") { LibrarySearch.fullTextMatches(query: "performance", in: files, includesSnippets: false).count }
measure("quickOpen2000-query-note", repeats: 5) { LibrarySearch.quickOpenMatches(query: "note", in: files).count }
measure("fullText2000-query-performance") { LibrarySearch.fullTextMatches(query: "performance", in: files).count }
measure("diff2000-unchanged", repeats: 5) { LibraryIndexDiff.apply(scan: .init(files: files, truncated: false), to: files).files.count }
measure("backlinks2000-no-links", repeats: 5) { BacklinkIndex.build(files: files).count }
let linkedFiles = files.enumerated().map { i, file in
    LibraryFile(fileURL: file.fileURL, relativePathComponents: file.relativePathComponents, displayTitle: file.displayTitle, outlineItems: file.outlineItems, plainText: file.plainText, searchableText: file.searchableText, contentFingerprint: file.contentFingerprint, outgoingReferences: (1...10).map { .init(target: .markdownFile(files[(i + $0) % files.count].fileURL), contextSnippet: "Nearby text") })
}
measure("backlinks2000-20k-links") { BacklinkIndex.build(files: linkedFiles).count }
let parser = MarkdownParser()
let renderer = WebKitHTMLRenderer()
let docURL = root.appendingPathComponent("index.md")
for count in [0, 100, 1000] {
    let source = "# Index\n\n" + (0..<count).map { "[Note \($0)](Note-\($0).md)\n\n" }.joined()
    let document = parser.parse(source: source, baseURL: docURL)
    measure("render-index-\(count)-local-links") { renderer.render(document: document).html.utf8.count }
}
for count in [1000, 5000, 10000] {
    let source = "# Wiki stress\n\n" + String(repeating: "[[", count: count) + "target]]"
    measure("nested-wiki-\(count)", repeats: 3) { WikiLinkSyntax.spans(in: source).count }
}
let code = "let answer = 42\n"
for count in [1000, 10000] {
    let source = "# Code\n\n```swift\n" + String(repeating: code, count: count) + "```\n"
    measure("code-render-lines-\(count)") { renderer.render(document: parser.parse(source: source, baseURL: nil)).html.utf8.count }
}
