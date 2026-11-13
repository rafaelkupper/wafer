import XCTest
@testable import WaferCore

final class CodeSyntaxHighlighterTests: XCTestCase {
    private let highlighter = CodeSyntaxHighlighter()

    func testSwiftPresentationRunsExposeSemanticTokenKinds() {
        let runs = highlighter.presentationRuns(
            code: """
            struct Theme {
                let title = "Wafer"
                func render() {}
                // comment
            }
            """,
            language: "swift"
        )

        let kinds = Set(runs.compactMap(\.kind))
        XCTAssertTrue(kinds.contains(.keyword))
        XCTAssertTrue(kinds.contains(.type))
        XCTAssertTrue(kinds.contains(.string))
        XCTAssertTrue(kinds.contains(.function))
        XCTAssertTrue(kinds.contains(.comment))
    }

    func testHighlightedHTMLUsesExpandedThemeSyntaxClasses() {
        let code = """
        @memoize
        const renderCard = (props) => props.title
        """

        let html = highlighter.highlightedHTML(code: code, language: "typescript")
        XCTAssertTrue(html.contains("<span class=\"cm-atom\">"))
        XCTAssertTrue(html.contains("<span class=\"cm-keyword\">"))
        XCTAssertTrue(html.contains("<span class=\"cm-variable-2\">"))
        XCTAssertTrue(html.contains("<span class=\"cm-property\">"))
    }

    func testUntaggedCodeProducesSinglePlainRun() {
        let runs = highlighter.presentationRuns(code: "plain code", language: nil)

        XCTAssertEqual(runs.count, 1)
        XCTAssertNil(runs.first?.kind)
    }

    func testShellAliasesNormalizeToBashRules() {
        let shellKinds = Set(
            highlighter.presentationRuns(
                code: "export PATH=\"$HOME/bin\"\n# note",
                language: "shell"
            ).compactMap(\.kind)
        )
        let bashKinds = Set(
            highlighter.presentationRuns(
                code: "export PATH=\"$HOME/bin\"\n# note",
                language: "bash"
            ).compactMap(\.kind)
        )

        XCTAssertEqual(shellKinds, bashKinds)
        XCTAssertTrue(shellKinds.contains(.keyword))
        XCTAssertTrue(shellKinds.contains(.string))
        XCTAssertTrue(shellKinds.contains(.comment))
    }

    func testJSONRulesHighlightKeysStringsNumbersAndKeywords() {
        let kinds = Set(
            highlighter.presentationRuns(
                code: """
                {"title":"Wafer","count":2,"enabled":true,"empty":null}
                """,
                language: "json"
            ).compactMap(\.kind)
        )

        XCTAssertTrue(kinds.contains(.type))
        XCTAssertTrue(kinds.contains(.string))
        XCTAssertTrue(kinds.contains(.number))
        XCTAssertTrue(kinds.contains(.keyword))
    }

    func testYAMLRulesHighlightKeysStringsNumbersKeywordsAndComments() {
        let kinds = Set(
            highlighter.presentationRuns(
                code: """
                title: "Wafer"
                retries: 3
                enabled: true
                # comment
                """,
                language: "yml"
            ).compactMap(\.kind)
        )

        XCTAssertTrue(kinds.contains(.type))
        XCTAssertTrue(kinds.contains(.string))
        XCTAssertTrue(kinds.contains(.number))
        XCTAssertTrue(kinds.contains(.keyword))
        XCTAssertTrue(kinds.contains(.comment))
    }

    func testMarkdownRulesHighlightHeadersCodeAndComments() {
        let kinds = Set(
            highlighter.presentationRuns(
                code: """
                # Heading
                `inline`
                <!-- note -->
                """,
                language: "markdown"
            ).compactMap(\.kind)
        )

        XCTAssertTrue(kinds.contains(.type))
        XCTAssertTrue(kinds.contains(.string))
        XCTAssertTrue(kinds.contains(.comment))
    }

