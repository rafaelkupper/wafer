#!/bin/zsh
# Sandboxed smoke test for a local build; see docs/DEVELOPMENT.md.
#
# Your real dev.wafer.app container and preferences are never touched. The
# app is copied under a separate bundle identifier (without the Quick Look
# extension), signed ad hoc with that identifier's entitlements, and its
# first launch migrates fixture preferences and themes instead of yours.
#
#   scripts/sandbox-smoke.sh prepare         copy, sign, and create fixtures
#   scripts/sandbox-smoke.sh open [FILE...]  launch the copy (fixture Notes/Plan.md by default)
#   scripts/sandbox-smoke.sh check           container, migration, grants, and log checks
#   scripts/sandbox-smoke.sh clean           quit and remove what the smoke test created
set -euo pipefail
setopt NULL_GLOB

ROOT_DIR=${0:A:h:h}
SOURCE_APP=${WAFER_SMOKE_APP:-"$ROOT_DIR/build/Wafer.app"}
SMOKE_ID=${WAFER_SMOKE_BUNDLE_ID:-dev.wafer.app.sandbox-smoke}
WORK_DIR=${WAFER_SMOKE_DIR:-/tmp/wafer-sandbox-smoke}
WORK_DIR=${WORK_DIR:A}
SMOKE_APP="$WORK_DIR/Wafer Smoke.app"
# Marks a work directory this script created; clean deletes only such a directory.
MARKER="$WORK_DIR/.wafer-sandbox-smoke"
DOCS_DIR="$WORK_DIR/Documents"
CONTAINER="$HOME/Library/Containers/$SMOKE_ID"
FIXTURE_PREFERENCES="$HOME/Library/Preferences/$SMOKE_ID.plist"
FIXTURE_SUPPORT="$HOME/Library/Application Support/WaferSmokeFixture-$SMOKE_ID"
FIXTURE_SCROLL="$HOME/Library/Preferences/wafer-smoke-scroll-$SMOKE_ID.plist"
EVIDENCE=${WAFER_SMOKE_EVIDENCE:-"$ROOT_DIR/build/sandbox-smoke-evidence/$SMOKE_ID"}
LSREGISTER=${WAFER_LSREGISTER:-"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"}

fail() {
  print -u2 -- "error: $*"
  exit 1
}

[[ "$SMOKE_ID" == dev.wafer.app.*smoke* && "$SMOKE_ID" != *[^a-zA-Z0-9.-]* ]] ||
  fail "WAFER_SMOKE_BUNDLE_ID must be a separate identifier containing 'smoke', not '$SMOKE_ID'"

owned() {
  [[ -f "$MARKER" && "$(cat "$MARKER")" == "$SMOKE_ID" ]] || fail "no ownership marker for $SMOKE_ID in $WORK_DIR"
}

stop_app() {
  owned
  local pid executable
  pid=$(cat "$WORK_DIR/pid" 2>/dev/null || true)
  if [[ -n "$pid" ]]; then
    executable=$(ps -p "$pid" -o comm= 2>/dev/null || true)
    if [[ "$executable" == "$SMOKE_APP/Contents/MacOS/Wafer" || "$executable" == "$SMOKE_APP/Contents/MacOS/WaferUpdateSmoke" ]]; then
      kill -TERM "$pid"
      for _ in {1..50}; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.2
      done
      fail "smoke process $pid did not terminate"
    fi
  fi
}

write_png() {
  python3 -I - "$1" <<'PY'
import struct, sys, zlib
width = height = 48
rows = b''.join(b'\x00' + bytes((40, 120 + y * 2, 220)) * width for y in range(height))
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')
open(sys.argv[1], 'wb').write(png)
PY
}

