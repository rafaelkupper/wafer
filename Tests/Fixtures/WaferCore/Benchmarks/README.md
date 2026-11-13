# WaferCore review-fix measurements, 2026-11-13

Optimized synthetic fixture: 2,000 actual Markdown files, exactly 20,000 bytes each (40,000,000 total bytes), varied words per file and within each file. The runner invokes `LibraryScanner.scan`, retains its result, and runs the public full-text query API. Every scan checks the file count, truncation, failures and skipped items. Every query checks its expected match count and checks that requested snippets are populated. Fixture generation is outside both timed regions. Temporary input directories are removed by the runner.

Five fresh processes per side, strictly alternating before/after. Before uses the index/search implementation from `b5431a4`; after removes the duplicate snippet text and body-word dictionary. Both use Swift 6.4.2 release core objects and `swiftc -O -whole-module-optimization`, targeting arm64 macOS 14. The same fixture runner is linked to each side. This controller has 14 logical CPUs; initial load average was about 5. Background desktop, indexing and backup processes were active, and a full test run overlapped early pairs. Interleaving limits drift but these are synthetic workstation measurements, not a production latency guarantee.

Values are medians with min to max in parentheses. Footprint is the increase in `TASK_VM_INFO.phys_footprint` from immediately before the scan to after the scan returns, with parse temporaries released. It includes retained index data, metadata and allocator pages; it is not a count of just String buffers.

| Measurement | Before | After |
| --- | ---: | ---: |
| Post-scan footprint increase, MiB | 359.8 (359.8 to 359.9) | 137.1 (136.9 to 137.2) |
| Scan and index, ms | 10366.6 (10089.4 to 11950.9) | 9432.1 (9290.2 to 9944.0) |
| Query `needle`, snippets false, ms | 814.9 (778.1 to 1017.3) | 651.3 (645.2 to 734.9) |
| Query `needle`, snippets true, ms | 815.9 (801.1 to 1012.6) | 674.7 (672.1 to 694.4) |
| Query `cafe needle`, snippets false, ms | 1616.1 (1571.1 to 1652.9) | 1304.5 (1300.9 to 1351.2) |
| Query `cafe needle`, snippets true, ms | 1608.7 (1604.6 to 1738.1) | 1322.6 (1317.5 to 1368.9) |
| Query `word1999x100`, snippets false, ms | 961.8 (937.1 to 1128.6) | 947.9 (937.3 to 965.0) |
| Query `word1999x100`, snippets true, ms | 967.5 (947.6 to 1023.5) | 953.4 (942.4 to 975.0) |
| Query `absentterm`, snippets false, ms | 637.9 (634.4 to 685.4) | 639.2 (632.9 to 643.5) |
| Query `absentterm`, snippets true, ms | 646.6 (636.2 to 663.7) | 635.2 (630.1 to 648.8) |

Footprint fell about 62%. The all-match `needle` query without snippets improved about 20%. The absent and one-file queries show no meaningful improvement. Full-library substring scanning still limits those queries. Separate unreported `sample <pid> 3` runs found the hot path in `LibrarySearch.fullTextMatches` under Foundation `StringProtocol.range` and `contains`, consistent with that limit. The corpus fits local memory, requests are synchronous, all 2,000 scan results and expected query matches are consumed, and no errors or cancellations are included in timings.

`results.jsonl` contains every measured run. `report.html` charts the two main measurements. This is the complete index/query path, including requested snippets, rather than a helper microbenchmark. It excludes AppKit UI presentation.

To build the runner on each revision:

```sh
python3 Tests/Fixtures/WaferCore/Benchmarks/library-index.py /tmp/wafer-index-before
# After applying the index change:
python3 Tests/Fixtures/WaferCore/Benchmarks/library-index.py /tmp/wafer-index-after
```

Run those binaries in alternating fresh processes five times; each prints one JSON record. The build helper supports both SwiftPM native and Swift Build output layouts. The initial standalone compilation needed that layout adjustment; its failed compilation is excluded from measurements.

To check missing-resource degradation with the release core, put the binary in a directory without a Wafer resource bundle:

```sh
mkdir -p /tmp/wafer-missing-resources
python3 Tests/Fixtures/WaferCore/Benchmarks/library-index.py /tmp/wafer-missing-resources/check Tests/Fixtures/WaferCore/Benchmarks/missing-resources.swift
/tmp/wafer-missing-resources/check
```
