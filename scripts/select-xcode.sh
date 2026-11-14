#!/bin/zsh
set -euo pipefail

# Print the newest installed Xcode 26 developer directory for CI's DEVELOPER_DIR.
python3 - <<'PY'
import os
import re
import subprocess
from pathlib import Path

candidates = {app / 'Contents/Developer' for app in Path('/Applications').glob('Xcode*.app')}
selected = subprocess.run(['xcode-select', '-p'], capture_output=True, text=True)
if selected.returncode == 0:
    candidates.add(Path(selected.stdout.strip()))

available = []
for directory in sorted(candidates):
    result = subprocess.run(['xcodebuild', '-version'], capture_output=True, text=True,
                            env=dict(os.environ, DEVELOPER_DIR=str(directory)))
    match = re.search(r'^Xcode (26(?:\.\d+)*)$', result.stdout, re.MULTILINE)
    if result.returncode == 0 and match:
        swift = subprocess.run(['xcrun', 'swift', '--version'], capture_output=True, text=True,
                               env=dict(os.environ, DEVELOPER_DIR=str(directory)))
        swift_version = re.search(r'Swift version (\d+\.\d+(?:\.\d+)?)', swift.stdout)
        if swift.returncode == 0 and swift_version and tuple(map(int, swift_version[1].split('.'))) >= (6, 2, 3):
            available.append((tuple(map(int, match[1].split('.'))), str(directory)))

if not available:
    raise SystemExit('error: Xcode 26 with Swift 6.2.3 or newer is required. Install it in /Applications '
                     'or select it with xcode-select; no usable Xcode 26 was found.')
print(max(available)[1])
PY
