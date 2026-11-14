# Fix the 2026-11-13 round-3 review findings

## Goal

Resolve the findings from the third reviews (Astra 8, Fable 8, Muse 8) of `e540489`, which is now merged into `main` as `c9558d4`. The work happens on local branch `review-fixes-round-4`.

## Context

- Earlier rounds: `plans/app/2026-11-13/review-fixes.md` and `review-fixes-2.md`.
- 2026-11-13: the user approved the merge into local `main`, the removal of 20,102 leftover test preference plists (backup at `/tmp/wafer-verify2/test-prefs-backup.tar.gz`), and this fourth round.

## Constraints

- No git commands that touch remotes. No push, publish or notarization. Merging into `main` needs the user's approval.
- No destructive commands. Preserve user data on every save path.
- Proportionate fixes. No new product features.
- Update ARCHITECTURE.md and the docs where behavior changes.
- Delegate through T3 `delegate_task`, using seats from `~/.config/pstack/config.json`. Streams own disjoint files. Test-file edits by T are mechanical, and the integrator resolves any overlap.

## Findings by stream

### R. Build, CI and Quick Look
Owns `.github/**`, `scripts/**`, `Tests/ReleaseTools/**`, `Package.swift`, `Sources/WaferQuickLook/**`, `Tests/WaferQuickLookTests/**`, `docs/DEVELOPMENT.md`, and the three known test-target warning sites.

- R1 (Astra 5, Muse 5): the Quick Look provider request lifecycle is untested, and `PreviewProvider.swift:82` can trap with `preconditionFailure`.
- R2 (Fable 5): optimized builds have no automated tests. Add a release-configuration CI job for at least `WaferCoreTests`.
- R3 (Muse 11, Fable 11): CI problems.
  - `actions/checkout` is not pinned by SHA.
  - The Xcode path is hard-coded.
  - The Node requirement is undocumented.
  - CI runs twice for each pull request.
  - There is no SwiftPM cache.
  - `build-app.sh` hard-codes `.build/<config>` instead of using `--show-bin-path`.
  - Three test-target warnings are documented rather than fixed.

### K. WaferCore
Owns `Sources/WaferCore/**`, `Tests/WaferCoreTests/**`, `Tests/Fixtures/**`, `Sources/WaferApp/LocalAssetLoader.swift` (containment only), and `docs/benchmarks/`.

- K1 (Muse 9, Fable 10): path containment is implemented three times with different rules (`LocalAssetLoader:109`, `WebKitAssets:62`, `LibraryIndex:109`). Make one Core helper.
- K2 (Muse 9): `TokenKind` and `TokenColor` are duplicated, and byte limits are scattered as literals.
- K3 (Muse 7): `LibraryFile` still stores both `plainText` and `searchFields.body`.
- K4 (Muse 8): no performance budget runs by default. Add one generous hard ceiling for parse and render.
- K5 (Fable 8):
  - `ScrollStateStore()` enumerates and prunes the whole domain on every construction.
  - `Set(footnoteDefinitionsByLabel.keys)` is rebuilt for every node.
- K6 (Fable 12): benchmark reports live in `Tests/Fixtures`, so they ship in the test bundle. Move them to `docs/benchmarks`.

### D. Document and editing
Owns `MarkdownReaderDocument.swift`, `MarkdownEditSession.swift`, `MarkdownEditCoordinator.swift`, `MarkdownSourceLoader.swift`, `MarkdownRenderWorker.swift`, `LinkTargetOpener.swift`, `MarkdownDocumentOpener.swift`, and their tests.

- D1 (Astra 1): a stale reload can replace newer saved editor text. Reads and saves need a shared disk revision.
- D2 (Astra 2): a save can write a file larger than the 32 MB open limit.
- D3 (Fable 2): SVG, XML and HTML-conforming images open without confirmation.
- D4 (Fable 3): `renderedPalette` is recorded at schedule time, so a theme change during a render leaves the old palette.
- D5 (Fable 7, 8, 10):
  - `LibraryController.shared` is the document's default snapshot provider.
  - The opener builds a `ScrollStateStore` per document instead of sharing one.
  - `MarkdownDocumentOpener.swift:117` has a no-op ternary.

### W. Reader, network and window chrome
Owns `WebKitReaderViewController.swift`, `DocumentChromeViewController.swift`, `FileChangeMonitor.swift`, `RemoteImageSchemeHandler.swift`, `RemoteAssetURLGuard.swift`, `RemoteExportAssetLoader.swift`, `ExportAssetInliner.swift`, `ReaderScriptResource.swift`, the bundled reader scripts, and their tests (except `DocumentExportControllerTests`).

- W1 (Muse 2): the navigation policy allows every non-link-click navigation.
- W2 (Muse 6): `waferContentReady` and `waferLiveScroll` are registered in the page content world.
- W3 (Muse 1, Fable 9):
  - Redirect validation runs a blocking `getaddrinfo` on the URLSession delegate queue.
  - Lookups are unbounded per image.
  - NAT64 (`64:ff9b::/96`) and 6to4 (`2002::/16`) addresses pass the guard.
- W4 (Astra 3): `FileChangeMonitor` debounce has no maximum delay.
- W5 (Astra 4): the sidebar animation logs "Conflicting constraints detected", and the test checks only width.
- W6 (Fable 8): every full render scans the whole HTML on the main thread to inject a `<head>` meta tag.
- W7 (Fable 10): the `wafer-remote` URL parser is duplicated.

### L. Library wiring
Owns `LibraryController.swift`, `LibraryChange.swift`, `DocumentWindowController.swift`, `DocumentHostWindowController.swift`, `DocumentSidebarViewController.swift`, `AppDelegate.swift`, and their tests.

- L1 (Fable 7): `LibraryController.shared` is read directly by the window and sidebar, and `LibraryChange` round-trips through a string-keyed dictionary.
- L2 (Fable 8): `DocumentHostWindowController:303` builds a `ScrollStateStore` per document.
- L3 (Fable 10): `isDirectory` is duplicated in `AppDelegate` and `LibraryController`.

### T. Test hygiene
Owns the `UserDefaults(suiteName:)` sites in `Tests/**` (63 sites in 22 files), a new shared test helper, and `DocumentExportControllerTests.swift`.

- T1 (Fable 1): tests leave one plist per suite in `~/Library/Preferences`. After a full run, no new files may remain.
- T2 (Fable 4): three export tests make real HTTPS requests.

### Recorded without code change
- Oversized coordinators (Muse 4, Fable 6): each round asked for a split, and the returns are shrinking. Deferred.
- AppKit imports in WaferCore (Muse 10): the app is macOS-only. Deferred.
- Main-app sandbox (Muse 3): the user's decision is pending. ARCHITECTURE.md will state it as the current accepted risk.
- DNS rebinding between validation and connect (Muse 1): this is documented. Pinning the connection to the validated address needs a custom network stack, which is not proportionate for opt-out image loading.

## Done when

- [ ] Each finding is fixed, or its resolution is recorded under Decisions.
- [ ] `swift test` passes five consecutive runs, with no "Conflicting constraints" or "Unable to simultaneously satisfy" in the logs.
- [ ] A full test run leaves no new files in `~/Library/Preferences`, and makes no outbound requests from export tests.
- [ ] `scripts/check.sh`, `scripts/build-app.sh release` and `scripts/verify-appex.sh build/Wafer.app` pass.
- [ ] Merging into `main` waits for the user.

## Decisions

## Verification
