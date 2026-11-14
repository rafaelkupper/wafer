# Harden the sandbox folder-access design

## Goal

Fix the round-4 review findings on branch `sandbox-and-render-split` (Astra, Fable and Muse, all 8/10; Fable gave sandbox security 7). Then run a fifth scored review by the same three reviewers. Merging into `main` waits for the user and for their manual sandbox check.

## Context

- Sandbox and render split: `plans/app/2026-11-13/sandbox-and-render-split.md`. Review head: `3851907`.
- User decision, 2026-11-14: do the hardening, then another three-reviewer review. The structural leftovers stay deferred:
  - release-mode app tests;
  - `FolderAccessStore.shared` injection;
  - the size of `MarkdownReaderDocument`;
  - AppKit in WaferCore;
  - the remote-image default, which the user kept as a menu option.

## Constraints

- No remote git operations, publishing or notarization. No destructive commands.
- Never launch an app with bundle ID `dev.wafer.app`. That would migrate the user's real preferences. Use the smoke copy's own ID.
- Do not modify the user's keychain. Throwaway signing keys live in temporary files and are deleted afterwards.
- Delegate through T3 `delegate_task`, with seats from `~/.config/pstack/config.json`. Streams own disjoint files.

## Findings by stream

### A. Folder access (hardest-task seat)
Owns:
- `FolderAccessStore.swift`, `FolderAccessNotice.swift`, `LocalAssetLoader.swift`, `WebKitLocalAssetSchemeHandler.swift`, `MarkdownSourceLoader.swift`, `AppMenuBuilder.swift`, `AppDelegate.swift`, `LibraryController.swift`, `LibraryPreferenceStore.swift`, `DocumentWindowController.swift`, `DocumentSidebarViewController.swift`
- `MarkdownReaderDocument.swift`: the `close()` hook and the link-navigation methods only
- a new folder-access window
- their tests, `docs/GUIDE.md`, and the ARCHITECTURE.md file-access sections

Findings:
- A1 (Fable 1): document content steers the width of the grant. `ensureAccess` offers the target's parent with no floor, and the notice suggestion widens to the common ancestor down to depth 2 (`/Users/<name>`, `/Volumes/<disk>`).
- A2 (Fable 3): grants are permanent, read-write and invisible. There is no list and no revoke.
- A3 (Fable 4): Open Recent marks URLs as user-selected without checking. An `EPERM` on a covered file returns a raw error with no Grant Access recovery.
- A4 (Astra 2): the library identity is the old path, while its grant follows a moved folder.
- A5 (Astra 3, Muse 4): `fileNeeds`, `linkNeeds` and `userSelections` are never released when a document closes or a reference goes away.
- A6 (Muse 2): after the `F_GETPATH` re-check, the opened path is checked against the document roots but not against the sandbox scope.
- A7 (Muse 3): grant recovery relies on the folder panel being modal.
- A8 (Fable 9): grants on volumes mounted after launch stay unresolved until relaunch. `FileContainment` re-resolves the candidate for each root.

### B. Sandbox tooling and builds (refactoring seat)
Owns `scripts/**`, `.github/**`, `Tests/ReleaseTools/**`, `App/**` (only if a build-ID rewrite needs it), `README.md`, `docs/DEVELOPMENT.md`, and the ARCHITECTURE.md packaging section.

- B1 (all three): `sandbox-smoke.sh check` never fails. Make it assert migration, grants, relaunch access and the absence of violations, and exit non-zero on failure. Run the no-click part in CI if a hosted runner can do it; otherwise document it as a required release gate.
- B2 (Fable 2): the sandboxed Sparkle install path has never run. Test one real update of the smoke copy against a local feed, signed with a throwaway EdDSA key held in a temporary file (not the keychain), without clicks if possible (automatic install on quit).
- B3 (Fable 5): local builds launch the real bundle ID and migrate preferences. Local and CI builds get a distinct development bundle ID; only `package-release.sh` produces `dev.wafer.app`. Update the README.
- B4 (Muse 12): `build-app.sh` runs `swift build` three times.

