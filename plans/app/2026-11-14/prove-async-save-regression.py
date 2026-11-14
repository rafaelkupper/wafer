#!/usr/bin/env python3
"""Run the unchanged explicit-save regression against the stream's base commit."""
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[3]
BASE = "0bba9cd7af5bd480646fb1993c0f3ece92ee952f"
test = (ROOT / "Tests/WaferAppTests/AsyncSaveFlushTests.swift").read_text()
# Keep the fixture, unchanged explicit-save test, and controlled writer only.
regression = test[:test.index("    func testNavigationWaitsForWrite")]
regression += "}\n\n" + test[test.index("private final class ControlledSaveWriter"):]
# The baseline adapter only lets the final cleanup use the new completion
# spelling. The saveEdits responsiveness action and assertions are unchanged.
regression += """
@MainActor
extension MarkdownReaderDocument {
    func flushEdits(interactive: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        completion(flushEdits(interactive: interactive))
    }
}
"""
archive = subprocess.check_output(["git", "archive", BASE], cwd=ROOT)
log = Path(tempfile.gettempdir()) / "wafer-stream-s-baseline.log"
with tempfile.TemporaryDirectory(prefix="wafer-save-baseline-") as directory:
    baseline = Path(directory)
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        tar.extractall(baseline, filter="data")
    (baseline / "Tests/WaferAppTests/AsyncSaveFlushTests.swift").write_text(regression)
    with log.open("w") as output:
        result = subprocess.run(
            ["swift", "test", "--filter", "AsyncSaveFlushTests/testExplicitSaveReturnsBeforeWriterReleased"],
            cwd=baseline, stdout=output, stderr=subprocess.STDOUT,
        )
output = log.read_text()
assert result.returncode != 0, "Baseline unexpectedly passed"
assert "The save action must return while the disk writer is blocked" in output, output[-8000:]
print(f"Baseline {BASE}: regression failed as expected; swift test exit {result.returncode}")
for line in output.splitlines():
    if "error: -[WaferAppTests.AsyncSaveFlushTests" in line or "Executed 1 test" in line:
        print(line)
print(f"Full log: {log}")
