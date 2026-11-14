# Library scan liveness and recovery, 2026-11-14

Warm recovery is faster on the 2,000-file fixture. The median fell from 8,906.6 ms to 120.6 ms, about 74 times faster. Cold scan times show no measurable improvement. All five fixed recovery scans reused all 2,000 parsed entries.

## Measurements

Values are medians of five fresh processes per side. Ranges show minimum to maximum.

| Measurement | Before | After |
| --- | ---: | ---: |
| Cold index scan, ms | 8,835.1 (8,588.9 to 9,144.3) | 8,887.6 (8,548.6 to 10,603.2) |
| Warm recovery scan, ms | 8,906.6 (8,649.4 to 9,256.4) | 120.6 (112.8 to 124.8) |
| Files parsed during cold scan | 2,000 | 2,000 |
| Files parsed during recovery | 2,000 | 0 |

[Raw runs](2026-11-14-library-scan-results.jsonl) contain every measurement, parse count, and search-result count. The [chart](2026-11-14-library-scan.html) uses the same medians.

The existing `library-index.swift` runner now times a recovery scan immediately after its cold scan, passing the cold result as `existingFiles` with `changedPaths: nil`. Each process creates 2,000 real Markdown files of exactly 20,000 bytes each, totaling 40,000,000 bytes. Content varies between files and within each file. Fixture generation and parser warmup are outside the timers. "Cold" means no existing parsed index, with filesystem pages potentially cached after fixture creation.

Both scans must return all 2,000 files with no failure, truncation, or skipped items. Recovery must return exactly the cold scan's entries. Existing search assertions still check expected match counts and requested snippets. Every measured process exited successfully. The timers include traversal, metadata, body reads when needed, parsing, index-field construction, and sorting. They exclude controller diffing, snapshot construction, and AppKit presentation. These numbers describe synchronous scanner latency on a synthetic corpus, not complete UI latency.

The baseline is `0bba9cd7af5bd480646fb1993c0f3ece92ee952f` with only a `parsedFileCount` counter added. The [baseline patch](2026-11-14-library-scan-baseline.patch) records that instrumentation. The fixed core is commit `4593282`. Both executables use the same updated runner and Swift 6.4.2 release objects, compiled with `swiftc -O -whole-module-optimization` for arm64 macOS 14.

Runs alternate before, after, before, after for five pairs on this 14-core controller. Initial load averages were 1.90, 1.75, and 1.77. Desktop processes and other agents remained active. Build and test work overlapped the early pairs, and `scripts/check.sh --perf` overlapped later pairs. Load reached about 6.3. The cold ranges overlap, so the small median difference does not support a cold-scan speed claim. The recovery improvement is much larger than the observed variation.

A separate, unreported baseline run was profiled with `sample <pid> 2 -file <output>`, starting three seconds after process launch. `ps` reported 98.4% CPU, roughly one core. The sampled main thread was inside `LibraryScanner.scan`, with stacks in `MarkdownParser.parse`, rendered-text extraction, and String processing for index fields. Metadata calls occupied few samples. This supports parsing and index-field construction as the baseline limiter. Recovery removes that work for unchanged entries. Its remaining traversal, metadata, and sorting work is inferred from the reuse path and zero parse count. The profiler was not attached to any of the ten reported runs.

## Decisions

A running scan finishes and publishes. Further requests coalesce into one pending scan, with dirty paths collected separately from the running scan's captured paths. A full request promotes that follow-up to a recovery walk. A scan that finishes during the debounce window leaves those pending events intact. The 500 ms debounce and two-second maximum wait still determine when to request a rescan. A queued rescan waits for the current scan to finish. Closing or switching libraries advances the generation and cancels the old scan, so it cannot publish into the new library.

Recovery walks still enumerate the entire tree to find additions and deletions. They reuse a file when size, modification date, device/inode identity, and status-change date match. `stat` reads that metadata without opening the file body. Device/inode identity catches atomic replacement. Status-change time catches ordinary writes that restore modification time. An explicit dirty-file event always forces a read. Metadata is checked again after parsing, and a file that changed during the read is marked for another read on the next scan.

This choice trusts filesystem metadata. It avoids reading and hashing all 40 MB on every recovery scan. It does not promise to detect content changes from a filesystem that reports identical or stale values for every checked field. Existing byte budgets, read-failure retention, root-failure reporting, and cancellation checkpoints remain in place. No `DirectoryChangeMonitor` or scheduler implementation change was needed.

## Regression evidence

The following command ran with the original controller and the original `changedPaths != nil` reuse gate. The parse counter and new metadata fields remained available so the final tests compiled. Both source files were restored in a `finally` block after the run.

```sh
swift test --filter 'LibraryControllerTests.testContinuousChangesPublish|LibraryControllerTests.testChangeDuringDebounce|LibraryIndexTests.testRecoveryScanReuses'
```

The run exited with code 1. [Captured output](2026-11-14-library-scan-regressions.log) records three failing tests with seven assertion failures:

- Continuous writes left the published file list empty after the first and second scans exited. The expected titles were `First` and `Second`. The initial completion had also not fired. The test gates worker completion and advances an injected clock through repeated events, with no wall-clock sleeps.
- An event inside the debounce window cancelled the initial scan, so its publication expectation was unfulfilled.
- Recovery parsed two unchanged files instead of zero, then parsed two files after one edit instead of one.

With the fix, these tests pass. Additional coverage checks explicit dirty-file parsing, replacement at the same size and modification date, and a write that restores modification time. The earlier `testContinuousMonitorChangesStartRescanWithinMaximumWait` still passes. Existing close/switch staleness, unavailable-library, skipped-item, and byte-budget tests also pass.

## Verification

- `swift build`: passed.
- `swift test`: 798 tests, zero failures, two opt-in performance tests skipped. Counts were 269 core, 516 app, and 13 Quick Look tests.
- `scripts/check.sh --perf`: passed. All 798 Swift tests passed with zero skips, followed by 61 Python tests and four JavaScript tests. Vendored-asset verification passed. Neither full Swift run emitted constraint warnings.
- Test preferences use the existing in-memory `makeTestUserDefaults` implementation. A check of 702 test suite names from this task's logs found zero preference files or lock files.
- `git diff --check`: passed.

The stream did not run release app assembly, notarization, sandbox smoke tests, the focused-round reviewer, or the five-run integration gate. It did not launch `dev.wafer.app`, change grants or access prompts, touch remotes, or start subagents. The parent stream owns integration acceptance and merging.

## Reproduction

Build the existing standalone runner in the fixed checkout:

```sh
python3 docs/benchmarks/library-index.py /tmp/wafer-index-after
/tmp/wafer-index-after
```

For the baseline, use an existing checkout at `0bba9cd`, apply the linked counter-only patch, and build with the updated runner passed as the second argument to `library-index.py`. Run the resulting before and after binaries in alternating fresh processes five times. The helper builds release core objects and links a standalone executable. It does not launch the app. Each runner removes its own temporary fixture directory on exit.
