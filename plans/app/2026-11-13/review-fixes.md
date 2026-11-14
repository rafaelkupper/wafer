# Fix the 2026-11-13 architecture review findings

## Goal

Resolve every finding from the three independent reviews (Astra 7, Fable 7.5, Muse 7.5) of commit `367301c`: security, data safety, correctness, resource limits, structure, tests, and release tooling, without changing the product's feature set.

## Context

Review threads: Astra, Fable, and Muse (xhigh) delegated reviews, 2026-11-13. The finding IDs below are the work items. Line references are against `367301c`.

## Constraints

- No git commands that touch remotes; no push, publish, or notarization. The CI workflow is added but not pushed.
- No destructive commands. Preserve user data on every save failure path.
- Proportionate fixes: smallest change that removes the defect; no new product features.
- Update ARCHITECTURE.md, README, and docs where behavior, architecture, or release steps change.
- Delegation through T3 `delegate_task`, model seats from `~/.config/pstack/config.json`.
- Parallel streams own disjoint files (listed per stream); each works in its own worktree and commits on its branch; the parent integrates.

## Workstreams and findings

### A. Release and tooling (owns `scripts/**`, `docs/DEVELOPMENT.md`, `.github/**`, `Tests/ReleaseTools/**`, `Tests/WaferAppTests/PackagingScriptTests.swift`, `.gitignore`)
- A1 `package-release.sh:135` deletes everything in `WAFER_DIST_DIR`.
- A2 `build-app.sh:58` succeeds when resource bundles are missing.
- A3 `build-app.sh:71` registers build output with LaunchServices and pluginkit on every build.
- A4 `release.py:163` receipt lacks source SHA, repository, feed URL, signing identity; publish does not validate them, does not target a commit, does not compare the receipt key with the manifest key.
- A5 `release.py:142` creates the GitHub release before pushing the feed; a failed push leaves an unresumable half-published state.
- A6 `DEVELOPMENT.md:41` bundle paths outdated (`Contents/Resources`).
- A7 No CI.
- A8 `PackagingScriptTests` assert source text instead of behavior.
- A9 The Quick Look appex carries Mermaid and KaTeX it never runs.

### B. WaferCore and Quick Look (owns `Sources/WaferCore/**`, `Sources/WaferQuickLook/**`, `Tests/WaferCoreTests/**`, `Tests/Fixtures/**`, new Quick Look test target, `Package.swift` except WaferApp resources)
- B1 Markdown links bypass the URL scheme allowlist (`WebKitHTMLRenderer:1701,1744,1812`, `AssetResolver:82`), including export.
- B2 Non-ASCII heading fragments are double-encoded (`WebKitHTMLRenderer:1736`, `StringRenderingHelpers:43`).
- B3 Sanitizer does not balance tags; stray closers close `#write`.
- B4 Tokenizer duplicated between `HTMLSanitizer` and `ExportSanitizer`.
- B5 `ExportSanitizer` copies unknown tags and attributes through.
- B6 One unreadable file or folder fails the whole library scan.
- B7 Library scan reads are unbounded.
- B8 Blind UTF-16LE fallback decodes non-UTF-8 files as mojibake.
- B9 `MarkdownTextFormat.encode` writes `\r\r\n` for CRLF input.
- B10 Identifier slugs and wiki keys depend on the user's locale.
- B11 Scroll state keys include the content fingerprint; entries grow unbounded.
- B12 `DocumentSummaryCache` does I/O and parsing under its lock.
- B13 About 700 lines of JavaScript in Swift strings in `WebKitHTMLRenderer`.
- B14 Golden tests compare hashes; fixtures located through `#filePath`.
- B15 No Quick Look test target.
- B16 Quick Look duplicates hex-to-`NSColor`.
- B17 Quick Look sandbox likely cannot read sibling images (unverified).
- B18 KaTeX ships `.ttf` and `.woff` fonts beside `.woff2`.
- B19 Reader HTML hardcodes `lang="en"`.
- B20 Unused `ScrollStateStore.remove`.

### C1. Document and editing (owns `MarkdownReaderDocument.swift`, `MarkdownEditSession.swift`, `MarkdownSourceEditorViewController.swift`, `MarkdownDocumentOpener.swift`, new files extracted from them, and their tests)
- C1.1 Navigation can discard edits typed during its background read.
- C1.2 Save failures fall back to non-atomic overwrites.
- C1.3 Autosave does full-file I/O and hashing on the main actor.
- C1.4 Check-then-write window between fingerprint check and replace.
- C1.5 Document lifecycle spread across parallel flags in a 1,272-line class.
- C1.6 Link opening has no scheme check; local executables open without confirmation.
- C1.7 Clicked fragments are not percent-decoded.
- C1.8 Document loads are unbounded.
- C1.9 `LibraryController.shared` read directly instead of injected.
- C1.10 `annotatesSourceLines` is an unchecked shared mutable flag.
- C1.11 Editor does not normalize pasted line endings.
- C1.12 Wall-clock assertions in the default test suite; one intermittent failure.

