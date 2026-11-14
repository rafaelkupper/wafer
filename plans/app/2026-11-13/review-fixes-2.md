# Fix the 2026-11-13 re-review findings

## Goal

Resolve the findings from the second round of reviews (Astra 8, Fable 8, Muse 8) of `review-fixes-integration` at `170c299`, then run a third scored review by the same three reviewers before the user decides on merging into `main`.

## Context

- First round and its fixes: `plans/app/2026-11-13/review-fixes.md`.
- User decisions, 2026-11-13:
  - Apply the follow-up fixes.
  - Remote images stay a user option in the top menu. It already exists: File > Load Remote Images, on by default. Keep it, and harden the loader.
  - Finish the follow-ups, re-run the three reviews, then decide whether to merge.
- Main-app sandboxing is a build-time entitlement, so it cannot be a runtime menu option. It stays out of this round, and the user will be told.

## Constraints

- No git commands that touch remotes. No push, publish or notarization. `main` stays untouched.
- No destructive commands. Preserve user data on every save path.
- Proportionate fixes: the smallest change that removes the defect. No new product features beyond the user's decisions.
- Update ARCHITECTURE.md, README and the docs when behavior, architecture or release steps change.
- Delegate through T3 `delegate_task`, using seats from `~/.config/pstack/config.json`.
- Parallel streams own disjoint files. Each works in its own worktree and commits on its own branch, and the parent integrates.
- Shared rule for bundled resources: a missing resource is a packaging defect. Log a fault through `WaferLog.resources` and degrade in a defined way. No `preconditionFailure`, no `fatalError` and no silent omission. Packaging verification checks that resources are present.

## Workstreams and findings

### R. Release and tooling
Owns `scripts/**`, `.github/**`, `Tests/ReleaseTools/**`, `Tests/WaferAppTests/PackagingScriptTests.swift`, `Package.swift`, `docs/DEVELOPMENT.md` and the vendored-asset manifest.

- R1 `build-app.sh:80` copies every `Wafer_*.bundle`, so stale test-fixture bundles get shipped. Copy an explicit list, and make verification reject extra bundles.
- R2 The shipped binary is unstripped, embeds build paths, and has no dSYM.
- R3 `release.py:170` creates and uploads the release before checking an existing tag's commit.
- R4 `release.py:197` records HEAD in the receipt, but the build uses the working tree. A dirty tree must refuse to package.
- R5 `release.py:57` does not handle `URLError`.
- R6 The notarization password is passed on the command line.
- R7 `package-release.sh` runs only `swift test`. Add a single local check script that matches CI, and make packaging use it.
- R8 There is no lint step in CI.
- R9 Vendored Mermaid and KaTeX have no recorded source, version or checksums.
- R10 `Package.swift` declares tools 6.0, but 6.2 is required. The library product's use of `unsafeFlags` is questioned.
- R11 Performance tests are not in CI.

### K. WaferCore
Owns `Sources/WaferCore/**`, `Tests/WaferCoreTests/**` and `Tests/Fixtures/**`.

- K1 `AssetResolver.swift:44` does not percent-decode link paths, so `My%20Note.md` is not found.
- K2 Raw HTML can close `#write` across Markdown containers, for example a `<div>` opened in a blockquote.
- K3 The export regex is compiled per attribute (`WebKitHTMLRenderer:1197`), and the KaTeX CSS is re-read on every render (`:189`).
- K4 The library index keeps three or more text copies per file, and ranking does an O(words) scan.
- K5 There are no sanitizer fuzz or property tests.
- K6 Core resources are loaded inconsistently (shared rule above).
- K7 `@unchecked Sendable` in core (`CodeSyntaxHighlighter`, `DocumentSummaryCache`, `WorkCancellation`).
- K8 `WebKitHTMLRenderer` (1,274 lines) is oversized.

### D. Document and editing
Owns `MarkdownReaderDocument.swift`, `MarkdownEditSession.swift`, `MarkdownEditCoordinator.swift`, `MarkdownRenderWorker.swift`, `LatestWorkQueue.swift`, `LinkTargetOpener.swift`, `MarkdownDocumentOpener.swift`, new files extracted from them, and their tests. May make one-line injection edits at `MarkdownReaderDocument(` construction sites in any test file.

- D1 `MarkdownEditSession.swift:513` reads the file unbounded during the save conflict check.
- D2 Tests write to the real `dev.wafer.scroll-state` preferences. `MarkdownReaderDocument:144` defaults to `ScrollStateStore()`.
- D3 Live preview can starve while typing in large documents, because each 100 ms tick cancels the in-flight render.
- D4 `LinkTargetOpener` "can run code" is a blocklist with gaps (`.playground`, `.xcodeproj`, `.html`, `.dmg`, `.shortcut`, `.wflow`, `.mobileconfig`, `.jnlp`, `.ipynb`). Invert it to an allowlist of passive types.
- D5 `MarkdownReaderDocument` (1,143 lines) is oversized. Extract source loading and reload.
- D6 `MarkdownRenderWorker.swift:63` uses an `@unchecked Sendable` callback box.

### L. Library, preferences and app shell
Owns `LibraryController.swift`, `*PreferenceStore.swift`, `UpdateController.swift`, `AppDelegate.swift`, `AppMenuBuilder.swift`, `ThemeLibrary.swift`, `ThemeFile.swift`, `QuickOpenPanelController.swift`, `LibraryInitialDocumentOpener.swift`, and their tests.

- L1 A library rescan can starve under continuous changes. It needs a maximum wait.
- L2 NotificationCenter `userInfo` is stringly typed.
- L3 The `UpdateController` quit-deferral path is untested.
- L4 `@unchecked Sendable` in the preference stores.
- L5 `ThemeLibrary` resource loading (shared rule).

