# Fix the round-5 review findings (focused round)

## Goal

Fix the seven round-5 findings the user approved on branch `sandbox-and-render-split` (head `f14abb3`). Then run a short check of only these changes by one reviewer. If the check passes, merge the branch into local `main`.

## Context

- Round-5 reviews of `f14abb3`: Astra 8, Fable 8, Muse 8. The scores have been flat for four rounds.
- User decision, 2026-11-14: "Yes and yes".
  - Run the focused round on items 1 to 7, followed by a single-reviewer check rather than a full three-reviewer review.
  - Merge into local `main` after this round, not before.
- Earlier plans:
  - `plans/app/2026-11-14/sandbox-hardening.md`
  - `plans/app/2026-11-13/sandbox-and-render-split.md`
- Structural items repeated across rounds stay deferred: the `FolderAccessStore.shared` global, DEBUG seams and release app tests, the size of `MarkdownReaderDocument`, wall-clock test waits, splitting `ARCHITECTURE.md`, AppKit in WaferCore, DNS-rebinding pinning, and the remote-image default.

## Constraints

- No remote git operations, no publishing, no destructive commands.
- Never launch an app with bundle ID `dev.wafer.app`. Do not modify the keychain.
- Delegate through T3 `delegate_task` with seats from `~/.config/pstack/config.json`. Each stream works in its own worktree and commits on its own branch. Streams own disjoint files or disjoint regions of a file.
- Every fix gets a regression test that fails without it. Update GUIDE and ARCHITECTURE where behavior changes.

## Findings by stream

### F. Folder access and library grant lifecycle (hardest-task seat)
Owns:
- `FolderAccessRange.swift`, `FolderAccessNotice.swift`, `FolderAccessStore.swift`, `FolderAccessWindowController.swift`, `AppDelegate.swift`, `LibraryPreferenceStore.swift`
- the library access, prompt and grant methods of `LibraryController.swift`
- their tests, `docs/GUIDE.md`, and the ARCHITECTURE file-access section

Findings:
- F1 (Fable 2): prompts can be aimed at sensitive folders.
  - A link like `../.ssh/config` offers `~/.ssh`.
  - `~/Library/Keychains` and `~/Library/Application Support/<app>` can be offered the same way.
  - `~/Library/Mobile Documents` is asserted offerable.
- F2 (Fable 3): library and grant lifecycle gaps.
  - Removing the library's grant leaves the library selected with a dangling `libraryGrantID`.
  - A library on a disconnected drive shows the one-time "choose again" prompt even though its grant exists.
- F3 (Fable 10): a chosen folder that does not cover the requested file is persisted silently.

### L. Library scan liveness (perf seat)
Owns:
- the scan scheduling and scan methods of `LibraryController.swift`
- `Sources/WaferCore/LibraryIndex.swift`, `DirectoryChangeMonitor.swift`, the library scanner files
- their tests and `docs/benchmarks/`

Finding:
- L1 (Fable 1): every change event cancels the running scan and discards its results, so continuous writes can starve the index. Recovery scans re-parse unchanged files.

### S. Saves off the main thread (bug-fix seat)
Owns `MarkdownEditSession.swift`, `MarkdownEditCoordinator.swift`, `MarkdownSourceLoader.swift`, the save, close and navigation call sites in `MarkdownReaderDocument.swift`, and their tests.

Finding:
- S1 (Astra 1, Fable 9): explicit save, close, quit, navigation and reload completion block the main thread on `queue.sync` save waits.

### N. Network guard and live preview (bug-fix seat)
Owns `RemoteAssetURLGuard.swift`, `ReaderLivePreviewController.swift` and their tests.

Findings:
- N1 (Muse 1): the guard accepts `http`, even though every caller already requires HTTPS. It also misses the special IPv4 ranges `198.18.0.0/15` and `192.0.0.0/24`, and possibly others in the IANA special-purpose registry.
- N2 (Astra 2): `reset(for:)` leaves `scrollSyncInFlight` true. A stale callback can then clear the new page's pending scroll request.