### C. Save conflicts (bug-fix seat)
Owns `MarkdownEditSession.swift`, `MarkdownEditCoordinator.swift` and their tests.

- C1 (Astra 1): the changed-file and missing-file conflict alerts have no Cancel. Cancelling "Save a Copy..." returns to the conflict alert. Add Cancel, keep both versions, and test the production choice configuration.

## Done when

- [x] Each finding is fixed, or its resolution is recorded under Decisions.
- [x] `swift test` passes five consecutive runs, with no constraint warnings and no test preference files left.
- [x] `scripts/check.sh`, `--release`, the release build, `verify-appex.sh`, `verify-app.sh` and a failing-then-passing `sandbox-smoke.sh check` pass.
- [ ] Astra, Fable and Muse (xhigh) run the scored review.

## Decisions

- A1: `FolderAccessRange` never offers `/`, top-level folders, `/Users/*`, `/Volumes/*`, the real home folder (from `getpwuid`) or its Library, or a mounted volume root. The notice widens at most two levels above the document's folder. Files whose own folder is too broad get an explanatory alert (default OK) instead of a panel. Prompts show the full path.
- A2: grants from the image and link notice are read-only bookmarks. The library and grants requested while editing are read-write. A sandboxed probe showed edit saves fail under a read-only grant, so starting edit mode offers a read-write "Grant Access…". During the session the folder panel itself keeps read-write access until quit; read-only applies from the next launch (documented). Wafer > Folder Access… lists grants with Remove.
- A4: the library refers to its grant by `libraryGrantID` and reopens where the grant resolves.
- A5: `userSelections` is capped at the 512 most recent; images removed during edit mode stop counting at the next full page load.
- A8: covers query 1.048 ms to 0.142 ms (debug, 10 grants, 30 opened files).
- B2: Sparkle 2.10.1 rejects `file://` feeds; the update smoke uses a loopback HTTP feed with `NSAllowsLocalNetworking` confined to smoke copies and a smoke-only host executable, because the production updater disables automatic downloads. The sandboxed `Installer.xpc` installed build 900002 over 900001 on quit.
- B3: `scripts/build-app.sh` builds `dev.wafer.app.dev` by default; only `package-release.sh` builds `dev.wafer.app`.
- Empty container shells left by smoke runs (`~/Library/Containers/dev.wafer.app.*smoke*`, `dev.wafer.*probe*`) cannot be deleted from the shell; the user can remove them in Finder.

## Verification

Branch `sandbox-and-render-split`, 2026-11-14, after merging C, B and A:

- `swift test`: five consecutive runs passed, each 794 tests (267 core, 514 app with 2 opt-in perf tests skipped, 13 Quick Look), 0 failures, 0 constraint-conflict messages, 0 new Wafer test files in `~/Library/Preferences`.
- `scripts/check.sh` (61 release-tool tests) and `scripts/check.sh --release`: passed.
- `scripts/build-app.sh release`: passed; built bundle ID `dev.wafer.app.dev`. `verify-appex.sh` and `verify-app.sh`: passed. 0 `ForTesting` symbols.
- `scripts/sandbox-smoke.sh run` with fresh ID `dev.wafer.app.integration-smoke-20261114`: phases 20 (container), 21 (migration), 22 (bookmark persisted and restored, document reopened) and 23 (no sandbox violations) passed; `clean` passed. Stream B showed phase 21 fails (exit 21) without the migration manifest.
- Streams verified their regression tests fail without the fixes: A1, A3, A4, A6, A7, C1.
- Not run: click-driven checks (desktop control failed with `Computer Use server error -10005` for stream A and the integrator), hosted CI, Developer ID packaging, notarization, the production "Check for Updates" menu path.