### W. Reader, window and assets
Owns `WebKitReaderViewController.swift`, `DocumentWindowController.swift`, `DocumentHostWindowController.swift`, `FileChangeMonitor.swift`, `DirectoryChangeMonitor.swift`, `LocalAssetLoader.swift`, `WebKitLocalAssetSchemeHandler.swift`, `RemoteImageSchemeHandler.swift`, `RemoteExportAssetLoader.swift`, `ExportAssetInliner.swift`, `DocumentExportController.swift`, `ReaderScriptResource.swift`, `WindowChromeSuppression.swift`, new files extracted from them, their tests, and `EditModeTests.swift`.

- W1 `scrollToHeadingScript` (`WebKitReaderViewController.swift:584`) builds JavaScript by string interpolation.
- W2 The private `drawsBackground` key (`WebKitReaderViewController:99`) is set without a guard.
- W3 `FileChangeMonitor` polls every 0.5 s forever after deletion, and has an empty deinit.
- W4 `LocalAssetLoader` has a path-prefix TOCTOU and compares case-sensitively.
- W5 Remote images and export assets follow redirects and have no guard against private, loopback or link-local addresses. The menu toggle stays.
- W6 `DocumentWindowController` (1,356 lines) is oversized. Extract link and navigation routing.
- W7 UI tests skip on narrow displays (`EditModeTests:1326`).
- W8 `ReaderScriptResource` uses only `Bundle.module` and calls `preconditionFailure` (shared rule).
- W9 `@unchecked Sendable` in the scheme handlers.

### Recorded without code change
- 224 `ForTesting` seams remain, all DEBUG-gated. The test suite compiles only in debug, which is intended.
- Private AppKit chrome class names are already matched against an OS allowlist (C2.6).
- Main-app sandboxing is deferred to the user (see Context).

## Done when

- [x] Each finding is fixed, or its proportionate resolution is recorded under Decisions.
- [x] `swift test` passes five consecutive runs, and tests write nothing to the real scroll-state domain.
- [x] Python release tests, Node tests, `scripts/build-app.sh release` and `scripts/verify-appex.sh build/Wafer.app` pass.
- [x] The built app contains only the expected resource bundles.
- [ ] Astra, Fable and Muse (xhigh) re-run the scored assessment on the integrated result.

## Decisions

- Remote images: keep the existing File > Load Remote Images toggle (default on). The fix is loader hardening only (`RemoteAssetURLGuard`). Residual DNS-rebind race between resolve and connect is documented in ARCHITECTURE.md.
- Sandbox: deferred to the user; not a runtime option.
- R8: warnings are errors for production targets only. Three existing test-target warnings are listed in `docs/DEVELOPMENT.md`.
- R10: tools version 6.2. `unsafeFlags` stay on the two executable targets; SwiftPM allows them in the root package and WaferCore has none.
- R11: performance tests stay opt-in (`scripts/check.sh --perf`); hosted runners are too noisy for timing assertions.
- K1: no fallback to a literal percent-encoded filename; a literal `%` must be written `%25`.
- K4: post-scan footprint for 2,000 x 20 KB files went from 359.8 MiB to 137.1 MiB (median of 5); all-match query 814.9 ms to 651.3 ms.
- D5, K8, W6: `MarkdownReaderDocument` 1,143 to 1,052 lines (`MarkdownSourceLoader`); `WebKitHTMLRenderer` 1,274 to 1,087 (`WebKitRendererScripts`, `WebKitAssets`); `DocumentWindowController.swift` 1,368 to 636 (integrator moved `DocumentChromeViewController` to its own file, because W's routing target lived in a D-owned file).
- L2: the last two stringly reads of library-change payloads were migrated to `LibraryChange.value(from:)` at integration.
- Resource lookup: WaferCore exposes `BundledResources.resourceURL(named:bundleName:)`. `ReaderScriptResource` and `ThemeLibrary` keep small app-local lookups with injected-bundle tests; all three log faults and degrade instead of trapping.
- `escapedJavaScriptString` removed as dead code after W1.
- Scroll-state entries written by earlier test runs remain in the user's `dev.wafer.scroll-state` domain; they are not deleted because the domain also holds real reading positions. Entries expire after 180 days.

## Verification

Integration branch `review-fixes-integration`, 2026-11-13, after merging L, R, W, D and K:

- `swift test`: passed five consecutive runs; each 671 tests (257 core, 407 app with 1 opt-in perf test skipped, 7 Quick Look), 0 failures. Correction (found by Astra in round 3): every run logs one "Conflicting constraints detected" warning from `testSidebarToggleDoesNotChangeWindowFrameWidth` (`DocumentChromeViewController.swift:614`); my log check searched for the older "Unable to simultaneously satisfy" wording. The warning also reproduces in isolation at `170c299`, so it predates this round.
- Real `dev.wafer.scroll-state` key count: 2,633 before and after each of the five runs.
- `scripts/check.sh`: passed (Swift tests, 40 Python release tests, Node tests, 25 vendored asset checksums).
- `scripts/build-app.sh release` and `scripts/verify-appex.sh build/Wafer.app`: passed. Bundles: `Contents/Resources/Wafer_WaferApp.bundle`, `Contents/Resources/Wafer_WaferCore.bundle`, appex `Wafer_WaferCore.bundle`. dSYMs: `build/Wafer.dSYM`, `build/WaferQuickLook.dSYM`.
- Shipped executable: 0 `ForTesting` symbols, 0 checkout paths.
- Stream regressions verified failing before their fixes: L1, D1, D3, D4, W1, W4, W5, K2.
- Not run: hosted CI, notarization, publication, installed Finder Quick Look smoke test.
