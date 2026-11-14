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
SMOKE_APP="$WORK_DIR/Wafer Smoke.app"
# Marks a work directory this script created; clean deletes only such a directory.
MARKER="$WORK_DIR/.wafer-sandbox-smoke"
DOCS_DIR="$WORK_DIR/Documents"
CONTAINER="$HOME/Library/Containers/$SMOKE_ID"
FIXTURE_PREFERENCES="$HOME/Library/Preferences/$SMOKE_ID.plist"
FIXTURE_SUPPORT="$HOME/Library/Application Support/WaferSmokeFixture"
LSREGISTER=${WAFER_LSREGISTER:-"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"}

fail() {
  print -u2 -- "error: $*"
  exit 1
}

# The clean step deletes this identifier's container contents: never the
# app's, the Quick Look extension's, or anything that is not a smoke copy.
[[ "$SMOKE_ID" == *smoke* && "$SMOKE_ID" != dev.wafer.app && "$SMOKE_ID" != dev.wafer.app.quicklook ]] ||
  fail "WAFER_SMOKE_BUNDLE_ID must be a separate identifier containing 'smoke', not '$SMOKE_ID'"

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
  if [[ -e "$WORK_DIR" && ! -e "$MARKER" ]]; then
    entries=("$WORK_DIR"/* "$WORK_DIR"/.[!.]*)
    (( ${#entries} == 0 )) || fail "WAFER_SMOKE_DIR must be new, empty, or made by this script: $WORK_DIR"
  fi
  ! pgrep -f "$SMOKE_APP/Contents/MacOS/" >/dev/null || fail "quit Wafer Smoke before preparing it again"
  mkdir -p "$WORK_DIR"
  : > "$MARKER"
  rm -rf "$SMOKE_APP" "$DOCS_DIR"
  ditto "$SOURCE_APP" "$SMOKE_APP"
  # Keep Finder's Quick Look previews on the real app.
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
  cat > "$SMOKE_APP/Contents/Resources/container-migration.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Move</key>
	<array>
		<string>${Library}/Preferences/${BundleId}.plist</string>
		<array>
			<string>${ApplicationSupport}/WaferSmokeFixture</string>
			<string>${ApplicationSupport}/Wafer</string>
		</array>
	</array>
</dict>
</plist>
PLIST
  sed "s/dev\\.wafer\\.app-sp/$SMOKE_ID-sp/g" "$ROOT_DIR/App/Wafer.entitlements" > "$WORK_DIR/Smoke.entitlements"
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

  if [[ -d "$CONTAINER" ]]; then
    print -- "note: $CONTAINER exists, so this launch will not migrate the fixtures."
  else
    # Saved as an unsandboxed install would have saved them.
    defaults write "$SMOKE_ID" appearanceSelection -string "custom:Smoke Fixture"
    defaults write "$SMOKE_ID" documentStatisticKind -string lines
    defaults write "$SMOKE_ID" libraryFolderPath -string "$DOCS_DIR/Library"
    defaults write "$SMOKE_ID" SUEnableAutomaticChecks -bool false
    mkdir -p "$FIXTURE_SUPPORT/Themes"
    python3 -I - "$SOURCE_APP" "$FIXTURE_SUPPORT/Themes/Smoke Fixture.json" <<'PY'
import json, sys
from pathlib import Path
themes = next(Path(sys.argv[1]).glob('Contents/Resources/Wafer_WaferApp.bundle/**/Themes'))
theme = json.loads((themes / 'Dracula.json').read_text())
theme['name'] = 'Smoke Fixture'
Path(sys.argv[2]).write_text(json.dumps(theme, indent=2))
PY
  fi
  print -- "Prepared $SMOKE_APP ($SMOKE_ID) with fixtures in $DOCS_DIR"
}