prepare() {
  [[ -d "$SOURCE_APP" ]] || fail "build the app first: scripts/build-app.sh release"
  [[ ! -e "$WORK_DIR" && ! -e "$CONTAINER" && ! -e "$FIXTURE_PREFERENCES" && ! -e "$FIXTURE_SCROLL" && ! -e "$FIXTURE_SUPPORT" && ! -e "$HOME/Library/Application Scripts/$SMOKE_ID" ]] ||
    fail "use a fresh work directory and smoke ID; a fixture path already exists: $WORK_DIR"
  mkdir -p "$WORK_DIR" "$EVIDENCE"
  chmod 700 "$WORK_DIR"
  print -r -- "$SMOKE_ID" > "$MARKER"
  ditto "$SOURCE_APP" "$SMOKE_APP"
  # Keep Finder's Quick Look previews on the installed app.
  rm -rf "$SMOKE_APP/Contents/PlugIns"

  local info="$SMOKE_APP/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string "$SMOKE_ID" "$info"
  plutil -replace CFBundleName -string "Wafer Smoke" "$info"
  plutil -replace CFBundleDisplayName -string "Wafer Smoke" "$info"
  # Never become the default Markdown app; leave the exported type to the real app.
  plutil -replace CFBundleDocumentTypes.0.LSHandlerRank -string Alternate "$info"
  plutil -remove UTExportedTypeDeclarations "$info"

  # The shipping manifest moves dev.wafer.app's own files. This one moves the
  # fixtures below into the same places in the smoke container.
  python3 -I - "$SMOKE_APP" "$SMOKE_ID" <<'PYPLIST'
import plistlib, sys
from pathlib import Path
app, identifier = Path(sys.argv[1]), sys.argv[2]
info_path = app / 'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
info.pop('SUFeedURL', None)
info.pop('SUPublicEDKey', None)
info_path.write_bytes(plistlib.dumps(info))
manifest = {'Move': [f'${{Library}}/Preferences/{identifier}.plist',
    [f'${{Library}}/Preferences/wafer-smoke-scroll-{identifier}.plist', '${Library}/Preferences/dev.wafer.scroll-state.plist'],
    [f'${{ApplicationSupport}}/WaferSmokeFixture-{identifier}', '${ApplicationSupport}/Wafer']]}
(app / 'Contents/Resources/container-migration.plist').write_bytes(plistlib.dumps(manifest))
PYPLIST
  sed "s/dev\\.wafer\\.app-sp/$SMOKE_ID-sp/g" "$ROOT_DIR/App/Wafer.entitlements" > "$WORK_DIR/Smoke.entitlements"
  mkdir -p "$WORK_DIR/Access Probe.app/Contents/MacOS"
  cp "$info" "$WORK_DIR/Access Probe.app/Contents/Info.plist"
  plutil -replace CFBundleExecutable -string SmokeAccessProbe "$WORK_DIR/Access Probe.app/Contents/Info.plist"
  xcrun clang -fobjc-arc -framework Foundation "$ROOT_DIR/scripts/sandbox-access-probe.m" -o "$WORK_DIR/Access Probe.app/Contents/MacOS/SmokeAccessProbe"
  codesign --force --sign - --entitlements "$WORK_DIR/Smoke.entitlements" "$WORK_DIR/Access Probe.app"
  codesign --force --sign - --entitlements "$WORK_DIR/Smoke.entitlements" "$SMOKE_APP"

  mkdir -p "$DOCS_DIR/Notes" "$DOCS_DIR/Archive" "$DOCS_DIR/Library/Topics"
  write_png "$DOCS_DIR/Notes/image.png"
  cat > "$DOCS_DIR/Notes/Plan.md" <<'MD'
# Plan

A sibling image, which needs a folder grant:

![Sibling image](image.png)

- [Next note](Next.md) in the same folder
- [Far note](../Archive/Far.md) in another folder

A remote image:

![Remote image](https://www.apple.com/favicon.ico)
MD
  print -- "# Next\n\nBack to [Plan](Plan.md)." > "$DOCS_DIR/Notes/Next.md"
  print -- "# Edit me\n\nOriginal text." > "$DOCS_DIR/Notes/Edit.md"
  print -- "# Far\n\nIn the archive folder." > "$DOCS_DIR/Archive/Far.md"
  print -- "# Guide\n\nSee [[Topic]]." > "$DOCS_DIR/Library/Guide.md"
  print -- "# Topic\n\nA library note." > "$DOCS_DIR/Library/Topics/Topic.md"

  python3 -I - "$SOURCE_APP" "$WORK_DIR" "$FIXTURE_PREFERENCES" "$FIXTURE_SCROLL" "$FIXTURE_SUPPORT" <<'PYSEED'
import datetime, json, plistlib, sys
from pathlib import Path
source, work, preferences, scroll, support = map(Path, sys.argv[1:])
preferences.write_bytes(plistlib.dumps({'appearanceSelection': 'custom:Smoke Fixture',
    'documentStatisticKind': 'lines', 'SUEnableAutomaticChecks': False,
    'libraryFolderPath': str(work / 'Documents/Library')}))
seed = json.dumps({'fingerprint': 'smoke-migration', 'state': {'fraction': 0.375,
    'updatedAt': (datetime.datetime.now(datetime.timezone.utc) - datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)).total_seconds()}}).encode()
(work / 'scroll-seed.json').write_bytes(seed)
scroll.write_bytes(plistlib.dumps({'scroll-state-v2:smoke-migration': seed}))
themes = next(source.glob('Contents/Resources/Wafer_WaferApp.bundle/**/Themes'))
theme = json.loads((themes / 'Dracula.json').read_text())
theme['name'] = 'Smoke Fixture'
(support / 'Themes').mkdir(parents=True)
seed = json.dumps(theme, indent=2).encode()
(support / 'Themes/Smoke Fixture.json').write_bytes(seed)
(work / 'theme-seed.json').write_bytes(seed)
(work / 'seed-paths.json').write_text(json.dumps([str(preferences), str(scroll), str(support)]))
PYSEED
  print -- "Prepared $SMOKE_APP ($SMOKE_ID) with fixtures in $DOCS_DIR"
}

