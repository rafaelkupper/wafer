#!/usr/bin/env python3
"""Run optimized, disposable core and AppKit performance fixtures. No installation."""
import pathlib
import platform
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
subprocess.run(["swift", "build", "-c", "release"], cwd=root, check=True)
build = pathlib.Path(subprocess.check_output(["swift", "build", "-c", "release", "--show-bin-path"], cwd=root, text=True).strip())
objects = [line for line in (build / "Wafer.product/Objects.LinkFileList").read_text().splitlines() if "/WaferApp.build/" not in line]
flags = ["swiftc", "-O", "-whole-module-optimization", "-swift-version", "6", "-target", f"{platform.machine()}-apple-macosx14.0", "-I", str(build / "Modules")]
for path in ["swift-cmark/src/include", "swift-cmark/extensions/include", "swift-markdown/Sources/CAtomic/include"]:
    flags += ["-I", str(root / ".build/checkouts" / path)]
with tempfile.TemporaryDirectory(prefix="wafer-performance-") as temporary:
    output = pathlib.Path(temporary)
    (output / "Wafer_WaferCore.bundle").symlink_to(build / "Wafer_WaferCore.bundle")
    subprocess.run(flags + [str(root / "scripts/benchmarks/core.swift")] + objects + ["-o", str(output / "core")], check=True)
    subprocess.run([str(output / "core")], check=True)
    sources = sorted(str(path) for path in (root / "Sources/WaferApp").glob("*.swift") if path.name != "main.swift")
    sources += [str(build / "WaferApp.build/DerivedSources/resource_bundle_accessor.swift"), str(root / "scripts/benchmarks/sidebar.swift")]
    subprocess.run(flags + ["-parse-as-library", "-module-name", "WaferPerformance"] + sources + objects + ["-o", str(output / "sidebar")], check=True)
    subprocess.run([str(output / "sidebar"), temporary], check=True)