open_app() {
  [[ -d "$SMOKE_APP" ]] || fail "run 'scripts/sandbox-smoke.sh prepare' first"
  date '+%Y-%m-%d %H:%M:%S' > "$WORK_DIR/started-at"
  if (( $# )); then
    open -a "$SMOKE_APP" "$@"
  else
    open -a "$SMOKE_APP" "$DOCS_DIR/Notes/Plan.md"
  fi
  local pid=
  for _ in {1..50}; do
    pid=$(pgrep -f "$SMOKE_APP/Contents/MacOS/" | head -1 || true)
    [[ -n "$pid" ]] && break
    sleep 0.2
  done
  [[ -n "$pid" ]] || fail "the smoke app did not start"
  print -- "$pid" > "$WORK_DIR/pid"
  print -- "Started $SMOKE_ID as process $pid"
}

check() {
  local data="$CONTAINER/Data"
  [[ -d "$data" ]] || fail "no container at $CONTAINER; run 'scripts/sandbox-smoke.sh open' first"
  print -- "Container: $CONTAINER"
  local preferences="$data/Library/Preferences/$SMOKE_ID.plist"
  if [[ -f "$preferences" ]]; then
    print -- "Migrated preferences: appearanceSelection=$(plutil -extract appearanceSelection raw -o - "$preferences" 2>/dev/null || print missing), documentStatisticKind=$(plutil -extract documentStatisticKind raw -o - "$preferences" 2>/dev/null || print missing)"
    print -- "Folder grants: $(plutil -extract folderAccessGrants raw -o - "$preferences" 2>/dev/null || print 0)"
    plutil -p "$preferences" | grep -E '"path" =>' || true
  else
    print -- "No preferences in the container yet."
  fi
  [[ -f "$data/Library/Application Support/Wafer/Themes/Smoke Fixture.json" ]] && print -- "Migrated themes: $(ls "$data/Library/Application Support/Wafer/Themes" | tr '\n' ' ')"
  [[ -e "$FIXTURE_PREFERENCES" ]] && print -- "Fixture preferences are still in ~/Library/Preferences (not migrated)."
  [[ -e "$FIXTURE_SUPPORT" ]] && print -- "Fixture themes are still in ~/Library/Application Support (not migrated)."
  local scroll="$data/Library/Preferences/dev.wafer.scroll-state.plist"
  [[ -f "$scroll" ]] && print -- "Scroll positions saved in the container: $(plutil -p "$scroll" | grep -c 'scroll-state-v2:')"

  local since pid
  since=$(cat "$WORK_DIR/started-at" 2>/dev/null || date -v-10M '+%Y-%m-%d %H:%M:%S')
  pid=$(cat "$WORK_DIR/pid" 2>/dev/null || print 0)
  # sandboxd reports app-sandbox denials under com.apple.sandbox.reporting;
  # the kernel's own reports carry sender "Sandbox". Refused file reads
  # outside the grants are often not reported at all, so Wafer logs the
  # files it refused itself (category "access").
  print -- "\nSandbox violations and Wafer logs for process $pid since $since:"
  /usr/bin/log show --style compact --info --start "$since" \
    --predicate "(subsystem == \"dev.wafer.app\" AND processID == $pid) OR ((sender == \"Sandbox\" OR subsystem == \"com.apple.sandbox.reporting\") AND eventMessage CONTAINS \"($pid)\")" |
    grep -E '^[0-9]{4}-' || true
}

clean() {
  pkill -f "$SMOKE_APP/Contents/MacOS/" 2>/dev/null || true
  [[ -d "$SMOKE_APP" && -x "$LSREGISTER" ]] && "$LSREGISTER" -u "$SMOKE_APP" >/dev/null 2>&1 || true
  if [[ -e "$MARKER" ]]; then
    rm -rf "$WORK_DIR"
  elif [[ -e "$WORK_DIR" ]]; then
    print -u2 -- "warning: leaving $WORK_DIR, which this script did not create"
  fi
  rm -rf "$FIXTURE_SUPPORT" "$HOME/Library/Application Scripts/$SMOKE_ID"
  rm -f "$FIXTURE_PREFERENCES"
  rm -f "$HOME/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/$SMOKE_ID".sfl*
  if [[ -d "$CONTAINER/Data" ]]; then
    rm -rf "$CONTAINER/Data" 2>/dev/null || true
  fi
  if [[ -d "$CONTAINER" ]]; then
    print -- "macOS keeps the emptied container $CONTAINER; delete it in Finder if you no longer need it."
  fi
}

case "${1:-}" in
  prepare) prepare ;;
  open) shift; open_app "$@" ;;
  check) check ;;
  clean) clean ;;
  *) print -u2 -- "Usage: scripts/sandbox-smoke.sh prepare | open [FILE...] | check | clean"; exit 1 ;;
esac
