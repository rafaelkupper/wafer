#!/bin/zsh
# Offline sandboxed Sparkle installation. No Keychain, publishing or notarization.
set -euo pipefail
ROOT_DIR=${0:A:h:h}
export WAFER_SMOKE_BUNDLE_ID=${WAFER_SMOKE_BUNDLE_ID:-dev.wafer.app.update-smoke-$(date +%Y%m%d%H%M%S)}
export WAFER_SMOKE_DIR=${WAFER_SMOKE_DIR:-/tmp/wafer-update-smoke-$(date +%Y%m%d%H%M%S)}
export WAFER_SMOKE_EVIDENCE=${WAFER_SMOKE_EVIDENCE:-"$ROOT_DIR/build/sandbox-smoke-evidence/$WAFER_SMOKE_BUNDLE_ID"}
WORK=${WAFER_SMOKE_DIR:A}
EVIDENCE=$WAFER_SMOKE_EVIDENCE
APP="$WORK/Wafer Smoke.app"
TOOLS=${WAFER_SPARKLE_TOOLS:-"$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"}
[[ -x "$TOOLS/sign_update" ]] || { print -u2 -- "Build first, or set WAFER_SPARKLE_TOOLS to Sparkle 2.10.1 bin"; exit 1; }
"$ROOT_DIR/scripts/sandbox-smoke.sh" prepare
SERVER_PID=
WATCH_PID=
cleanup() {
  [[ -z "$SERVER_PID" ]] || kill "$SERVER_PID" 2>/dev/null || true
  [[ -z "$WATCH_PID" ]] || kill "$WATCH_PID" 2>/dev/null || true
  rm -f "$WORK/private.pem" "$WORK/private.key" "$WORK/private.der"
  "$ROOT_DIR/scripts/sandbox-smoke.sh" clean
}
trap cleanup EXIT
mkdir "$WORK/feed" "$WORK/target"
# OpenSSL creates a new Ed25519 seed entirely in files. Sparkle accepts the
# base64-encoded raw 32-byte seed, not PEM. Never call generate_keys here.
(umask 077; openssl genpkey -algorithm ed25519 -out "$WORK/private.pem")
openssl pkey -in "$WORK/private.pem" -pubout -outform DER -out "$WORK/public.der"
openssl pkey -in "$WORK/private.pem" -outform DER -out "$WORK/private.der"
python3 -I - "$WORK" <<'PY'
import base64, os, sys
from pathlib import Path
work = Path(sys.argv[1])
(work / 'private.key').write_bytes(base64.b64encode((work / 'private.der').read_bytes()[-32:]))
os.chmod(work / 'private.key', 0o600)
(work / 'public.key').write_bytes(base64.b64encode((work / 'public.der').read_bytes()[-32:]))
(work / 'private.der').unlink()
PY
# Bind only loopback, with an OS-assigned port. Retain every HTTP request.
python3 -u - "$WORK/feed" "$WORK/port" > "$EVIDENCE/http.log" 2>&1 <<'PY' &
import functools, http.server, sys
from pathlib import Path
server = http.server.HTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[1]))
Path(sys.argv[2]).write_text(str(server.server_port))
server.serve_forever()
PY
SERVER_PID=$!
for _ in {1..50}; do [[ -f "$WORK/port" ]] && break; sleep 0.1; done
FEED="http://localhost:$(cat "$WORK/port")/appcast.xml"
python3 -I - "$APP/Contents/Info.plist" "$WORK/public.key" "$FEED" <<'PY'
import plistlib, sys
from pathlib import Path
p = Path(sys.argv[1]); info = plistlib.loads(p.read_bytes())
info.update(SUPublicEDKey=Path(sys.argv[2]).read_text(), SUFeedURL=sys.argv[3],
            CFBundleVersion='900001', CFBundleShortVersionString='0.0.1',
            NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
p.write_bytes(plistlib.dumps(info))
PY
# Archive the second version with Wafer's actual executable. Only the old copy
# uses the driver: production UpdateController deliberately disables auto-download.
ditto "$APP" "$WORK/target/Wafer Smoke.app"
plutil -replace CFBundleVersion -string 900002 "$WORK/target/Wafer Smoke.app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string 0.0.2 "$WORK/target/Wafer Smoke.app/Contents/Info.plist"
codesign --force --sign - --entitlements "$WORK/Smoke.entitlements" "$WORK/target/Wafer Smoke.app"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$WORK/target/Wafer Smoke.app" "$WORK/feed/update.zip"
"$TOOLS/sign_update" --ed-key-file "$WORK/private.key" "$WORK/feed/update.zip" > "$WORK/signature"
python3 -I - "$WORK" "$FEED" <<'PY'
import sys
from pathlib import Path
work = Path(sys.argv[1]); base = sys.argv[2].rsplit('/', 1)[0]
(work / 'feed/appcast.xml').write_text(f'''<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Wafer sandbox smoke</title><item><title>Smoke 2</title><sparkle:version>900002</sparkle:version><sparkle:shortVersionString>0.0.2</sparkle:shortVersionString><enclosure url="{base}/update.zip" type="application/octet-stream" { (work / 'signature').read_text().strip() } /></item></channel></rss>''')
PY
"$TOOLS/sign_update" --ed-key-file "$WORK/private.key" "$WORK/feed/appcast.xml" > "$EVIDENCE/feed-signing.log"
cp "$WORK/feed/appcast.xml" "$WORK/public.key" "$EVIDENCE/"
FRAMEWORKS="$APP/Contents/Frameworks"
xcrun clang -fobjc-arc -framework AppKit -F "$FRAMEWORKS" -framework Sparkle \
  -Wl,-rpath,@executable_path/../Frameworks "$ROOT_DIR/scripts/sandbox-update-driver.m" -o "$APP/Contents/MacOS/WaferUpdateSmoke"
rm "$APP/Contents/MacOS/Wafer"
plutil -replace CFBundleExecutable -string WaferUpdateSmoke "$APP/Contents/Info.plist"
codesign --force --sign - --entitlements "$WORK/Smoke.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
# Observe actual helper processes, rather than treating a version plist edit as proof.
python3 -u - "$WORK" > "$EVIDENCE/processes.log" <<'PY' &
import subprocess, sys, time
for _ in range(1200):
    for row in subprocess.check_output(['/bin/ps', '-axo', 'pid=,command='], text=True).splitlines():
        if sys.argv[1] in row and ('Installer.xpc/' in row or '/Autoupdate' in row):
            print(row, flush=True)
    time.sleep(0.1)
PY
WATCH_PID=$!
date '+%Y-%m-%d %H:%M:%S' > "$WORK/started-at"
"$APP/Contents/MacOS/WaferUpdateSmoke" > "$EVIDENCE/driver.log" 2>&1 &
DRIVER_PID=$!
print -- "$DRIVER_PID" > "$WORK/pid"
for _ in {1..120}; do
  version=$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")
  [[ "$version" == 900002 ]] && break
  if ! kill -0 "$DRIVER_PID" 2>/dev/null; then sleep 2; break; fi
  sleep 1
done
/usr/bin/log show --style compact --info --debug --start "$(cat "$WORK/started-at")" \
  --predicate 'process == "Installer" OR process == "Autoupdate" OR subsystem CONTAINS "sparkle"' > "$EVIDENCE/installer.log"
plutil -p "$APP/Contents/Info.plist" > "$EVIDENCE/installed-info.txt"
[[ "$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")" == 900002 ]] || { cat "$EVIDENCE/driver.log"; exit 35; }
grep -q 'installer ready' "$EVIDENCE/driver.log" || exit 36
grep -q 'Installer.xpc/' "$EVIDENCE/processes.log" || { print -u2 -- "No Installer.xpc process evidence"; exit 37; }
codesign --verify --deep --strict "$APP"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist")" == "$WAFER_SMOKE_BUNDLE_ID" ]] || exit 38
cmp "$APP/Contents/MacOS/Wafer" "$WORK/target/Wafer Smoke.app/Contents/MacOS/Wafer" || exit 39
shasum -a 256 "$APP/Contents/MacOS/Wafer" "$WORK/target/Wafer Smoke.app/Contents/MacOS/Wafer" > "$EVIDENCE/installed-binary.sha256"
codesign -d --entitlements :- "$APP" > "$EVIDENCE/installed-entitlements.plist" 2>/dev/null
print -- "PASS: sandboxed Installer.xpc updated $WAFER_SMOKE_BUNDLE_ID from 900001 to 900002 on quit; evidence: $EVIDENCE"
