import Foundation
import WaferCore

// Run from a directory with no Wafer resource bundle, using a release build.
precondition(ReaderTheme.resourceURL(named: "reader-theme.css") == nil)
precondition(ReaderTheme.styleSheet(for: .dark).contains("#write"))
let document = MarkdownParser().parse(source: ":smile:\n\n```mermaid\ngraph TD; A-->B\n```\n\n```math\nx^2\n```", baseURL: nil)
let output = WebKitHTMLRenderer().render(document: document)
precondition(!output.waitsForContentReady && !output.hasMathDisplays && !output.hasMermaidDiagrams)
precondition(output.html.contains(":smile:") && output.html.contains("x^2") && output.html.contains("A--&gt;B"))
precondition(!output.html.contains("<script"))
print("PASS: missing resources preserve reader CSS, literal emoji, and code fences without waiting for scripts")
