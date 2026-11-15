# Sandbox the main app and split the render coordinator

## Goal

Run `Wafer.app` under the App Sandbox without losing documented features, and pull the render and reader state machines out of the two largest controllers. Then run a fourth scored review by Astra, Fable and Muse.

## Context

- 2026-11-13: the user approved merging round 4 into local `main` (`bc2b1b6`). They then asked for the sandbox and the controller split, followed by another review.
- Benefits and costs were discussed with the user before approval:
  - Sandboxing confines bugs in Wafer's own process (the parser, the sanitizer, the file and asset loaders) to granted files. WebKit content is already sandboxed by Apple.
  - Splitting reduces the interleaving bugs found in rounds 3 and 4 (stale reload over a save, a theme change during a render).
- Today the main app is unsandboxed and signed with the hardened runtime. The Quick Look appex is already sandboxed (`App/QuickLook.entitlements`).
- Sparkle 2.10.1 is pinned. `package-release.sh` signs `Installer.xpc` and `Downloader.xpc`.
- Work branch: `sandbox-and-render-split`, from `main`.

## Constraints

- No git commands that touch remotes. No push, publish or notarization. Merging into `main` needs the user's approval.
- No destructive commands. Preserve user data, including preferences, scroll positions, themes and the library choice, across the switch to a sandbox container.
- No feature may silently stop working. Where the sandbox requires a user grant, Wafer explains it and offers the grant.
- Delegate through T3 `delegate_task`, using seats from `~/.config/pstack/config.json`. Streams own disjoint files, and the parent integrates.
- Update ARCHITECTURE.md (security model, packaging, file access), docs/GUIDE.md (what users see) and docs/DEVELOPMENT.md.

## Design defaults (parent decisions; the user can redirect)

- **Entitlements:** `app-sandbox`, `files.user-selected.read-write`, `files.bookmarks.app-scope`, `network.client` (remote images, Sparkle feed and downloads) and `print`. Add the Sparkle installer mach-lookup exceptions, following the Sparkle 2 sandboxing documentation. No other temporary exceptions.
- **Folder grants:** opening a single file grants only that file. When a document needs files outside its granted scope (relative or wiki links, local images, linked-document summaries), Wafer shows a non-blocking notice in the window: "Allow Wafer to read the folder ... to show linked files and images", with a "Grant Access..." button.
  - The button opens an `NSOpenPanel` that starts at the document's folder and suggests choosing a parent folder.
  - Grants are stored as app-scoped security bookmarks and reused for every later document under that folder.
- **Library:** the library folder choice is stored as a security bookmark. Existing installs that only have the stored path get a one-time prompt to re-select the folder.
- **Migration:** a `container-migration.plist` moves the app and scroll-state preferences and the themes directory into the container on first sandboxed launch.
- **Saves:** saving edits keeps using `itemReplacementDirectory` plus `replaceItemAt`. Confirm this works in the sandbox for a user-opened file. If not, use `NSFileCoordinator` or `NSDocument`'s safe-save path.

## Workstreams

### S. Sandbox (hardest-task seat)
Owns:
- `App/**` (entitlements, `Info.plist`, container migration) and `scripts/**` (signing, verification, local ad-hoc sandbox signing).
- `AppDelegate.swift`, `LibraryController.swift`, `LibraryPreferenceStore.swift`, `ThemeLibrary.swift`, `LinkTargetOpener.swift`, `LocalAssetLoader.swift`, `WebKitLocalAssetSchemeHandler.swift`, `MarkdownSourceLoader.swift`, `MarkdownEditSession.swift`, `DocumentWindowController.swift`, `DocumentSidebarViewController.swift`.
- A new folder-access store and the grant notice view, `Sources/WaferCore/DocumentSummaryCache.swift`, their tests, and the docs.
- In `MarkdownReaderDocument.swift`, only the link-navigation and access-hook methods.

### C. Render coordinator and reader split (refactoring seat)
Owns:
- `MarkdownReaderDocument.swift`: the render scheduling, theme application, live-render and edit-mode render state.
- `WebKitReaderViewController.swift`, plus new files extracted from both, their tests, and the ARCHITECTURE.md document and reader sections.

