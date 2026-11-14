# Library, preferences and app shell fixes

## Goal
Resolve L1 through L5 from review-fixes-2 and preserve File > Load Remote Images.

## Context
Implementation stream L works on its own branch; other streams own core, document,
reader/window and release tooling changes. The integrator will migrate observers
outside this stream after integration.

## Constraints
Only edit the assigned app files, extracted files, their tests and requested docs.
Keep notification names and existing payload keys compatible. Remote images stay on
by default. No remotes, publishing, destructive commands or subagents.

## Done-when
- Library rescan starts within a maximum wait under continuous file changes.
- Deterministic regression fails without the deadline and passes with it.
- Notification payloads have shared typed definitions and Sendable safety is explicit.
- Update quit deferral is tested without starting Sparkle.
- Missing bundled themes fault and degrade predictably.
- Menu behavior remains covered; documentation reflects changes.
- swift test passes twice; logical commits include the requested co-author trailer.

## Changes

- L1: `LibraryController.scheduleMonitorRescan` preserves a two-second deadline
  from the first pending event while retaining the 500 ms quiet-period debounce.
  Selecting or closing the library and firing a rescan reset the deadline.
  `LibraryRescanScheduler` injects monotonic time and delayed execution.
- L2: `LibraryChange` and the four payload types in `PreferenceNotifications.swift`
  define both the posted dictionaries and `value(from:)` accessors. Names and
  dictionary keys remain compatible. Tests observe real preference changes,
  library scan completion and library close, including nil folder values.
- L3: `UpdateController` accepts session, visible-window and termination closures;
  Sparkle's cycle delegate calls `updateCycleDidFinish`. Tests cover active and
  inactive sessions, repeated requests and completion, and reopening a window.
  They use a bundle without SUFeedURL, so no updater or network activity starts.
- L4: Removed unchecked Sendable from the already main-actor-isolated
  `AppearancePreferenceStore`. All its production clients (AppDelegate,
  AppearanceMenuController, MarkdownReaderDocument, DocumentWindowController and
  DocumentHostWindowController) use the main actor, as do its tests. Compilation
  verifies the checked isolation. The other stores retain nonisolated APIs used
  in their non-main-actor tests and hold only immutable references to thread-safe
  UserDefaults and NotificationCenter. Their conformances now say why they are safe.
- L5: Bundled theme lookup no longer uses the trapping Bundle.module accessor.
  Missing bundles, missing expected JSON files, unreadable directories and invalid
  bundled themes produce a resources fault and a diagnostic. Remaining bundled
  and user themes still load. Compiled System, Light and Dark remain available;
  an unavailable selected custom theme resolves to Dark. The expected filenames
  cover the fourteen shipped JSON resources and can be injected for fixtures.
- The existing File menu and preference tests already cover Load Remote Images
  placement, action, target, on-by-default state and toggling to off. Its menu
  implementation and default were preserved.
- ARCHITECTURE.md and docs/GUIDE.md describe the deadline, payload API, concurrency
  rationale, theme degradation and remote-image toggle.

## Integrator migrations

The following unowned observers deliberately retain their existing dictionary
lookups. They remain functional with these commits:

- `Sources/WaferApp/DocumentSidebarViewController.swift:737`,
  `handleLibraryDidChangeNotification(_:)`: migrate contentChanged and
  availabilityChanged reads to `LibraryChange.value(from:)`.
- `Sources/WaferApp/MarkdownReaderDocument.swift:498`,
  `handleLibraryDidChangeForWikiLinks(_:)`: migrate contentChanged to
  `LibraryChange.value(from:)`.

`DocumentStatisticsAccessoryViewController.handleStatisticKindChange()` ignores
its notification's payload and reads the preference store. It has no string key
to migrate. No production observer reads string keys from the other preference
notifications. Their existing test observers verify compatibility and also read
the new typed accessors.

## Decisions and limits

- No duplicate menu test: the existing AppMenuBuilderTests and default preference
  test already exercise the requested behavior.
- No main-actor conversion of the remaining three preference stores: their
  thread-safe dependencies and immutable stored references make a documented
  unchecked conformance the smaller fix without restricting their existing API.
- A rescan request waits for any cancelled scan to exit. The new deadline bounds
  debounce starvation, not blocked filesystem I/O or main-queue execution.
- Packaging scripts and verification remain owned by stream R. No release build,
  packaging, signing, notarization, live update download or installation was run.
- No edits to other workstreams' source files, no subagents, no pushes and no git
  commands against remotes. All commits include the requested co-author trailer.

## Verification

- Deliberate failure: `swift test --filter LibraryControllerTests.testContinuousMonitorChangesStartRescanWithinMaximumWait`
  exited 1. The test and scheduler seam were added before adding the maximum-wait
  calculation, retaining the original debounce-only scheduling. Changes every
  250 ms left isScanning false at virtual time 2.0, failing the assertion
  "continuous writes must start a rescan by 2 seconds". No sleep advances the
  test clock. It passes with the deadline calculation.
- Passed: `swift test --filter 'LibraryControllerTests|PreferenceStoreTests'`,
  26 tests, zero failures after the deadline and payload changes.
- Failed during development: the first theme/update/menu focused build lacked a
  WaferCore import in the new theme test. Added the import and reran the checks.
- Passed: `swift test --filter 'LibraryControllerTests|PreferenceStoreTests|ThemeLibraryTests|UpdateControllerTests|AppMenuBuilderTests'`,
  53 tests, zero failures. The first version of the update tests warned about
  mutable closure captures; a main-actor fixture removed those warnings.
- Passed: two initial full `swift test` runs, each with 7 Quick Look tests,
  249 core tests and 387 app tests, zero failures. The single skipped test is
  EditSavePerformanceTests.testKeystrokeTriggeredSaveMainThreadTimeOnLargeDocument,
  which requires WAFER_PERF_TESTS=1. Performance measurement is outside stream L.
- Final verification after the warning cleanup is recorded below.
- Passed: final `swift test > /tmp/wafer-l-final-1.log 2>&1`, exit 0.
  Quick Look: 7 tests, zero failures. Core: 249 tests, zero failures. App: 387
  tests, zero failures, the one opt-in performance test skipped. No compiler warnings.
- Passed: final `swift test > /tmp/wafer-l-final-2.log 2>&1`, exit 0.
  Quick Look: 7 tests, zero failures. Core: 249 tests, zero failures. App: 387
  tests, zero failures, the same performance test skipped. No compiler warnings.
- Passed: `git diff --check`.

Branch: `t3/wafer-library-preferences-fixes`. Implementation and verification are
complete for stream L. The integrator migrations above remain outside its ownership.