    func testAdditionalLanguagesExposeExpectedSemanticTokenKinds() {
        struct Sample {
            let language: String
            let code: String
            let expectedKinds: Set<CodeSyntaxHighlighter.TokenKind>
        }

        let samples: [Sample] = [
            Sample(
                language: "go",
                code: """
                package main
                type Reader struct { title string }
                func renderCard(value Reader) string {
                    return `ok`
                }
                // comment
                """,
                expectedKinds: [.keyword, .type, .function, .string, .comment]
            ),
            Sample(
                language: "ruby",
                code: """
                class Reader
                  def render_card
                    @title = "Wafer" # comment
                  end
                end
                """,
                expectedKinds: [.keyword, .type, .function, .member, .string, .comment]
            ),
            Sample(
                language: "python",
                code: """
                class Reader:
                    @cached_property
                    def render(self):
                        return self.title
                """,
                expectedKinds: [.keyword, .type, .function, .member, .meta]
            ),
            Sample(
                language: "elixir",
                code: """
                defmodule Reader do
                  def render_card(user) do
                    user.title
                    :ok
                  end
                end
                """,
                expectedKinds: [.keyword, .type, .function, .member, .meta]
            ),
            Sample(
                language: "javascript",
                code: """
                class Reader {}
                const renderCard = (props) => props.title
                """,
                expectedKinds: [.keyword, .type, .function, .member]
            ),
            Sample(
                language: "typescript",
                code: """
                interface Props { title: string }
                const renderCard = (props: Props) => props.title
                """,
                expectedKinds: [.keyword, .type, .function, .member]
            ),
            Sample(
                language: "php",
                code: """
                class Reader {
                    public function renderCard() {
                        return $this->title;
                    }
                }
                """,
                expectedKinds: [.keyword, .type, .function, .member]
            ),
            Sample(
                language: "c",
                code: """
                #include <stdio.h>
                int render_card(struct reader *value) {
                    return value->title[0];
                }
                """,
                expectedKinds: [.meta, .type, .function, .member]
            ),
            Sample(
                language: "cpp",
                code: """
                #include <string>
                class Reader {};
                std::string render_card(Reader* value) {
                    return value->title;
                }
                """,
                expectedKinds: [.meta, .keyword, .type, .function, .member]
            ),
            Sample(
                language: "rust",
                code: """
                #[derive(Debug)]
                struct Reader { title: String }
                fn render_card(reader: Reader) -> String {
                    reader.title
                }
                """,
                expectedKinds: [.meta, .keyword, .type, .function, .member]
            ),
            Sample(
                language: "zig",
                code: """
                const Reader = struct { title: []const u8 };
                fn renderCard(reader: Reader) []const u8 {
                    return reader.title;
                }
                const standard = @import("std");
                """,
                expectedKinds: [.keyword, .type, .function, .member, .meta, .string]
            ),
            Sample(
                language: "haskell",
                code: """
                {-# LANGUAGE OverloadedStrings #-}
                data Reader = Reader
                renderCard reader = reader
                """,
                expectedKinds: [.meta, .keyword, .type, .function]
            ),
            Sample(
                language: "java",
                code: """
                @Override
                class Reader {
                    String renderCard(Reader value) {
                        return value.title;
                    }
                }
                """,
                expectedKinds: [.meta, .keyword, .type, .function, .member]
            ),
            Sample(
                language: "html",
                code: """
                <!DOCTYPE html>
                <div class="card" data-title="Wafer">Title</div>
                <!-- comment -->
                """,
                expectedKinds: [.meta, .type, .member, .string, .comment]
            ),
            Sample(
                language: "css",
                code: """
                @media screen {
                  .card {
                    color: #fff;
                    transform: translateX(12px);
                  }
                }
                """,
                expectedKinds: [.meta, .type, .member, .function, .number]
            ),
            Sample(
                language: "toml",
                code: """
                [app]
                title = "Wafer"
                enabled = true
                """,
                expectedKinds: [.meta, .type, .string, .keyword]
            ),
            Sample(
                language: "diff",
                code: """
                diff --git a/file b/file
                @@ -1,2 +1,2 @@
                -old line
                +new line
                """,
                expectedKinds: [.meta, .addition, .deletion]
            ),
            Sample(
                language: "dockerfile",
                code: """
                FROM swift:6.1 AS build
                ARG APP_ENV=prod
                RUN echo "$APP_ENV"
                # comment
                """,
                expectedKinds: [.keyword, .string, .member, .comment]
            ),
        ]

        for sample in samples {
            let kinds = Set(highlighter.presentationRuns(code: sample.code, language: sample.language).compactMap(\.kind))
            XCTAssertTrue(sample.expectedKinds.isSubset(of: kinds), "Missing expected kinds for \(sample.language): \(sample.expectedKinds.subtracting(kinds))")
        }
    }

