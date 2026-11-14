# Document and editing review fixes

Date: 2026-11-13. Branch: `t3/wafer-document-editing-fixes`.
Code head before this documentation receipt: `a00af989f327af43c903c577d6665978506354d6`.

## Changes

| Finding | Implementation |
| --- | --- |
| D1 | `MarkdownEditSession.swift:513` uses `BoundedFileReader` with the opening limit. Oversized disk files produce `.changedOnDisk` without retaining their bytes or replacing the original. |
| D2 | `MarkdownReaderDocument.swift:113` requires a scroll-state store. Production construction sites pass the real store explicitly. `TestScrollStateStore.swift:8` creates unique test suites and removes them through an XCTest teardown observer, including suites created inside nested factories. The existing in-memory recording defaults test stays in memory. |
| D3 | `MarkdownReaderDocument.swift:355` coalesces live requests behind an active render. Its completion reaches the preview, then the newest text starts. Navigation, explicit renders, and close retain cancellation/generation handling. |
| D4 | `LinkTargetOpener.swift:58` allows known passive regular files, using UTType conformance for images, PDF, media, and RTF, with explicit plain-text and macro-free Office extensions. Executable files, unknown types, directories, and packages require confirmation. Markdown routing and `LinkURLPolicy` stay unchanged. |
| D5 | `MarkdownSourceLoader.swift:7` owns source data, bounded reading, decoding, fingerprinting, generation checks, reload coalescing, and reload-on-change decisions. The document forwards its existing loading API. It shrank from 1,143 to 1,052 lines. |
| D6 | `MarkdownRenderWorker.swift:33` accepts a checked `@MainActor @Sendable` completion. The unchecked callback box is gone. The worker's remaining unchecked conformance names its NSLock and serial-queue invariant at line 8. No other unchecked conformances occur in the owned production files. |

`ARCHITECTURE.md` documents document loading, saving, preview scheduling, and preferences injection. `docs/GUIDE.md` documents link confirmation, preview scheduling, and oversized-save conflicts.

## Verification

- Passed: `swift test` four consecutive ordinary runs. Each ran 638 XCTest cases across Quick Look (7), Core (249), and App (382), with zero failures and one opt-in performance skip.
- Passed: `CFFIXED_USER_HOME=/tmp/wafer-workstream-d-evidence/isolated-home swift test`, again 638 cases, zero failures, one opt-in performance skip.
- Skipped by the existing suite: `EditSavePerformanceTests.testKeystrokeTriggeredSaveMainThreadTimeOnLargeDocument`, which requires `WAFER_PERF_TESTS=1`. No performance measurement was requested.
- Passed: `swift test --filter 'MarkdownSaveBoundsTests|LiveRenderSchedulingTests|LinkTargetOpenerTests|ReaderReliabilityTests|MarkdownReaderDocumentTests'`, 58 cases, zero failures.
- Passed: `git diff --check`.
- Unrun: release packaging and distribution checks. These changes do not change assembly, resources, signing, or release tooling.

### Failing-before evidence

Before the D1, D3, and D4 implementation changes, ran:

```sh
swift test --filter 'DocumentEditingRegressionTests|LinkTargetOpenerTests'
```

The first two tests initially lived in `DocumentEditingRegressionTests.swift`; they were subsequently split into the final files below without changing their assertions.

- D1, now `MarkdownSaveBoundsTests.testOversizedDiskVersionIsABoundedConflictAndIsNotOverwritten`: failed because the conflict retained `32000001 bytes` instead of nil. The test grows a real temporary file beyond the limit, exercises the real save worker, and checks that the original size is preserved.
- D3, now `LiveRenderSchedulingTests.testContinuousLiveRequestsFinishInFlightRenderThenRenderNewestText`: failed five assertions. It scheduled all five texts instead of the initial and first texts, cancelled the in-flight item, dropped its preview output, and failed latest-only follow-up delivery. It controls render completions through an injected queue without sleeps.
- D4, `LinkTargetOpenerTests.testUnknownFilesDirectoriesAndPackagesAskFirst`: failed both assertions. The old implementation opened HTML, disk images, shortcuts, configuration profiles, notebooks, unknown files, and directories/packages without confirmation.

The failing-before command ran nine cases with eight expected assertion failures. The same checks passed after the fixes. Logs remain in `/tmp/wafer-workstream-d-evidence/red.log` and `green.log`.

### D2 preferences proof limitation

The initial read-only snapshot from `defaults read dev.wafer.scroll-state`, counted using the corresponding `defaults export` plist, had 1,288 keys. Concurrent suites in other Wafer worktrees still used the real domain. Monitored full run 3 saw 2,025 -> 2,129 keys; run 4 saw 2,129 -> 2,211. Process working directories from `ps` and `lsof` independently recorded other test worktrees during both runs. Those counts do not prove this branch's isolation.

The parent authorized deferring the shared-domain count proof until integration. Tried the suggested temporary-home alternative. The effective Foundation home was `/tmp/wafer-workstream-d-evidence/isolated-home`, and no `dev.wafer.scroll-state.plist` existed anywhere beneath it after the full suite. However, an explicit `UserDefaults` probe still read 2,465 entries from the real domain. Therefore plist absence under the temporary home is inconclusive and is not presented as isolation proof. No global production test hook was added solely to replace this check. The parent will re-measure the real domain after integration with other suites stopped.

All preferences comparisons were read-only. No user entries were deleted or repaired. Raw preference snapshots were not committed.

## Test files touched for D2

All files are under `Tests/WaferAppTests/`:

- `AnchorLinkEndToEndTests.swift`
- `DocumentHostWindowControllerTests.swift`
- `DocumentNavigationHistoryTests.swift`
- `EditModeTests.swift`
- `EditSavePerformanceTests.swift`
- `LinkSchemeEndToEndTests.swift`
- `LinkTargetOpenerTests.swift`
- `MarkdownDocumentOpenerTests.swift`
- `MarkdownReaderDocumentTests.swift`
- `ReaderReliabilityTests.swift`
- `ReviewRegressionTests.swift`
- `TestScrollStateStore.swift` (new shared helper)
- `WikiLinkAppIntegrationTests.swift`

Other streams' test files received constructor injection only. Opener tests also inject their document factory. Tests created for D1 and D3 use the same helper.

## Delivery

Six logical implementation commits, all with the requested coauthor footer:

- `fc3f725` Require explicit scroll-state stores and isolate document tests
- `068ab3e` Bound save conflict reads to the document size limit
- `0c67f72` Confirm linked files unless their type is known passive content
- `8be63a4` Let live renders finish and coalesce the newest pending text
- `aed7094` Check render completion isolation instead of boxing callbacks
- `a00af98` Extract source loading and reload decisions from the document

No subagents, remote git operations, pushes, publishing, or shared-environment mutations were performed. The required NSDocument/Objective-C initializer remains available with its production dependencies; its existing smoke test does not load a source or persist scroll state.