No behavior change. Extract:
- a render coordinator: render token, `isRendering`, pending live render, rendered palette, theme reapply;
- from the reader view controller: navigation gating, the find bar controller, and live-preview and scroll sync.

## Done when

- [ ] `build/Wafer.app` is signed with the sandbox entitlement, both locally (ad-hoc) and in the release script. `verify-appex.sh`, or a new app verifier, checks the exact entitlement set.
- [ ] Sandboxed smoke test of the locally built app, recorded in the plan:
  - open a file;
  - see a sibling image after granting the folder;
  - follow a relative link;
  - open a library folder;
  - edit and save;
  - export HTML and PDF;
  - load a remote image;
  - switch the theme;
  - relaunch, and check that grants, library, preferences and scroll position survive;
  - first launch migrates the existing unsandboxed preferences.
- [ ] Sparkle configuration follows the sandbox guide and is verified statically. A live update cannot be tested without a published feed, and the plan says so.
- [ ] `MarkdownReaderDocument` and `WebKitReaderViewController` each lose their render or reader state machine to a dedicated, directly tested type, with no behavior change.
- [ ] `swift test` passes five consecutive runs, with no constraint warnings and no preference files left. `scripts/check.sh`, `--release`, the release build and verification pass.
- [ ] Astra, Fable and Muse (xhigh) run the scored review on the result.
- [ ] Merging into `main` waits for the user.

## Decisions

- The library folder is stored as an ordinary folder grant in `FolderAccessStore`, so there is one bookmark store and one coverage rule; Close Library keeps the grant (documented in GUIDE).
- Saving keeps `itemReplacementDirectory` plus `replaceItemAt`: a sandboxed probe confirmed it works on a user-opened file on the startup volume and on an external APFS volume.
- Sparkle: `SUEnableInstallerLauncherService` on; the Downloader XPC service stays off because the app has `network.client` (Sparkle sandboxing guide). Mach-lookup exceptions `dev.wafer.app-spks` and `dev.wafer.app-spki`.
- Local builds are ad-hoc signed with the sandbox entitlements but without the hardened runtime (library validation needs a team identity); release builds use Developer ID with the hardened runtime.
- The reader disables WebKit Safe Browsing lookups; they were the only sandbox denial and add nothing for generated HTML.
- `MarkdownReaderDocument` shrank only 1,058 to 1,020 lines because link navigation, history and load/save stayed put while the sandbox stream edited them; the render state machine is now `DocumentRenderCoordinator` with direct tests. `WebKitReaderViewController` went from 1,027 to 730 lines (`ReaderNavigationState`, `ReaderFindController`, `ReaderLivePreviewController`).
- HTML export still omits images it cannot read, without a grant prompt (`ExportAssetInliner` was outside the sandbox stream).

## Verification

Branch `sandbox-and-render-split`, 2026-11-14:

- `swift test`: five consecutive runs passed, each 759 tests (266 core, 480 app with 1 opt-in perf test skipped, 13 Quick Look), 0 failures, 0 constraint-conflict messages, 0 new Wafer test files in `~/Library/Preferences`.
- `scripts/check.sh` (55 release-tool tests) and `scripts/check.sh --release`: passed.
- `scripts/build-app.sh release`, `scripts/verify-appex.sh` and `scripts/verify-app.sh`: passed. Entitlements are exactly `app-sandbox`, `files.user-selected.read-write`, `files.bookmarks.app-scope`, `network.client`, `print`, and the two Sparkle mach-lookup names. 0 `ForTesting` symbols.
- Sandboxed smoke test by the sandbox stream, using a renamed copy with bundle ID `dev.wafer.app.sandbox-smoke` so the user's real preferences were not migrated: container created and preferences and themes migrated; a single file outside any grant logged the refused reads and showed the notice; a granted folder served the sibling image without reopening; grants restored after relaunch and after re-signing; remote image loaded; only sandbox denial was Safe Browsing (now disabled). Evidence in `/tmp/wafer-sandbox-work/evidence`.
- Not run: click-driven steps (desktop control failed with `Computer Use server error -10005: codex app-server exited before returning a response` for both the stream and the integrator; window capture needs Screen Recording permission), Sparkle update against a published feed, Developer ID packaging, notarization.
