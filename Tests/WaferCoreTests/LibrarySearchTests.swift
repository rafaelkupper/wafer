import Foundation
import XCTest
@testable import WaferCore

final class LibrarySearchTests: XCTestCase {
    func testFullTextRankingOrdersFilenamePrefixSubstringTitleHeadingThenBody() {
        let files = [
            libraryFile(path: "AlphaNotes.md", title: "Zed", plainText: "Plain body."),
            libraryFile(path: "MyAlphaNotes.md", title: "Zed", plainText: "Plain body."),
            libraryFile(path: "Title.md", title: "Alpha Title", plainText: "Plain body."),
            libraryFile(
                path: "Heading.md",
                title: "Zed",
                plainText: "Plain body.",
                outlineItems: [DocumentOutlineItem(title: "Alpha Heading", level: 2, anchorID: "alpha-heading")]
            ),
            libraryFile(path: "Body.md", title: "Zed", plainText: "Alpha alpha alpha body."),
        ]

        let matches = LibrarySearch.fullTextMatches(query: "alpha", in: files)

        XCTAssertEqual(matches.map { $0.file.relativePathForTesting }, [
            "AlphaNotes.md",
            "MyAlphaNotes.md",
            "Title.md",
            "Heading.md",
            "Body.md",
        ])
        XCTAssertEqual(matches[3].matchedAnchorID, "alpha-heading")
    }

    func testFullTextSearchUsesTokenAndSemanticsAcrossBodyText() {
        let files = [
            libraryFile(path: "Match.md", title: "Match", plainText: "Red paragraph. Blue paragraph."),
            libraryFile(path: "Miss.md", title: "Miss", plainText: "Red paragraph only."),
        ]

        let matches = LibrarySearch.fullTextMatches(query: "red blue", in: files)

        XCTAssertEqual(matches.map { $0.file.relativePathForTesting }, ["Match.md"])
    }

    func testFullTextSearchIsCaseAndDiacriticInsensitive() {
        let file = libraryFile(path: "Cafe.md", title: "Coffee", plainText: "A quiet Café table.")

        let matches = LibrarySearch.fullTextMatches(query: "CAFE", in: [file])

        XCTAssertEqual(matches.first?.file.relativePathForTesting, "Cafe.md")
        XCTAssertTrue(matches.first?.snippet.contains("Café") == true)
    }

    func testBodyRankingKeepsRepeatedSubstringCountsAndNormalizedSnippets() {
        let repeated = libraryFile(path: "Repeated.md", title: "Zed", plainText: "Banana banana bandana. Café CAFE café.")
        let single = libraryFile(path: "Single.md", title: "Zed", plainText: "Banana café.")
        let matches = LibrarySearch.fullTextMatches(query: "ana", in: [single, repeated])
        XCTAssertEqual(matches.map(\.file.relativePath), ["Repeated.md", "Single.md"])
        XCTAssertEqual(matches.map(\.score), [10_003, 10_001])
        XCTAssertEqual(LibrarySearch.fullTextMatches(query: "CAFE", in: [repeated]).first?.score, 10_003)
        XCTAssertEqual(LibrarySearch.fullTextMatches(query: "ana cafe", in: [repeated]).first?.score, 10_006)
        XCTAssertTrue(LibrarySearch.snippet(query: "cafe", in: repeated).contains("Café"))
    }

    func testHeadingMatchUsesDuplicateSafeSlugFromOutlineItems() {
        let file = libraryFile(
            path: "Sections.md",
            title: "Sections",
            plainText: "Opening body.",
            outlineItems: [
                DocumentOutlineItem(title: "Section", level: 2, anchorID: "section"),
                DocumentOutlineItem(title: "Section", level: 2, anchorID: "section-2"),
            ]
        )

        let match = LibrarySearch.fullTextMatches(query: "section", in: [file]).first

        XCTAssertEqual(match?.matchedAnchorID, "section")
    }

    func testSnippetCentersFirstBodyMatchAndEllipsizes() {
        let text = """
        This intro is intentionally long enough to sit before the match. It keeps going for a while before the needle appears near the middle. After the needle, there is enough trailing prose to require an ending ellipsis.
        """
        let file = libraryFile(path: "Needle.md", title: "Needle", plainText: text)

        let snippet = LibrarySearch.fullTextMatches(query: "needle", in: [file]).first?.snippet

        XCTAssertNotNil(snippet)
        XCTAssertTrue(snippet?.hasPrefix("...") == true)
        XCTAssertTrue(snippet?.hasSuffix("...") == true)
        XCTAssertTrue(snippet?.contains("needle appears") == true)
        XCTAssertLessThanOrEqual(snippet?.count ?? 0, 143)
    }

