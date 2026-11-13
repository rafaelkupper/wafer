#!/usr/bin/env python3
"""Verify the recorded Mermaid and KaTeX assets without network access."""
import hashlib
import json
from pathlib import Path


def verify(root):
    assets = json.loads((root / "docs/vendored-assets.json").read_text())["assets"]
    resources = root / "Sources/WaferCore/Resources"
    expected = {"Sources/WaferCore/Resources/mermaid.min.js",
                "Sources/WaferCore/Resources/mermaid-LICENSE.txt"}
    expected.update(str(p.relative_to(root)) for p in (resources / "katex").rglob("*") if p.is_file())
    recorded = [asset["path"] for asset in assets]
    if len(set(recorded)) != len(recorded) or set(recorded) != expected:
        raise SystemExit("Vendored asset inventory differs from docs/vendored-assets.json")
    for asset in assets:
        if not asset["version"] or not asset["url"].startswith("https://"):
            raise SystemExit(f"Missing vendored asset provenance: {asset['path']}")
        path = root / asset["path"]
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != asset["sha256"]:
            raise SystemExit(f"Vendored asset checksum mismatch: {asset['path']}")
    print(f"Verified {len(assets)} vendored Mermaid and KaTeX assets")


if __name__ == "__main__":
    verify(Path(__file__).resolve().parent.parent)
