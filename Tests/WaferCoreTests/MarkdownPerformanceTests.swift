import XCTest
@testable import WaferCore

final class MarkdownPerformanceTests: XCTestCase {
    // These budgets exercise 20 passes through the four compatibility fixtures.
    // Use a median of three warm samples to tolerate isolated scheduler stalls.
    // See docs/benchmarks/2026-11-13-round-4.md for calibration and scope.
    func testCorpusParseBudget() throws {
        let fixtures = try corpusFixtures()
        let parser = MarkdownParser()
        var parsedBytes = 0
        let median = medianDuration {
            parsedBytes = 0
            for _ in 0..<20 {
                for (url, source) in fixtures {
                    let document = parser.parse(source: source, baseURL: url)
                    parsedBytes += document.source.utf8.count
                }
            }
        }
        XCTAssertEqual(parsedBytes, 20 * fixtures.reduce(0) { $0 + $1.1.utf8.count })
        print("Corpus parse median: \(median) s")
        XCTAssertLessThan(median, 0.3, "Gross parse regression on the compatibility corpus")
    }

    func testCorpusRenderBudget() throws {
        let parser = MarkdownParser()
        let documents = try corpusFixtures().map { parser.parse(source: $0.1, baseURL: $0.0) }
        let renderer = WebKitHTMLRenderer()
        var renderedBytes = 0
        let median = medianDuration {
            renderedBytes = 0
            for _ in 0..<20 {
                for document in documents {
                    let output = renderer.render(document: document)
                    renderedBytes += output.bodyHTML?.utf8.count ?? 0
                }
            }
        }
        XCTAssertGreaterThan(renderedBytes, 20 * documents.reduce(0) { $0 + $1.source.utf8.count })
        print("Corpus render median: \(median) s")
        XCTAssertLessThan(median, 0.75, "Gross render regression on the compatibility corpus")
    }

    private func corpusFixtures() throws -> [(URL, String)] {
        try ["github-readme", "obsidian-note", "commonmark-edges", "kitchen-sink"].map {
            let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/WaferCore/\($0).md")
            return (url, try String(contentsOf: url, encoding: .utf8))
        }
    }

    private func medianDuration(_ work: () -> Void) -> TimeInterval {
        work()
        let samples = (0..<3).map { _ in
            let start = ProcessInfo.processInfo.systemUptime
            work()
            return ProcessInfo.processInfo.systemUptime - start
        }
        return samples.sorted()[1]
    }

    func testParseAndRenderMediumDocumentPerformance() {
        let parser = MarkdownParser()
        let renderer = WebKitHTMLRenderer()
        let block = """
        ## Section

        Paragraph with **bold**, *italic*, `code`, [link](https://example.com), and a table:

        | Name | Value |
        | ---- | ----- |
        | One  | 1     |
        | Two  | 2     |

        - [x] done
        - [ ] todo

        > Block quote content for layout testing.

        ```swift
        let sample = true
        let veryLongLine = "This line should wrap inside the readable content column without requiring horizontal scrolling in the viewer."
        ```

        | Feature | Notes |
        | ------- | ----- |
        | Quotes  | WebKit block styling |
        | Tables  | Responsive HTML table styling |
        | Lists   | Consistent nested markers |

        ```bash
        ./scripts/build-app.sh release
        open build/Wafer.app
        ```

        """
        let source = String(repeating: block, count: 250)

        measure {
            let document = parser.parse(source: source, baseURL: nil)
            _ = renderer.render(document: document)
        }
    }
}
