# Asynchronous save flush (stream S)

## Goal

Remove main-thread disk-write waits from interactive saves and every dependent action, preserving save order, disk revision checks, and conflict choices.

## Context

Focused round S1, based on 0bba9cd. The existing synchronous Bool APIs force navigation, reload, tab/window close, and quit to wait on the save worker. Window close callers also require small adaptations in DocumentWindowController and DocumentHostWindowController. AppDelegate changes stay limited to termination.

## Constraints

No remote git operations, no destructive commands, no app launch. No subagents. In-memory test preferences. Preserve newer editor text while writes and reads complete. One coalesced flush per editor, deferred close/quit.

## Done-when

- Completion-based save/flush and ordered reload delivery, with no production synchronous worker drains.
- Controlled slow-writer tests demonstrate responsive explicit save, navigation, close and reload, completion after writes, and coalescing.
- At least one regression test fails against the baseline implementation.
- swift build and swift test pass; architecture save section updated; local commit with requested coauthor.

## Decisions

- Replace the synchronous session/coordinator/document save APIs with completions. There is no bounded-wait fallback and no production save queue drain. Conflict prompts remain on the main actor; normal writes, overwrite, encoding/hashing, and Save a Copy run on the serial worker.
- Keep a flush open until the latest editor revision is saved. Coalesced callers resume together. Save cancellation resumes them with failure and retains the editor text.
- Defer the existing document/window close hooks. Re-find tabs by document identity after the asynchronous write, and recheck whether a closing tab became the last one. Window close rechecks tabs added during the flush.
- Use `.terminateLater` and one deferred reply, coalescing repeated quit requests. Quit can join a close's flush and includes documents opened while earlier writes were pending.
- The existing source loader's save barrier is now a completion. Deliver save bookkeeping before checking the captured disk revision, repeating stale reads instead of replacing newer saved text.
- Update old synchronous test assertions to await completions. Test-only `SaveTestSupport` helpers pump the test run loop; asynchronous teardown awaits the flush before removing fixtures. Cancel-only fixtures explicitly discard their own unsaved test text during teardown.
- Necessary caller adaptations extend to DocumentWindowController and DocumentHostWindowController. AppDelegate changes are confined to termination state, injected flush/reply closures for tests, and applicationShouldTerminate; folder-access code is untouched.

## Verification

- `swift build`: passed.
- `swift test --filter AsyncSaveFlushTests`: seven controlled-writer tests passed. They cover explicit-save responsiveness, navigation after both snapshot revisions, close plus concurrent/repeated quit, Cancel preserving text, coalesced flush completions, simultaneous tab closes, and a document opened during quit. No fixed sleeps were added.
- `DocumentEditingReviewTests`: the two reload-order tests retain the disk revision assertions. The undelivered-save case now holds the writer until the main actor confirms read delivery is waiting asynchronously, then releases it and checks that the loader rereads C instead of applying stale B.
- Existing conflict, Save a Copy, encoding/BOM/line-ending, size-bound, navigation-during-read, and autosave-order tests pass through the completion API.
- Red proof: `python3 plans/app/2026-11-14/prove-async-save-regression.py` extracts local commit 0bba9cd7af5bd480646fb1993c0f3ece92ee952f into a disposable directory and runs the explicit-save regression. The original saveEdits action blocks the main turn that releases the controlled writer. Its five-second failure-recovery timeout expires; the test fails with "The save action must return while the disk writer is blocked" and disk text remains "old" rather than "new". It also catches queue.sync executing the writer on the main thread. The baseline adapter only gives final cleanup the completion spelling; it does not change the tested action or assertions.
- `git diff --check`: passed. No app bundle was launched and no remote git operation was run.

## Handoff boundaries

Release packaging, sandbox smoke, the overall focused round's five consecutive full-suite runs, the parent review, and merging into local main belong to the parent round. No new latency/throughput measurement was run. Existing opt-in performance output now separates the explicit-save main turn from completion latency.

Final acceptance on 2026-11-14:

```text
swift build: exit 0
swift test: exit 0
WaferQuickLookTests: 13 tests, 0 skipped, 0 failures
WaferCoreTests: 267 tests, 0 skipped, 0 failures
WaferAppTests: 521 tests, 2 skipped, 0 failures
Total: 801 tests reported, 799 passed, 2 skipped, 0 failures
AsyncSaveFlushTests: 7 tests, 0 failures
Baseline regression runner: exit 0 (expected swift test exit 1)
Baseline explicit-save regression: 1 test, 5 failed assertions
```

The two skips are existing opt-in performance measurements. The final full-suite log has no compiler warnings or Auto Layout constraint warnings. The baseline runner removes its disposable checkout/build; it preserves its raw log in the system temporary directory and prints the path.