### C2. Reader, window, and sidebar (owns `WebKitReaderViewController.swift`, `ReaderLivePreviewScript.swift`, `DocumentWindowController.swift`, `DocumentSidebarViewController.swift`, `DocumentStatisticsAccessoryViewController.swift`, `DirectoryChangeMonitor.swift`, `FileChangeMonitor.swift`, `RemoteImageSchemeHandler.swift`, new files extracted from them, their tests, WaferApp resources in `Package.swift`)
- C2.1 Local asset loads are unbounded and not cancelled.
- C2.2 JavaScript in Swift strings in the reader.
- C2.3 Arbitrary-JavaScript test hook ships in release builds.
- C2.4 Oversized reader, window, and sidebar controllers.
- C2.5 FSEvents context holds an unretained `self`.
- C2.6 Titlebar styling walks the view tree on every layout and matches private class names unguarded.
- C2.7 Statistics accessory Auto Layout conflict.
- C2.8 Remote image user agent says `Wafer/0.5`.
- C2.9 Real-kqueue monitor tests are timing-sensitive.

### P2. Cross-cutting, after integration
- P2.1 Global mutable `ReaderTheme.current` lives in the core.
- P2.2 161 to 223 `ForTesting` members ship in production types.
- P2.3 No structured logging; silent `try?` failure sites.
- P2.4 Show library skipped-item count (from B6).
- P2.5 App-side scroll state migration and pruning (from B11).
- P2.6 End-to-end tests for non-ASCII fragments and link schemes.
- P2.7 ARCHITECTURE.md matches the new structure.

## Done when

- [x] Each finding is fixed, or its proportionate resolution is recorded under Decisions.
- [x] `swift test` passes five consecutive runs.
- [x] `python3 -m unittest discover -s Tests/ReleaseTools -v` passes.
- [x] `scripts/build-app.sh release` and `scripts/verify-appex.sh build/Wafer.app` pass.
- [ ] The three original reviewers (Codex Company gpt-6-astra xhigh, Claude One claude-fable-5-2 xhigh, Muse muse-wonder-full-1.0 xhigh) re-run the same scored assessment on the integrated result (requested 2026-11-13).

## Decisions

- Integration happens on local branch `review-fixes-integration`; `main` is untouched until the user approves.
- B8: bytes that are neither UTF-8 nor BOM/zero-pattern UTF-16 are a decoding error; no legacy-encoding guessing.
- B19: removed the hardcoded `lang`; no localization system (a feature, not a defect).
- B17: Finder previews deterministically omit sibling images (sandbox gives no folder scope); documented.
- P2.1: global `ReaderTheme.current` and derived native colors moved to `WaferApp/ReaderTheme+Current.swift` with unchanged names. WaferCore keeps stateless AppKit color conversion, editor colors, and Quick Look attributed-text import because app and extension share them.
- A8 follow-up: Quick Look linkage (QuickLookUI, no WebKit) and view-based plist are checked by `verify-appex.sh` against the built artifact; attributed-text import and fallback moved to `PreviewAttributedText` in WaferCore with unit tests.
- C2 follow-up: `scripts/benchmarks/scroll.cjs` removed; `Tests/JavaScript/app/reader-scroll.cjs` is the same check against the bundled script. CI runs all Node tests.
- P2.4: sidebar shows "N files skipped (unreadable or too large)".

## Verification

Integration branch `review-fixes-integration`, 2026-11-13:

- `swift test`: passed five consecutive runs; each 635 tests (249 core, 379 app with 1 opt-in perf test skipped, 7 Quick Look), 0 failures, no "Unable to simultaneously satisfy" warnings. Correction 2026-11-13: the sidebar-toggle test logs a "Conflicting constraints detected" warning when run in isolation at this commit; the log check did not search for that wording.
- `python3 -m unittest discover -s Tests/ReleaseTools`: passed, 20 tests.
- Node tests (`Tests/JavaScript/*/*.cjs`): all 3 passed.
- `scripts/build-app.sh release` and `scripts/verify-appex.sh build/Wafer.app`: passed.
- `swift build -c release`: no `ForTesting` symbols in the release binary (`nm`).
- Mutation checks: link-scheme end-to-end test fails when `shortcuts` is allowed; C1 reported its navigation, CRLF, stale-reload, and save-fallback tests fail without their fixes.
- C1.3: keystroke autosave main-thread time on a 5 MB document, median about 20 ms before, about 4 ms after (release).
- Not run: hosted CI, notarization, publication, installed Finder Quick Look smoke test.
