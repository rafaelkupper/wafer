#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}
cd "$ROOT_DIR"

case "${1:-}" in
  '') ;;
  --perf) export WAFER_PERF_TESTS=1 ;;
  *) print -u2 -- "Usage: scripts/check.sh [--perf]"; exit 1 ;;
esac
(( $# <= 1 )) || { print -u2 -- "Usage: scripts/check.sh [--perf]"; exit 1; }

python3 scripts/verify-vendored-assets.py
swift test
python3 -m unittest discover -s Tests/ReleaseTools -v
for test in Tests/JavaScript/*/*.cjs; do
  node "$test"
done