    func testV1CompatibilityLanguagesHighlightExpectedSubstrings() {
        struct TokenExpectation {
            let token: String
            let kind: CodeSyntaxHighlighter.TokenKind
        }
        struct Sample {
            let language: String
            let code: String
            let expectations: [TokenExpectation]
        }

        let samples: [Sample] = [
            Sample(
                language: "sql",
                code: """
                -- latest posts
                SELECT "title", COUNT(*) FROM posts WHERE status = 'published' AND views >= 10;
                """,
                expectations: [
                    TokenExpectation(token: "SELECT", kind: .keyword),
                    TokenExpectation(token: #""title""#, kind: .type),
                    TokenExpectation(token: "COUNT", kind: .function),
                    TokenExpectation(token: #"'published'"#, kind: .string),
                    TokenExpectation(token: "10", kind: .number),
                    TokenExpectation(token: "-- latest posts", kind: .comment),
                ]
            ),
            Sample(
                language: "kotlin",
                code: """
                data class Reader(val title: String)
                fun render(reader: Reader): String {
                    val count = 2
                    return reader.renderedTitle + "ok" // comment
                }
                """,
                expectations: [
                    TokenExpectation(token: "data", kind: .keyword),
                    TokenExpectation(token: "Reader", kind: .type),
                    TokenExpectation(token: "render", kind: .function),
                    TokenExpectation(token: "renderedTitle", kind: .member),
                    TokenExpectation(token: #""ok""#, kind: .string),
                    TokenExpectation(token: "2", kind: .number),
                    TokenExpectation(token: "// comment", kind: .comment),
                ]
            ),
            Sample(
                language: "csharp",
                code: """
                [Serializable]
                public class Reader {
                    public string Render(Reader value) {
                        var count = 2;
                        return value.Title + "ok"; // comment
                    }
                }
                """,
                expectations: [
                    TokenExpectation(token: "[Serializable]", kind: .meta),
                    TokenExpectation(token: "public", kind: .keyword),
                    TokenExpectation(token: "Reader", kind: .type),
                    TokenExpectation(token: "Render", kind: .function),
                    TokenExpectation(token: "Title", kind: .member),
                    TokenExpectation(token: #""ok""#, kind: .string),
                    TokenExpectation(token: "2", kind: .number),
                    TokenExpectation(token: "// comment", kind: .comment),
                ]
            ),
            Sample(
                language: "objective-c",
                code: """
                #import <Foundation/Foundation.h>
                @interface Reader : NSObject
                @property(nonatomic) NSString *title;
                - (NSString *)render:(NSInteger)count {
                    NSInteger total = 2;
                    return self.renderedTitle ?: @"ok"; // comment
                }
                @end
                """,
                expectations: [
                    TokenExpectation(token: "#import <Foundation/Foundation.h>", kind: .meta),
                    TokenExpectation(token: "@interface", kind: .keyword),
                    TokenExpectation(token: "Reader", kind: .type),
                    TokenExpectation(token: "render", kind: .function),
                    TokenExpectation(token: "renderedTitle", kind: .member),
                    TokenExpectation(token: #"@"ok""#, kind: .string),
                    TokenExpectation(token: "2", kind: .number),
                    TokenExpectation(token: "// comment", kind: .comment),
                ]
            ),
            Sample(
                language: "lua",
                code: """
                -- comment
                local count = 2
                function render(value)
                  return value.title .. "ok"
                end
                """,
                expectations: [
                    TokenExpectation(token: "local", kind: .keyword),
                    TokenExpectation(token: "render", kind: .function),
                    TokenExpectation(token: "title", kind: .member),
                    TokenExpectation(token: #""ok""#, kind: .string),
                    TokenExpectation(token: "2", kind: .number),
                    TokenExpectation(token: "-- comment", kind: .comment),
                ]
            ),
            Sample(
                language: "makefile",
                code: "include config.mk\nVERSION = 2\nbuild: main.o\n\t@echo $(VERSION)\n# comment\n",
                expectations: [
                    TokenExpectation(token: "include", kind: .keyword),
                    TokenExpectation(token: "VERSION", kind: .type),
                    TokenExpectation(token: "build", kind: .function),
                    TokenExpectation(token: "@echo", kind: .string),
                    TokenExpectation(token: "$(VERSION)", kind: .member),
                    TokenExpectation(token: "2", kind: .number),
                    TokenExpectation(token: "# comment", kind: .comment),
                ]
            ),
            Sample(
                language: "ini",
                code: """
                ; comment
                [server]
                port = 8080
                enabled = true
                name = "wafer"
                """,
                expectations: [
                    TokenExpectation(token: "; comment", kind: .comment),
                    TokenExpectation(token: "[server]", kind: .meta),
                    TokenExpectation(token: "port", kind: .type),
                    TokenExpectation(token: "8080", kind: .number),
                    TokenExpectation(token: "true", kind: .keyword),
                    TokenExpectation(token: #""wafer""#, kind: .string),
                ]
            ),
            Sample(
                language: "graphql",
                code: """
                # comment
                query GetPost($id: ID!) {
                  post(id: $id) @include(if: true) {
                    title(format: "short", limit: 2)
                  }
                }
                """,
                expectations: [
                    TokenExpectation(token: "# comment", kind: .comment),
                    TokenExpectation(token: "query", kind: .keyword),
                    TokenExpectation(token: "ID", kind: .type),
                    TokenExpectation(token: "post", kind: .function),
                    TokenExpectation(token: "@include", kind: .meta),
                    TokenExpectation(token: #""short""#, kind: .string),
                    TokenExpectation(token: "2", kind: .number),
                ]
            ),
            Sample(
                language: "hcl",
                code: """
                # comment
                resource "aws_instance" "web" {
                  count = 2
                  name = format("web-%d", count)
                  enabled = true
                }
                """,
                expectations: [
                    TokenExpectation(token: "# comment", kind: .comment),
                    TokenExpectation(token: "resource", kind: .keyword),
                    TokenExpectation(token: "count", kind: .type),
                    TokenExpectation(token: "format", kind: .function),
                    TokenExpectation(token: #""aws_instance""#, kind: .string),
                    TokenExpectation(token: "2", kind: .number),
                    TokenExpectation(token: "true", kind: .keyword),
                ]
            ),
            Sample(
                language: "protobuf",
                code: """
                syntax = "proto3";
                message Reader {
                  string title = 1;
                  repeated int32 counts = 2; // comment
                }
                """,
                expectations: [
                    TokenExpectation(token: "syntax", kind: .keyword),
                    TokenExpectation(token: #""proto3""#, kind: .string),
                    TokenExpectation(token: "Reader", kind: .type),
                    TokenExpectation(token: "string", kind: .type),
                    TokenExpectation(token: "title", kind: .member),
                    TokenExpectation(token: "1", kind: .number),
                    TokenExpectation(token: "// comment", kind: .comment),
                ]
            ),
        ]

        for sample in samples {
            XCTAssertGreaterThanOrEqual(Set(sample.expectations.map(\.kind)).count, 3, "\(sample.language) should assert at least three token kinds")
            for expectation in sample.expectations {
                assertToken(expectation.token, kind: expectation.kind, in: sample.code, language: sample.language)
            }
        }
    }

    func testMakefileRecipeRuleRequiresTabIndentation() {
        let code = "    echo not a recipe\n"

        assertTokenIsPlain("echo", in: code, language: "makefile")
    }

    func testBroadLanguageAliasesNormalizeToCanonicalRuleSets() {
        assertAlias("golang", canonical: "go", code: "func renderCard() string { return `ok` }")
        assertAlias("rb", canonical: "ruby", code: "def render_card\n  @title = \"Wafer\"\nend")
        assertAlias("py", canonical: "python", code: "@cached_property\ndef render(self):\n    return self.title")
        assertAlias("jsx", canonical: "javascript", code: "const renderCard = (props) => props.title")
        assertAlias("tsx", canonical: "typescript", code: "interface Props { title: string }\nconst renderCard = (props: Props) => props.title")
        assertAlias("rs", canonical: "rust", code: "#[derive(Debug)]\nfn render_card() {}")
        assertAlias("c++", canonical: "cpp", code: "#include <string>\nstd::string render_card();")
        assertAlias("hpp", canonical: "cpp", code: "#include <string>\nstd::string render_card();")
        assertAlias("hs", canonical: "haskell", code: "{-# LANGUAGE OverloadedStrings #-}\nrenderCard value = value")
        assertAlias("exs", canonical: "elixir", code: "defmodule Reader do\n  def render_card, do: :ok\nend")
        assertAlias("xml", canonical: "html", code: "<?xml version=\"1.0\"?><note id=\"one\" />")
        assertAlias("svg", canonical: "html", code: "<svg viewBox=\"0 0 10 10\"><rect width=\"10\" /></svg>")
        assertAlias("scss", canonical: "css", code: "@media screen { .card { color: #fff; } }")
        assertAlias("patch", canonical: "diff", code: "@@ -1 +1 @@\n-old\n+new")
        assertAlias("docker", canonical: "dockerfile", code: "FROM swift:6.1\nRUN echo hi")
        assertAlias("sql", canonical: "sql", code: "select count(*) from posts where title = 'ok'")
        assertAlias("postgres", canonical: "sql", code: "select count(*) from posts where title = 'ok'")
        assertAlias("postgresql", canonical: "sql", code: "select count(*) from posts where title = 'ok'")
        assertAlias("mysql", canonical: "sql", code: "select count(*) from posts where title = 'ok'")
        assertAlias("sqlite", canonical: "sql", code: "select count(*) from posts where title = 'ok'")
        assertAlias("kt", canonical: "kotlin", code: "fun render(): String = \"ok\"")
        assertAlias("kts", canonical: "kotlin", code: "fun render(): String = \"ok\"")
        assertAlias("cs", canonical: "csharp", code: "public string Render() { return \"ok\"; }")
        assertAlias("csharp", canonical: "csharp", code: "public string Render() { return \"ok\"; }")
        assertAlias("objc", canonical: "objective-c", code: "@interface Reader : NSObject\n@end")
        assertAlias("objective-c", canonical: "objective-c", code: "@interface Reader : NSObject\n@end")
        assertAlias("objectivec", canonical: "objective-c", code: "@interface Reader : NSObject\n@end")
        assertAlias("make", canonical: "makefile", code: "build:\n\t@echo $(VERSION)")
        assertAlias("mk", canonical: "makefile", code: "build:\n\t@echo $(VERSION)")
        assertAlias("ini", canonical: "ini", code: "[server]\nport = 8080")
        assertAlias("conf", canonical: "ini", code: "[server]\nport = 8080")
        assertAlias("properties", canonical: "ini", code: "port = 8080")
        assertAlias("gql", canonical: "graphql", code: "query GetPost { post(id: 1) { title } }")
        assertAlias("terraform", canonical: "hcl", code: "resource \"x\" \"y\" { count = 1 }")
        assertAlias("tf", canonical: "hcl", code: "resource \"x\" \"y\" { count = 1 }")
        assertAlias("proto", canonical: "protobuf", code: "message Reader { string title = 1; }")
    }

    func testDiffHighlightedHTMLUsesAdditionAndDeletionClasses() {
        let html = highlighter.highlightedHTML(
            code: """
            @@ -1 +1 @@
            -old line
            +new line
            """,
            language: "diff"
        )

        XCTAssertTrue(html.contains("<span class=\"cm-atom\">@@ -1 +1 @@</span>"))
        XCTAssertTrue(html.contains("<span class=\"cm-negative\">-old line</span>"))
        XCTAssertTrue(html.contains("<span class=\"cm-positive\">+new line</span>"))
    }

    func testPresentationRunsCanBeComputedConcurrently() {
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            let runs = CodeSyntaxHighlighter().presentationRuns(
                code: """
                struct Reader {
                    let title = "Wafer"
                    func render() {}
                }
                """,
                language: "swift"
            )

            XCTAssertTrue(Set(runs.compactMap(\.kind)).isSuperset(of: [.keyword, .type, .string, .function]))
        }
    }

    func testExistingSwiftAndJSONHighlightOutputRemainsStable() {
        let swiftHTML = highlighter.highlightedHTML(
            code: """
            struct Reader {
                let title = "Wafer"
                func render() {}
            }
            """,
            language: "swift"
        )
        let jsonHTML = highlighter.highlightedHTML(
            code: #"{"title":"Wafer","count":2,"enabled":true}"#,
            language: "json"
        )

        XCTAssertEqual(FileFingerprint.sha256Hex(for: swiftHTML), "94317b8f37a73fd60a2bf9c6e89390da2a2e0f781a27fc577a666db36eef89a5")
        XCTAssertEqual(FileFingerprint.sha256Hex(for: jsonHTML), "3598545ac9295b614a0db148f8d647691e33963cbfb5326385790a539a76a22a")
    }

    func testUnknownLanguageFallsBackToPlainRuns() {
        let runs = highlighter.presentationRuns(code: "SELECT * FROM table", language: "madeuplang")

        XCTAssertEqual(runs.count, 1)
        XCTAssertNil(runs.first?.kind)
    }

    private func assertAlias(_ alias: String, canonical: String, code: String) {
        let aliasKinds = Set(highlighter.presentationRuns(code: code, language: alias).compactMap(\.kind))
        let canonicalKinds = Set(highlighter.presentationRuns(code: code, language: canonical).compactMap(\.kind))
        XCTAssertEqual(aliasKinds, canonicalKinds, "Alias \(alias) should normalize to \(canonical)")
    }

    private func assertToken(
        _ token: String,
        kind expectedKind: CodeSyntaxHighlighter.TokenKind,
        in code: String,
        language: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let range = (code as NSString).range(of: token)
        XCTAssertNotEqual(range.location, NSNotFound, "Missing token \(token) in \(language)", file: file, line: line)
        guard range.location != NSNotFound else {
            return
        }

        for offset in range.location..<NSMaxRange(range) {
            XCTAssertEqual(
                kind(atUTF16Offset: offset, in: code, language: language),
                expectedKind,
                "Unexpected kind for token \(token) in \(language)",
                file: file,
                line: line
            )
        }
    }

    private func assertTokenIsPlain(
        _ token: String,
        in code: String,
        language: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let range = (code as NSString).range(of: token)
        XCTAssertNotEqual(range.location, NSNotFound, "Missing token \(token) in \(language)", file: file, line: line)
        guard range.location != NSNotFound else {
            return
        }

        for offset in range.location..<NSMaxRange(range) {
            XCTAssertNil(
                kind(atUTF16Offset: offset, in: code, language: language),
                "Expected plain token \(token) in \(language)",
                file: file,
                line: line
            )
        }
    }

    private func kind(
        atUTF16Offset offset: Int,
        in code: String,
        language: String
    ) -> CodeSyntaxHighlighter.TokenKind? {
        highlighter.presentationRuns(code: code, language: language)
            .first { NSLocationInRange(offset, $0.range) }?
            .kind
    }
}