## Done when

- [x] Each finding is fixed, or its resolution is recorded under Decisions.
- [x] `swift test` passes five consecutive runs, with no constraint warnings and no test preference files left.
- [x] `scripts/check.sh`, `--release`, the release build, `verify-appex.sh`, `verify-app.sh` and `sandbox-smoke.sh run` (fresh smoke ID) all pass.
- [ ] One reviewer checks the diff from `f14abb3` and finds no blocking issue.
- [ ] Merge into local `main`.

## Decisions

- F1: `FolderAccessRange.mayOffer(_:)` is the single check for suggestions, widening, panel start and parent hints.
  - It refuses:
    - the old breadth floors;
    - any folder with a hidden path component;
    - anything in the real home's `~/Library`.
  - Exceptions: folders inside iCloud Drive (`Mobile Documents/com~apple~CloudDocs`) and inside `~/Library/CloudStorage/<provider>` stay offerable. Their roots are not.
  - Other apps' iCloud containers, such as Obsidian iCloud vaults, get the explanation instead of a suggestion. The user can still pick the folder in the panel.
- F2a: the library's row in Folder Access is labelled "Your library". Removing it closes the library (`LibraryController.folderGrantRemoved(id:)`).
- F2b: a library that has a grant record is never re-prompted at launch. While its grant is unresolved, it stays selected and shown as unavailable, and it is rescanned when the volume mounts.
- F3: a folder holding none of the needed files is not stored. The user can choose again or cancel. "Grant Access…" in the window bar follows the same rule.
- L1: an active scan always publishes. Then one coalesced follow-up scan runs with the accumulated dirty paths, or a full scan if one was requested.
  - Recovery scans reuse unchanged entries, checked by size, modification time, device and inode, and status-change time.
  - For 2,000 files, the warm recovery scan went from 8,906.6 ms to 120.6 ms; the cold scan is unchanged (`docs/benchmarks/2026-11-14-library-scan.md`).
- S1: explicit save, navigation, reload completion, leaving edit mode, close, quit, overwrite and Save a Copy now complete asynchronously. No production `queue.sync` disk wait remains. The stream's own notes are in `plans/app/2026-11-14/async-save-flush.md`.
- N1: the guard accepts HTTPS only. It also rejects these IANA special-purpose ranges:
  - IPv4: `192.0.0.0/24`, the TEST-NETs, `198.18.0.0/15` and broadcast;
  - IPv6: documentation and discard-only.
- N2: `reset(for:)` clears the in-flight scroll sync. Callbacks check their generation before touching current-page state.
- Not done: the Open Recent `open(2)` probe is still on the main thread (its caller is in `AppMenuBuilder.swift`). File > Retry Library while the library's drive is disconnected still offers the folder panel.

## Verification

Branch `sandbox-and-render-split`, 2026-11-14, after merging N, L, S and F:

- `swift test`: five consecutive passing runs. Each ran 815 tests: 269 core, 533 app (2 opt-in perf tests skipped) and 13 Quick Look. 0 failures and 0 constraint-conflict messages. The Wafer file count in `~/Library/Preferences` stayed at 18.
- `scripts/check.sh` (61 release-tool tests, Node tests) and `scripts/check.sh --release`: passed.
- `scripts/build-app.sh release` built `dev.wafer.app.dev` with 0 `ForTesting` symbols. `verify-appex.sh` and `verify-app.sh` passed.
- `scripts/sandbox-smoke.sh run` with fresh ID `dev.wafer.app.focused-smoke-20261114` passed phases 20 to 23 (container, migration, bookmark restore and reopen, no sandbox violations). `clean` passed.
- The streams verified that their regression tests fail without the fixes: F1, F2a, F2b, F3, L1, S1 (explicit save), N1 and N2.
- Stream L's perf run (`scripts/check.sh --perf`) passed.
- Not run: click-driven checks, hosted CI, Developer ID packaging, notarization.