open_app() {
  [[ -d "$SMOKE_APP" ]] || fail "run 'scripts/sandbox-smoke.sh prepare' first"
  owned
  [[ "$(plutil -extract CFBundleIdentifier raw -o - "$SMOKE_APP/Contents/Info.plist")" == "$SMOKE_ID" ]] || fail "smoke app identifier changed; refusing to launch"
  [[ -e "$WORK_DIR/started-at" ]] || date '+%Y-%m-%d %H:%M:%S' > "$WORK_DIR/started-at"
  if (( $# )); then
    open -a "$SMOKE_APP" "$@"
  else
    open -a "$SMOKE_APP" "$DOCS_DIR/Notes/Plan.md"
  fi
  local pid=
  for _ in {1..50}; do
    pid=$(ps -axo pid=,comm= | python3 -I -c 'import sys
expected = sys.argv[1]
for row in sys.stdin:
    fields = row.strip().split(None, 1)
    if len(fields) == 2 and fields[1] == expected:
        print(fields[0]); break' "$SMOKE_APP/Contents/MacOS/Wafer")
    [[ -n "$pid" ]] && break
    sleep 0.2
  done
  [[ -n "$pid" ]] || fail "the smoke app did not start"
  print -- "$pid" > "$WORK_DIR/pid"
  print -- "$pid" >> "$WORK_DIR/pids"
  print -- "Started $SMOKE_ID as process $pid"
}

collect_logs() {
  local since predicate pid
  since=$(cat "$WORK_DIR/started-at")
  predicate=''
  for pid in "${(@f)$(cat "$WORK_DIR/pids")}"; do
    [[ -z "$predicate" ]] || predicate+=' OR '
    predicate+="(subsystem == \"dev.wafer.app\" AND processID == $pid) OR ((sender == \"Sandbox\" OR subsystem == \"com.apple.sandbox.reporting\") AND eventMessage CONTAINS \"($pid)\")"
  done
  /usr/bin/log show --style json --info --debug --start "$since" --predicate "$predicate" > "$EVIDENCE/unified.json" || return 23
}

check() {
  owned
  [[ -d "$CONTAINER/Data" ]] || { print -u2 -- "FAIL phase 20: container not created: $CONTAINER"; return 20; }
  if [[ "${1:-}" != --migration-only ]]; then
    "$WORK_DIR/Access Probe.app/Contents/MacOS/SmokeAccessProbe" "$SMOKE_ID" "$DOCS_DIR/Notes/image.png" > "$EVIDENCE/probe.png" 2> "$EVIDENCE/probe.log" &
    local probe_pid=$!
    print -- "$probe_pid" >> "$WORK_DIR/pids"
    wait "$probe_pid" || {
      collect_logs || return 23
      print -u2 -- "FAIL phase 22: sandboxed bookmark read failed; see $EVIDENCE/probe.log"; return 22
    }
    cmp -s "$EVIDENCE/probe.png" "$DOCS_DIR/Notes/image.png" || { print -u2 -- "FAIL phase 22: bookmark read bytes differ"; return 22; }
  fi
  collect_logs || return 23
  python3 -I "$ROOT_DIR/scripts/sandbox-smoke-check.py" "$WORK_DIR" "$CONTAINER" "$EVIDENCE" "$SMOKE_ID" "$@"
}

relaunch() {
  stop_app
  open_app "$DOCS_DIR/Notes/Plan.md"
  cp "$WORK_DIR/pid" "$WORK_DIR/relaunch-pid"
  sleep 5
}

run() {
  prepare
  # Opening the fixture folder is a user-selection event without a folder panel.
  open_app "$DOCS_DIR"
  # CFPreferences writes asynchronously; wait for the actual bookmark file.
  python3 -I - "$CONTAINER/Data/Library/Preferences/$SMOKE_ID.plist" <<'PYWAIT'
import plistlib, sys, time
from pathlib import Path
p = Path(sys.argv[1])
for _ in range(100):
    try:
        if plistlib.loads(p.read_bytes()).get("folderAccessGrants"):
            break
    except (OSError, ValueError):
        pass
    time.sleep(0.2)
else:
    sys.exit(22)
PYWAIT
  relaunch
  check
}

clean() {
  if [[ ! -f "$MARKER" || "$(cat "$MARKER")" != "$SMOKE_ID" ]]; then
    print -u2 -- "warning: leaving $WORK_DIR and all fixtures/containers, which this script did not create"
    return
  fi
  stop_app
  [[ -d "$SMOKE_APP" && -x "$LSREGISTER" ]] && "$LSREGISTER" -u "$SMOKE_APP" >/dev/null 2>&1 || true
  [[ -d "$EVIDENCE" ]] || mkdir -p "$EVIDENCE"
  rm -rf "$FIXTURE_SUPPORT" "$HOME/Library/Application Scripts/$SMOKE_ID"
  rm -f "$FIXTURE_PREFERENCES" "$FIXTURE_SCROLL"
  rm -f "$HOME/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/$SMOKE_ID".sfl*
  if [[ -d "$CONTAINER" ]]; then
    if ! rm -rf "$CONTAINER" 2> "$EVIDENCE/cleanup.log"; then
      print -u2 -- "macOS refused container deletion: $CONTAINER (see $EVIDENCE/cleanup.log)"
    fi
  fi
  rm -rf "$WORK_DIR"
  print -- "Preserved evidence: $EVIDENCE"
}

case "${1:-}" in
  prepare) prepare ;;
  open) shift; open_app "$@" ;;
  check) shift; check "$@" ;;
  relaunch) relaunch ;;
  stop) stop_app ;;
  run) run ;;
  clean) clean ;;
  *) print -u2 -- "Usage: scripts/sandbox-smoke.sh prepare | open [FILE...] | relaunch | check [--migration-only] | run | stop | clean"; exit 1 ;;
esac
