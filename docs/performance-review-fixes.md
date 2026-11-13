# Performance review fixes, 2026-09-07

All 17 findings from the review of `fc98175` are addressed. The implementation keeps Swift, AppKit, WebKit, and swift-markdown and adds no dependencies. Unrelated local changes were preserved. No commit, remote operation, app signing, installation, or deployment was performed.

## Measured results

These are synthetic native-operation timings on the same Apple silicon Mac used for the review, running macOS 26.6.2 and Swift 6.3.3. Core figures below use the median of repeated optimized runs. The fixture contains 2,000 notes of 3,774 bytes each. Sidebar figures measure changing to Library mode and forcing layout without displaying a window, once per size, matching the original probe. They are not end-to-end application launch or frame-rate measurements.

| Operation | Before | After |
| --- | ---: | ---: |
| Sidebar construction/layout, 500 rows | 7,792 ms | 7.9 ms |
| Sidebar construction/layout, 2,000 rows | Unmeasured | 9.3 ms |
| Unchanged 2,000-note refresh | 3,643 ms | 110 ms |
| Refresh with one explicitly dirty note | Unmeasured | 111 ms |
| Quick Open, 2,000 notes | About 40 ms | 3.6 ms |
| Full-text search with all snippets | About 472 ms | 40.9 ms |
| Full-text ranking, snippets deferred to visible rows | Unmeasured | 11.5 ms |
| Unchanged index diff | About 46 ms | 1.9 ms |
| Build backlinks, 20,000 edges | About 217 ms | 122 ms, off-main |
| Render an index linking 1,000 local notes | About 946 ms | 68.5 ms |
| Scan 10,000 nested wiki openers | About 1,692 ms | 0.19 ms |
| Initial indexing without a previous snapshot | 3,643 ms | 4,192 ms |
| Parse/render a 10,000-line Swift fence | About 98 ms | 96.5 ms |

Initial indexing is approximately 15% slower in the final run because it prepares reusable search fields and word counts. An earlier implementation run measured approximately 12%. This is a deliberate tradeoff for much cheaper queries and refreshes, with additional per-file search metadata in memory. No decoded-image or whole-app RSS limit is claimed.

Quick Open and sidebar search now run off-main with a 60 ms debounce, so native search duration is only part of interactive response time. The 11.5 ms full-text result excludes snippet generation; snippets are generated for realized rows. The linked-index measurement now excludes deferred summaries. Visible-row loading preserves titles and previews without delaying the reader; it uses library metadata when possible and otherwise reads a maximum 256 KiB prefix per linked note. Row order stays stable while titles arrive.

## Finding disposition

| Finding | Implementation and verification |
| --- | --- |
| 1. Eager sidebar rows | Reusable NSTableView cells, stable row identities, cached folder tree, row-level updates, and no content rebuild on scanning-status notifications. A 2,000-file test verifies fewer than 25 realized rows. |
| 2. Reader/WebView ownership cycle | Weak message-handler forwarding plus production shutdown on document close. The reader deallocates without test-only invalidation. |
| 3. Remote-image session cycle | URLSession owns a separate delegate that does not own the fetcher. Fetcher deinit invalidates its session. The optimized successful-request probe confirms release. |
| 4. Repeated scans and obsolete work | Reuse unchanged LibraryFile values; retain/filter FSEvents paths; force dirty-file reads; recover after dropped events. One active scan and one pending refresh, with cancellation between files. Tests cover identical size/date edits and superseding a blocked scan. |
| 5. Main-thread index publication | Build the diff, backlinks, normalized lookups, and shared wiki resolver in an immutable LibrarySnapshot off-main; publish by swapping the snapshot. |
| 6. Repeated search work | Prepare search fields once; serial latest-query workers cancel obsolete work; generate snippets only for visible sidebar results. Immediate Return waits for the current Quick Open query instead of opening stale results. |
| 7. Eager linked-note metadata | First render emits placeholders without reading linked notes. Visible rows request bounded cached summaries. Hidden-sidebar tests verify no enrichment until shown. Preview omits statistics and sidebar metadata. |
| 8. Theme reparsing and inactive tabs | Retain one source parse/metadata per document worker. Theme changes update CSS in place and rerender only Mermaid figures. Inactive tabs adopt the palette on activation. WebKit tests verify heading identity, scroll preservation, and diagram replacement. |
| 9. Scroll overhead | One report across timer/frame callbacks, cached heading positions, binary search, and layout-triggered invalidation. The actual injected script passes both scheduler orders: 100 scroll events cause no additional heading scan. |
| 10. Quadratic wiki scanning | Single-pass delimiter scanner, with malformed/nested input regression tests and scaling measurements. |
| 11. Preview/export allocation budgets | Bounded source/asset reads; streaming per-request limits use remaining export bytes; serial remote export fetching; window-close cancellation. Quick Look preparation runs off-main and rechecks the 10 MiB attachment budget at read time. Tests cover growing attachments, oversize chunks, aggregate limits, and cancellation. |
| 12. Empty documents | Loaded-state fingerprint gates rendering, so empty source follows the normal render path and replaces prior content. |
| 13. Inconsistent decoding | Initial reads and disk reload/navigation use MarkdownSourceDecoding. UTF-16 and truncated UTF-8/UTF-16 boundary regressions pass. |
| 14. Premature anchor consumption | Pending anchors wait for renderable content. Navigation IDs reject stale page readiness and navigation completions; loading pages cannot consume anchors. |
| 15. Duplicate heading IDs | Allocate against all emitted primary IDs while retaining existing noncolliding IDs. Outline and rendered HTML agree for colliding title/suffix cases. |
| 16. Lost wiki destinations on export | Production ExportPolicy now rewrites wiki links using the chosen output URL as the relative base, with absolute file URLs for destinations outside that directory. |
| 17. Inert exported copy controls | Copy buttons carry data-wafer-chrome. A real WebKit DOM snapshot passed through production export preparation retains code and removes controls. |

## Verification

- `swift test`: 496 tests passed, 0 failures, approximately 19.8 seconds of test execution. Baseline: 473 tests passed. Final full log: `/tmp/wafer-fixes-verified-tests.log`.
- `python3 scripts/benchmark-performance.py`: release build and optimized core/AppKit probes passed. It uses disposable fixtures, binaries, resource links, and isolated preferences, without registering or installing the app.
- `node scripts/benchmarks/scroll.cjs`: timer-first and frame-first checks passed against the current injected script.
- `git diff --check`: passed.
- Existing tests were updated where the intended contract changed: asynchronous Quick Open completion, serialized superseding scans, lazy linked summaries, in-place theme updates, and navigation readiness. Renderer golden hashes required no updates.

Raw results: [final performance run](benchmarks/2026-09-07-performance.log), [original core run](benchmarks/2026-09-07-before-core.log), [original sidebar run](benchmarks/2026-09-07-before-sidebar.log), and [scroll verification](benchmarks/2026-09-07-scroll.log). Benchmark sources are in `scripts/benchmarks`; the runner is `scripts/benchmark-performance.py`.

The build emitted existing module-cache debug-symbol warnings and a test captured-variable warning; compilation and tests succeeded. The standalone sidebar probe also emits a harmless weak-variable mutability warning.

Finder extension election, an installed signed app, whole-app RSS, and end-to-end WebKit frame timing were not measured. Quick Look still imports bounded HTML into AppKit on the main thread; only source preparation and asset inlining moved off-main. Remote-image byte limits bound encoded payloads, not decoded pixel memory. Network export latency may increase for many remote images because fetches are now serial within the aggregate budget.