    func testQuickOpenUsesSubsequenceMatchingAndWordBoundaryBonus() {
        let files = [
            libraryFile(path: "RenderingShowcase.md", title: "Rendering", plainText: ""),
            libraryFile(path: "indsideways.md", title: "Other", plainText: ""),
            libraryFile(path: "DocumentSidebar.md", title: "Sidebar", plainText: ""),
        ]

        XCTAssertEqual(
            LibrarySearch.quickOpenMatches(query: "rsh", in: files).map { $0.relativePathForTesting },
            ["RenderingShowcase.md"]
        )
        XCTAssertEqual(
            LibrarySearch.quickOpenMatches(query: "ds", in: [files[1], files[2]]).map { $0.relativePathForTesting },
            ["DocumentSidebar.md", "indsideways.md"]
        )
    }

    func testQuickOpenScoresWordBoundariesAfterRemovedSpaces() {
        let files = [
            libraryFile(path: "mynotesfile.md", title: "Flat", plainText: ""),
            libraryFile(path: "My Notes File.md", title: "Spaced", plainText: ""),
        ]

        XCTAssertEqual(
            LibrarySearch.quickOpenMatches(query: "mnf", in: files).map { $0.relativePathForTesting },
            ["My Notes File.md", "mynotesfile.md"]
        )
    }

    func testQuickOpenKeepsDiacriticFoldedCharactersAlignedWithBoundaries() {
        let files = [
            libraryFile(path: "rxxp.md", title: "Flat", plainText: ""),
            libraryFile(path: "Rosé Pine.md", title: "Accent", plainText: ""),
        ]

        XCTAssertEqual(
            LibrarySearch.quickOpenMatches(query: "rp", in: files).map { $0.relativePathForTesting },
            ["Rosé Pine.md", "rxxp.md"]
        )
    }

    func testQuickOpenScoresSpaceContainingRelativePathsWithAlignedCharacters() {
        let files = [
            libraryFile(path: "projectdocsmap.md", title: "Flat", plainText: ""),
            libraryFile(path: "Project Docs/Map.md", title: "Spaced", plainText: ""),
        ]

        XCTAssertEqual(
            LibrarySearch.quickOpenMatches(query: "dm", in: files).map { $0.relativePathForTesting },
            ["Project Docs/Map.md", "projectdocsmap.md"]
        )
    }

    func testQuickOpenCapsResultsAtFifty() {
        let files = (1...60).map { index in
            libraryFile(path: String(format: "Alpha%02d.md", index), title: "Alpha", plainText: "")
        }

        let matches = LibrarySearch.quickOpenMatches(query: "a", in: files)

        XCTAssertEqual(matches.count, 50)
        XCTAssertEqual(matches.first?.relativePathForTesting, "Alpha01.md")
    }

    func testSearchResultsAreDeterministic() {
        let files = [
            libraryFile(path: "Beta.md", title: "Beta", plainText: "shared token"),
            libraryFile(path: "Alpha.md", title: "Alpha", plainText: "shared token"),
        ]

        let first = LibrarySearch.fullTextMatches(query: "shared", in: files)
        let second = LibrarySearch.fullTextMatches(query: "shared", in: files)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map { $0.file.relativePathForTesting }, ["Alpha.md", "Beta.md"])
    }

    private func libraryFile(
        path: String,
        title: String,
        plainText: String,
        outlineItems: [DocumentOutlineItem] = []
    ) -> LibraryFile {
        LibraryFile(
            fileURL: URL(fileURLWithPath: "/tmp/\(path)"),
            relativePathComponents: path.split(separator: "/").map(String.init),
            displayTitle: title,
            outlineItems: outlineItems,
            plainText: plainText.collapsingWhitespace,
            searchableText: plainText.libraryFoldedSearchText,
            contentFingerprint: LibraryFileFingerprint(modificationDate: Date(timeIntervalSince1970: 0), fileSize: 0)
        )
    }
}

private extension LibraryFile {
    var relativePathForTesting: String {
        relativePathComponents.joined(separator: "/")
    }
}
