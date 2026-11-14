#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
cd "$ROOT_DIR"

CONFIGURATION=debug
for option in "$@"; do
  case "$option" in
    --perf) export WAFER_PERF_TESTS=1 ;;
    --release) CONFIGURATION=release ;;
    *) print -u2 -- "Usage: scripts/check.sh [--perf] [--release]"; exit 1 ;;
  esac
done

command -v node >/dev/null 2>&1 || { print -u2 -- "error: Node.js 22 or newer is required for JavaScript tests; install node and add it to PATH."; exit 1; }
node -e 'if (Number(process.versions.node.split(".")[0]) < 22) { console.error("error: Node.js 22 or newer is required; found " + process.versions.node); process.exit(1); }'

python3 scripts/verify-vendored-assets.py
if [[ "$CONFIGURATION" == release ]]; then
  WAFER_RELEASE_TESTS=1 swift test -c release
else
  swift test
fi
python3 -m unittest discover -s Tests/ReleaseTools -v
for test in Tests/JavaScript/*/*.cjs; do
  node "$test"
done
