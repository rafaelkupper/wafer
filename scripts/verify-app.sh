#!/bin/zsh
set -euo pipefail

# Verifies the containing app's signature and sandbox configuration:
# - the signature (and nested code) verifies;
# - the signed entitlements are exactly App/Wafer.entitlements;
# - Sparkle's sandbox keys match the bundle identifier;
# - the container migration manifest is bundled unchanged.
# --distribution also requires a Developer ID signature with the hardened runtime.

ROOT_DIR=${0:A:h:h}
APP_NAME=Wafer
DISTRIBUTION=0
EXPECTED_ID=dev.wafer.app.dev
APP_BUNDLE=
for argument in "$@"; do
  case "$argument" in
    --distribution) DISTRIBUTION=1; EXPECTED_ID=dev.wafer.app ;;
    --release-identity) EXPECTED_ID=dev.wafer.app ;;
    -*) print -u2 -- "Usage: scripts/verify-app.sh [--distribution|--release-identity] [path/to/$APP_NAME.app]"; exit 1 ;;
    *) APP_BUNDLE=$argument ;;
  esac
done
APP_BUNDLE=${APP_BUNDLE:-"$ROOT_DIR/build/$APP_NAME.app"}
EXPECTED_ENTITLEMENTS="$ROOT_DIR/App/$APP_NAME.entitlements"
EXPECTED_MIGRATION="$ROOT_DIR/App/container-migration.plist"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
MIGRATION_PLIST="$APP_BUNDLE/Contents/Resources/container-migration.plist"
SPARKLE_INSTALLER="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"

fail() {
  print -u2 -- "error: $*"
  exit 1
}

[[ -d "$APP_BUNDLE" ]] || fail "app bundle not found: $APP_BUNDLE"
[[ -f "$INFO_PLIST" ]] || fail "app Info.plist not found: $INFO_PLIST"
[[ -d "$SPARKLE_INSTALLER" ]] || fail "Sparkle's Installer.xpc is missing; sandboxed updates need it: $SPARKLE_INSTALLER"
plutil -lint "$INFO_PLIST" >/dev/null || fail "app property lists are malformed"

codesign --verify --deep --strict "$APP_BUNDLE" || fail "app signature does not verify: $APP_BUNDLE"

entitlements_plist=$(mktemp "${TMPDIR:-/tmp}/wafer-app-entitlements.XXXXXX")
trap 'rm -f "$entitlements_plist"' EXIT
codesign -d --entitlements :- "$APP_BUNDLE" > "$entitlements_plist" 2>/dev/null || fail "could not read the app's signed entitlements"

python3 -I - "$entitlements_plist" "$EXPECTED_ENTITLEMENTS" "$INFO_PLIST" "$MIGRATION_PLIST" "$EXPECTED_MIGRATION" "$EXPECTED_ID" <<'PY'
import plistlib
import sys
from pathlib import Path

signed_path, expected_path, info_path, migration_path, expected_migration_path, expected_id = sys.argv[1:]
data = Path(signed_path).read_bytes()
signed = plistlib.loads(data) if data.strip() else {}
expected = plistlib.loads(Path(expected_path).read_bytes())
info = plistlib.loads(Path(info_path).read_bytes())
problems = []
if info.get('CFBundleIdentifier') != expected_id:
    problems.append(f"bundle identifier is {info.get('CFBundleIdentifier')!r}, expected {expected_id!r}")
expected['com.apple.security.temporary-exception.mach-lookup.global-name'] = [f'{expected_id}-spks', f'{expected_id}-spki']

for key in sorted(expected.keys() - signed.keys()):
    problems.append(f'missing entitlement {key}')
for key in sorted(signed.keys() - expected.keys()):
    problems.append(f'unexpected entitlement {key}')
for key in sorted(expected.keys() & signed.keys()):
    if signed[key] != expected[key]:
        problems.append(f'entitlement {key} is {signed[key]!r}, expected {expected[key]!r}')

bundle_id = info.get('CFBundleIdentifier')
lookups = expected.get('com.apple.security.temporary-exception.mach-lookup.global-name')
if lookups != [f'{bundle_id}-spks', f'{bundle_id}-spki']:
    problems.append(f'Sparkle mach-lookup exceptions {lookups!r} do not match the bundle identifier {bundle_id!r}')
if info.get('SUEnableInstallerLauncherService') is not True:
    problems.append('Info.plist must set SUEnableInstallerLauncherService to true for the sandboxed Sparkle installer')
if info.get('SUEnableDownloaderService', False) is not False:
    problems.append('Info.plist must not set SUEnableDownloaderService; the app downloads updates itself with network.client')

if expected_id == 'dev.wafer.app':
    if not Path(migration_path).is_file():
        problems.append('container migration manifest not found: ' + migration_path)
    else:
        migration = plistlib.loads(Path(migration_path).read_bytes())
        if not migration.get('Move'):
            problems.append('container-migration.plist has no Move entries')
        if migration != plistlib.loads(Path(expected_migration_path).read_bytes()):
            problems.append('the bundled container-migration.plist differs from App/container-migration.plist')
else:
    if Path(migration_path).exists():
        problems.append('development app must not carry a container migration manifest')
    if 'SUFeedURL' in info or 'SUPublicEDKey' in info:
        problems.append('development app must not carry the release update feed or key')

for problem in problems:
    print('error: ' + problem, file=sys.stderr)
sys.exit(1 if problems else 0)
PY

if (( DISTRIBUTION )); then
  details=$(codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1) || fail "could not read the app's signature details"
  [[ "$details" == *"Authority=Developer ID Application:"* ]] || fail "app is not signed with a Developer ID Application identity"
  [[ "$details" == *"runtime"* ]] || fail "app is not signed with the hardened runtime"
fi

print -- "Verified app signature and sandbox entitlements: $APP_BUNDLE"
