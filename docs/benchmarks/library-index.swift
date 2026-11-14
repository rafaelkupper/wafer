import Darwin
import Foundation
import WaferCore

func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    precondition(result == KERN_SUCCESS)
    return info.phys_footprint
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("wafer-index-benchmark-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let fileCount = 2_000
let byteCount = 20_000
// Vary words within each file as well as between files. No shared full-text buffers.
for index in 0..<fileCount {
    var source = "# Note \(index)\n\nNeedle Café needle\n\n"
    var word = 0
    while source.utf8.count < byteCount {
        source += "word\(index)x\(word) "
        word += 1
    }
    source = String(source.prefix(byteCount))
    // Non-ASCII header changes the character/byte count; pad to exactly 20 KB.
    var data = Data(source.utf8.prefix(byteCount))
    while data.count < byteCount { data.append(32) }
    try data.write(to: root.appendingPathComponent("Note\(index).md"))
}
// Warm parsing and allocation machinery without retaining indexed fixture text.
autoreleasepool { _ = MarkdownParser().parse(source: "# Warmup\n\nneedle", baseURL: nil) }
let before = footprint()
let start = CFAbsoluteTimeGetCurrent()
let scan = autoreleasepool { LibraryScanner.scan(rootURL: root) }
let scanMS = (CFAbsoluteTimeGetCurrent() - start) * 1_000
precondition(scan.files.count == fileCount && scan.failure == nil && scan.skippedItemCount == 0 && !scan.truncated)
let retained = footprint() - before
let recoveryStart = CFAbsoluteTimeGetCurrent()
let recovery = autoreleasepool { LibraryScanner.scan(rootURL: root, existingFiles: scan.files, changedPaths: nil) }
let recoveryMS = (CFAbsoluteTimeGetCurrent() - recoveryStart) * 1_000
precondition(recovery.files == scan.files && recovery.failure == nil && recovery.skippedItemCount == 0 && !recovery.truncated)
let queries = ["needle", "word1999x100", "absentterm", "cafe needle"]
var times: [String: Double] = [:]
var counts: [String: Int] = [:]
for snippets in [false, true] {
    for query in queries {
        let start = CFAbsoluteTimeGetCurrent()
        let matches = autoreleasepool { LibrarySearch.fullTextMatches(query: query, in: scan.files, includesSnippets: snippets) }
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000
        let expected = query == "absentterm" ? 0 : (query == "word1999x100" ? 1 : fileCount)
        precondition(matches.count == expected, "incorrect results for \(query)")
        if snippets && !matches.isEmpty { precondition(!matches[0].snippet.isEmpty) }
        let key = "\(query);snippets=\(snippets)"
        times[key] = elapsed
        counts[key] = matches.count
    }
}
let output: [String: Any] = ["files": scan.files.count, "source_bytes": fileCount * byteCount,
    "scan_ms": scanMS, "recovery_ms": recoveryMS, "parsed_files": scan.parsedFileCount,
    "recovery_parsed_files": recovery.parsedFileCount,
    "retained_footprint_bytes": retained, "query_ms": times, "match_counts": counts]
let json = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))
withExtendedLifetime(scan) {}
