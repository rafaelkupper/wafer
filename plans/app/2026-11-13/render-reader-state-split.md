# Extract document and reader state machines

## Goal

Complete stream C of sandbox-and-render-split with no behavior change.

## Context

The document and reader mix independent render, navigation, find, and live-preview state. Baseline line counts: MarkdownReaderDocument.swift 1058, WebKitReaderViewController.swift 1027.

## Constraints

Own only render and theme parts of the document, reader controller extractions, new tests, and the document and reader architecture sections. Preserve DEBUG test forwarding. No remote git operations, sandbox changes, or subagents.

## Done-when

- Render scheduling, coalescing, completion palette, and worker interface live in a directly tested coordinator.
- Reader navigation readiness, find, and live preview with scroll sync live in dedicated types with direct tests.
- Existing behavior and test hooks remain intact.
- Three swift test runs, Node script tests, and swift build -c release pass. Logs contain no constraint warnings and preferences inventory has no new matching files.
- Changes are committed in logical units with the requested co-author trailer.

## Changes

- `Sources/WaferApp/DocumentRenderCoordinator.swift:7` owns generation, cancellation, active render state, pending live snapshots, completion palette, theme reapply, and the worker scheduler. `MarkdownReaderDocument.swift:345` forwards requests and supplies presentation snapshots at line 362. `applyThemeIfNeeded` at line 467 forwards to the coordinator.
- `Sources/WaferApp/ReaderNavigationState.swift:5` owns load authorization, load UUID and readiness, fragment policy, and theme-update completion identity. The reader retains only WebKit navigation object identity.
- `Sources/WaferApp/ReaderFindController.swift:5` owns find controls, normalized query, direction, status, search commands, and selection-clearing JavaScript. The reader forwards its existing menu actions and DEBUG hooks.
- `Sources/WaferApp/ReaderLivePreviewController.swift:6` owns body HTML, helper and patch-baseline state, available renderers, patch/reload decisions, and scroll-sync coalescing. The reader injects script execution with the same content worlds and the existing scroll-preserving reload.
- `ARCHITECTURE.md:233` documents render ownership. The reader types are documented at line 239.

The document's link navigation, history, and load/save glue are unchanged. JavaScript resources and `ReaderLivePreviewScript.swift` are unchanged. `ReaderFindBarView.swift` changes only the action target type.

## Direct tests

All new tests use injected execution and controlled completions, without WebKit views or sleeps. Existing tests were not rewritten.

| Test file | Tests | Coverage |
| --- | ---: | --- |
| `DocumentRenderCoordinatorTests.swift` | 7 | Superseded render, theme change during render and delayed readiness, typing coalescing, full reload during live render, edit enter/exit annotations, cancellation, synchronous completion |
| `ReaderNavigationStateTests.swift` | 4 | One-use authorization and fragments, replacement loads, both readiness event orders, stale UUID and theme completions |
| `ReaderFindControllerTests.swift` | 3 | Normalization and find configuration, empty query and selection clearing, field identity and keyboard commands |
| `ReaderLivePreviewControllerTests.swift` | 7 | Patch baseline, renderer/readiness reload decisions, failed and stale patches, isolated scroll coalescing, page reset, metrics and edit exit, patch realignment and line decoding |

## Line counts

Counts include imports, comments, blank lines, and DEBUG forwarding. Reproduce with `wc -l` on the listed files. Before means the stream's starting checkout.

| Production file/type | Before | After |
| --- | ---: | ---: |
| `MarkdownReaderDocument.swift` | 1058 | 1020 |
| `WebKitReaderViewController.swift` | 1027 | 730 |
| `DocumentRenderCoordinator.swift` | 0 | 85 |
| `ReaderNavigationState.swift` | 0 | 73 |
| `ReaderFindController.swift` | 0 | 177 |
| `ReaderLivePreviewController.swift` | 0 | 207 |

New test file line counts, in the order above: 147, 72, 65, 151.

## Verification

Final verification on the two implementation commits passed. The documentation-only receipt commit does not change the tested source.

| Command or check | Result |
| --- | --- |
| `swift test --filter 'DocumentRenderCoordinatorTests\|ReaderNavigationStateTests\|ReaderFindControllerTests\|ReaderLivePreviewControllerTests\|MarkdownRenderThemeRaceTests\|WebKitReaderViewControllerTests'` | Passed: 61 tests, zero failures |
| `swift test`, run 1 | Passed: 13 Quick Look + 265 Core + 450 App tests, zero failures, one skip |
| `swift test`, run 2 | Passed: same counts, zero failures, one skip |
| `swift test`, run 3 | Passed: same counts, zero failures, one skip |
| `for t in Tests/JavaScript/*/*.cjs; do node "$t"; done` | Passed all three files: live preview, reader scroll, and renderer scripts |
| `swift build -c release` | Passed, including the app target, with no DEBUG-only symbol leak |
| Search all verification logs for `Conflicting constraints` and `Unable to simultaneously satisfy` | Passed: zero matches |
| Compare `~/Library/Preferences` before and after; scan subdirectories too | Passed: zero `dev.wafer.tests*` or UUID-named files before or after |
| `git diff --check` | Passed |

Each full run discovers 728 tests, passes 727, and skips the existing `EditSavePerformanceTests.testKeystrokeTriggeredSaveMainThreadTimeOnLargeDocument`. That test requires `WAFER_PERF_TESTS=1`; performance measurement is outside this structural refactor. Early focused compilation attempts caught Swift type-inference, actor annotation, selector qualification, and test-fixture errors. Those were corrected before the final successful checks.

Local logs and preference inventories are retained in ignored `build/verification-stream-c-2026-11-13/`. No test hooks or existing test files were removed or rewritten.

## Delivery and limits

Branch: `t3/render-reader-state-split`. Implementation commits: `2228115` (document render coordinator) and `d0e4341` (reader split, direct tests, architecture).

No sandbox changes, packaging, signing, manual app smoke test, remote git operations, or subagents. Those belong to stream S or the integrating parent. No published artifacts or changes to shared environments.
