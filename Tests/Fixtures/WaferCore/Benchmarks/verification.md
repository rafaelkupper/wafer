# Workstream K verification receipt, 2026-11-13

Scope: WaferCore sources/tests, test fixtures, and WaferCore architecture documentation only. No remote git operations, push, app packaging, deployment, or subagents.

## Regression evidence

- `swift test --filter ReaderContainmentTests` before the K2 fix: FAILED as intended. `testRawHTMLAcrossMarkdownContainersCannotCloseReaderColumn` returned `[false, true, false]` instead of `[true, true, true]` from WebKit DOMParser. Two documents put the trailing paragraph outside the reader column.
- The same command after the `main` boundary change: PASSED, 1 test, zero failures.
- `WAFER_UPDATE_GOLDENS=1 swift test --filter 'RenderCompatibilityCorpusTests|WebKitHTMLRendererTests.testReaderGoldenOutputMatchesCheckedInHTML|ReaderContainmentTests|AssetResolverTests'`: PASSED, 14 tests at that stage. Reviewed golden diffs change only `<div id="write">`/`</div>` to `<main id="write">`/`</main>`.
- Final seeded property check: 128 fixed-seed generated inputs, each through the sanitizer, reader, and preview, for 384 documents parsed with WebKit DOMParser. Checks DOM script elements, handler attributes, JavaScript URLs, and reader containment. Included and passed in both full runs.
- Focused resource/search/asset run: `swift test --filter 'BundledResourcesTests|LibrarySearchTests|AssetResolverTests'`: PASSED, 25 tests, zero failures.

## Full final suite

- `swift test`, run 1: PASSED. Quick Look tests 7, core tests 257, app tests 379; zero failures. One app test skipped: `EditSavePerformanceTests.testKeystrokeTriggeredSaveMainThreadTimeOnLargeDocument`, requires `WAFER_PERF_TESTS=1`. Core 6.182 s, app 26.369 s. Run ended 2026-11-13 20:36:55 local time.
- `swift test`, run 2: PASSED. Same counts, same one opt-in skip, zero failures. Core 6.053 s, app 26.089 s. Run ended 2026-11-13 20:38:00 local time.
- Release core and standalone fixture build: PASSED via `python3 Tests/Fixtures/WaferCore/Benchmarks/library-index.py <output> [source]`.
- Missing-resource release probe: PASSED via `/tmp/wafer-k-resource-fallback-2026-11-13/check`. The runner was built from `missing-resources.swift`, with no adjacent core bundle. Output: `PASS: missing resources preserve reader CSS, literal emoji, and code fences without waiting for scripts`.
- `git diff --check`: PASSED.
- App bundle assembly/packaging and opt-in app performance test: UNRUN, outside this core-only assignment. Required index performance measurement ran separately with optimized core code.

## Performance

See README.md for measurement boundaries, commands, medians/ranges, noise and limits. `results.jsonl` retains five alternating pairs and all match counts. Every scan indexed 2,000 files / 40,000,000 bytes, with no failures, skips or truncation. Median footprint increase: 359.8 to 137.1 MiB. Median all-match `needle` query without snippets: 814.9 to 651.3 ms. Absent and one-file queries have no meaningful improvement.

Separate unreported samples of both binaries found the remaining limiter in Foundation substring scanning below `LibrarySearch.fullTextMatches`. These samples were not included in timing results.

## Integration notes

New public API: `BundledResources.resourceURL(named:bundleName:) -> URL?`. App streams can use it with `bundleName: "Wafer_WaferApp"`, for example `named: "Scripts/reader-scroll.js"`, then log read/decode failures and choose their own fallback. It supports packaged bundles, SwiftPM hosts and flattened resource filenames without the generated trapping `Bundle.module` accessor. Existing public signatures remain intact.

No literal-name fallback for `My%20Note.md`: URL paths decode once. Address a literal percent in a filename as `%25`. Preview traversal checks remain in effect after decoding.

`escapedJavaScriptString` is untouched for the integrator, as requested. No advanced search index was added; the two-body representation and direct substring ranking remove the requested copies/dictionary with a small change. App code and package/scripts are untouched.

## Measured search source identities

- Sources/WaferCore/LibraryIndex.swift: before SHA-256 `6ec7c3497ba6c964cbb99ed22797b928117fca8c4b1f2bffc5bc53a383449660`; after SHA-256 `a9d9912c70b4b1126d65277c161d5020b9a52f2992a12b1ec3d803577cd8d360`.
- Sources/WaferCore/LibrarySearch.swift: before SHA-256 `afccf0a360d6488c9ca045006f8f87b165f3d4acd06942a8fecc7c8776db9e98`; after SHA-256 `7301ea2792ef5c5fb22cb4e513e6e8ed1af23c5940527ec04ecfde58791f62fe`.
