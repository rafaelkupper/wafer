# Project cleanup

## Goal

Remove obsolete local artifacts and repository clutter while retaining what is needed to develop, test, and release Wafer.

## Context

Starting commit: ce4498d. Project disk usage is approximately 1.0 GiB. App source and manifests are committed; AGENTS.md has an existing user edit. The current signed/notarized 1.3.0 release must remain intact.

## Constraints

- Delete only inventoried paths inside this project. Preserve Git history, main, user instruction edits, credentials, source assets, third-party licenses, fixtures, and current release artifacts.
- Keep source dependency checkouts and repositories for continued development. Remove compiler output with SwiftPM's clean command after validation.
- Keep current README and architecture documentation, performance evidence and reproducible tooling, and the current release audit. Remove superseded implementation plans and logs.
- Keep editable master icon artwork under App/Resources and retain Wafer.icns, the iconset, and the preview fixture. Decoded pixels in the 16- and 32-pixel iconset images differ from an iconutil round-trip; those editable sizes are useful source assets.
- Remove source only when callers have been checked. Do not remove AppKit callbacks or used test seams.
- Remove merged local branches only. Compact Git objects without expiring reflogs or pruning unreachable objects. The initial cleanup did not mutate remotes; the user subsequently authorized committing and pushing the cleanup to origin/main.

## Done-when

- No obsolete release backup folders, redundant notarization ZIP, stale project compiler cache, old compiled products, or obsolete plans remain.
- Current release ZIP checksum and signed app verification remain valid.
- Tests and optimized compilation pass after source cleanup; package metadata and dependency checkouts remain usable after cleaning compiled output.
- Pending instruction edits and retained source assets match their original checksums.
- Record actual disk usage and the retained development/release files in the cleanup result.

## Progress

- Inventoried project files, Git state, disk usage, callers, scripts, and resources. All eight old local feature branches are merged into main; no other worktrees or active build processes were found.
- Compared all ten iconset images with iconutil reconstruction using decoded RGBA pixels. Eight match, but the 16- and 32-pixel sizes differ. Preserve the complete editable iconset rather than discarding unique source artwork.
- Removed an unused sidebar spacing function, two unused test helpers, and a redundant theme-update forwarding method. The theme-change caller now invokes the existing guarded update directly.
- Removed obsolete release backup directories, the redundant notarization upload ZIP, stale project compiler cache, Finder metadata, and 20 superseded planning/log files. Moved the original icon master into App/Resources. Preserved current release provenance in dist before deleting backups.
- Deleted eight local feature branches after proving they are merged into main. Compacted Git without pruning or expiring retained reflogs; all 2,430 objects and all remote-tracking references are unchanged. Git integrity checks passed.
- `swift test` passed: 516 tests, zero failures, 23.20 seconds. `swift build -c release` passed in 7.95 seconds. Removed compiled outputs afterward with `swift package clean`.
- After cleaning, SwiftPM still describes all five targets. Both dependency checkouts match Package.resolved and their local repositories remain available. The next build will recompile.
- All eight protected file checksums match, including existing AGENTS.md edits, the moved icon master, Package.resolved, and the 1.3.0 ZIP. The retained app passed strict signature, stapled-ticket, and Quick Look verification.
- Current documentation links and `git diff --check` passed. At the end of cleanup, HEAD was ce4498d and changes were local and uncommitted. No remote Git operation, app replacement, installation, or re-signing occurred during cleanup. The follow-up commit excludes the pre-existing AGENTS.md edit.
- Project allocation fell from 1,122,254,848 bytes to approximately 74 MB, reclaiming approximately 1.05 GB. Source, tests, fixtures, editable artwork, dependency downloads, benchmark tooling/evidence, current documentation, and the signed 1.3.0 release remain. All done-when items are complete.
