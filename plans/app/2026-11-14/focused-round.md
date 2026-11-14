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

- [ ] Each finding is fixed, or its resolution is recorded under Decisions.
- [ ] `swift test` passes five consecutive runs, with no constraint warnings and no test preference files left.
- [ ] `scripts/check.sh`, `--release`, the release build, `verify-appex.sh`, `verify-app.sh` and `sandbox-smoke.sh run` (fresh smoke ID) all pass.
- [ ] One reviewer checks the diff from `f14abb3` and finds no blocking issue.
- [ ] Merge into local `main`.

## Decisions

## Verification
