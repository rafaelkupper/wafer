#!/bin/zsh
set -euo pipefail
setopt NULL_GLOB

ROOT_DIR=${0:A:h:h}
APP_NAME=Wafer
QUICKLOOK_NAME=WaferQuickLook
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
BUILD_SCRIPT="$ROOT_DIR/scripts/build-app.sh"
VERIFY_APPEX_SCRIPT="$ROOT_DIR/scripts/verify-appex.sh"
# scripts/release.py points this at dist/updates/<version>-<build>.
DIST_DIR=${WAFER_DIST_DIR:-"$ROOT_DIR/dist"}
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
QUICKLOOK_APPEX="$APP_BUNDLE/Contents/PlugIns/$QUICKLOOK_NAME.appex"
QUICKLOOK_ENTITLEMENTS="$ROOT_DIR/App/QuickLook.entitlements"
SPARKLE_VERSION_DIR="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"

SIGN_IDENTITY=${WAFER_SIGN_IDENTITY:-}
NOTARY_PROFILE=${WAFER_NOTARY_PROFILE:-}
SKIP_TESTS=${WAFER_SKIP_TESTS:-0}
SKIP_NOTARIZATION=${WAFER_SKIP_NOTARIZATION:-0}
NOTARY_TIMEOUT=${WAFER_NOTARY_TIMEOUT:-1h}
NOTARY_ARGS=()

fail() {
  print -u2 -- "error: $*"
  exit 1
}

step() {
  print -- "==> $*"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is required but was not found on PATH."
}

detect_sign_identity() {
  local output identities
  output=$(security find-identity -v -p codesigning)
  identities=("${(@f)$(print -- "$output" | sed -n 's/.*"\(Developer ID Application: .*\)".*/\1/p')}")

  case ${#identities[@]} in
    0)
      fail "no Developer ID Application signing identity was found in the keychain."
      ;;
    1)
      print -- "$identities[1]"
      ;;
    *)
      print -u2 -- "$output"
      fail "multiple Developer ID Application identities were found. Set WAFER_SIGN_IDENTITY explicitly."
      ;;
  esac
}

notary_credentials_args() {
  if [[ -n "$NOTARY_PROFILE" ]]; then
    print -r -- "--keychain-profile"
    print -r -- "$NOTARY_PROFILE"
    return
  fi

  if [[ -n "${WAFER_NOTARY_KEY:-}" && -n "${WAFER_NOTARY_KEY_ID:-}" ]]; then
    print -r -- "--key"
    print -r -- "$WAFER_NOTARY_KEY"
    print -r -- "--key-id"
    print -r -- "$WAFER_NOTARY_KEY_ID"

    if [[ -n "${WAFER_NOTARY_ISSUER:-}" ]]; then
      print -r -- "--issuer"
      print -r -- "$WAFER_NOTARY_ISSUER"
    fi

    return
  fi

  if [[ -n "${WAFER_APPLE_ID:-}" && -n "${WAFER_APP_PASSWORD:-}" && -n "${WAFER_TEAM_ID:-}" ]]; then
    print -r -- "--apple-id"
    print -r -- "$WAFER_APPLE_ID"
    print -r -- "--password"
    print -r -- "$WAFER_APP_PASSWORD"
    print -r -- "--team-id"
    print -r -- "$WAFER_TEAM_ID"
    return
  fi

  return 1
}

# Resolve symlinks before deciding whether this is a dedicated output directory.
DIST_DIR=${DIST_DIR:A}
if [[ "$DIST_DIR" != "$ROOT_DIR/dist" && "$DIST_DIR" != "$ROOT_DIR/dist/"* ]]; then
  if [[ -e "$DIST_DIR" ]]; then
    [[ -d "$DIST_DIR" ]] || fail "DIST_DIR is not a directory: $DIST_DIR"
    entries=("$DIST_DIR"/* "$DIST_DIR"/.[!.]* "$DIST_DIR"/..?*)
    (( ${#entries} == 0 )) || fail "DIST_DIR outside $ROOT_DIR/dist must be new or empty: $DIST_DIR"
  fi
fi

require_tool swift
require_tool security
require_tool codesign
require_tool ditto
require_tool plutil
require_tool xcrun

if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  step "Using developer directory: $DEVELOPER_DIR"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY=$(detect_sign_identity)
fi

step "Using signing identity: $SIGN_IDENTITY"

if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
  NOTARY_ARGS=("${(@f)$(notary_credentials_args)}") || fail "notarization credentials are missing. Set WAFER_NOTARY_PROFILE to a notarytool keychain profile, or provide App Store Connect/API key environment variables."
fi

if [[ "$SKIP_TESTS" != "1" ]]; then
  step "Running tests"
  swift test
fi

step "Building release app bundle"
"$BUILD_SCRIPT" release

[[ -d "$APP_BUNDLE" ]] || fail "expected app bundle was not built: $APP_BUNDLE"
[[ -f "$INFO_PLIST" ]] || fail "expected Info.plist was not found: $INFO_PLIST"
[[ -d "$QUICKLOOK_APPEX" ]] || fail "expected Quick Look extension was not built: $QUICKLOOK_APPEX"
[[ -f "$QUICKLOOK_ENTITLEMENTS" ]] || fail "expected Quick Look entitlements were not found: $QUICKLOOK_ENTITLEMENTS"
[[ -f "$SPARKLE_VERSION_DIR/Sparkle" ]] || fail "expected Sparkle framework was not embedded: $SPARKLE_VERSION_DIR"

VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")
BUILD_NUMBER=$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")
RELEASE_NAME="$APP_NAME-$VERSION"
NOTARIZATION_ZIP="$DIST_DIR/$RELEASE_NAME-notarization.zip"
FINAL_ZIP="$DIST_DIR/$RELEASE_NAME.zip"
NOTARY_RESULT="$DIST_DIR/notarytool-submit.json"

# Remove only packaging outputs. Preserve review directories and unrelated files.
mkdir -p "$DIST_DIR"
find "$DIST_DIR" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) \
  \( -name 'Wafer-*.zip' -o -name 'notarytool-submit.json' -o -name 'notarytool-log.json' \) -delete

# Sparkle's helpers are signed one by one, inside out, as its documentation
# prescribes. --deep would stamp one set of entitlements on all of them.
step "Signing Sparkle"
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
codesign --force --timestamp --options runtime --preserve-metadata=entitlements --sign "$SIGN_IDENTITY" "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$SPARKLE_VERSION_DIR/Autoupdate"
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$SPARKLE_VERSION_DIR/Updater.app"
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

step "Signing Quick Look extension"
codesign --force --timestamp --options runtime --entitlements "$QUICKLOOK_ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$QUICKLOOK_APPEX"
"$VERIFY_APPEX_SCRIPT" "$APP_BUNDLE"

step "Signing $APP_NAME $VERSION ($BUILD_NUMBER)"
codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$APP_BUNDLE"

step "Verifying code signature"
"$VERIFY_APPEX_SCRIPT" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign --display --verbose=4 "$APP_BUNDLE"

step "Creating notarization archive"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP_BUNDLE" "$NOTARIZATION_ZIP"

if [[ "$SKIP_NOTARIZATION" == "1" ]]; then
  step "Skipping notarization because WAFER_SKIP_NOTARIZATION=1"
else
  step "Submitting notarization archive"
  if ! xcrun notarytool submit "${NOTARY_ARGS[@]}" --wait --timeout "$NOTARY_TIMEOUT" --output-format json "$NOTARIZATION_ZIP" > "$NOTARY_RESULT"; then
    SUBMISSION_ID=$(plutil -extract id raw -o - "$NOTARY_RESULT" 2>/dev/null || true)
    if [[ -n "$SUBMISSION_ID" ]]; then
      xcrun notarytool log "${NOTARY_ARGS[@]}" "$SUBMISSION_ID" "$DIST_DIR/notarytool-log.json" || true
      print -u2 -- "Notarization failed. See $NOTARY_RESULT and $DIST_DIR/notarytool-log.json."
    else
      print -u2 -- "Notarization failed before a submission id was returned. See $NOTARY_RESULT."
    fi
    exit 1
  fi

  NOTARY_STATUS=$(plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null || true)
  [[ "$NOTARY_STATUS" == "Accepted" ]] || fail "notarization finished with status '$NOTARY_STATUS'. See $NOTARY_RESULT."

  step "Stapling notarization ticket"
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
fi

step "Creating final distribution zip"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$APP_BUNDLE" "$FINAL_ZIP"

step "Verifying final app"
"$VERIFY_APPEX_SCRIPT" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
  spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
fi

# Verify what the ZIP extracts to, not just the bundle on disk: Finder-style
# extraction breaks the code seal on AppleDouble (._*) entries and on file
# names whose Unicode normalization differs from the sealed form.
step "Verifying final zip as extracted"
if unzip -l "$FINAL_ZIP" | grep -q "/\._"; then
  fail "final zip contains AppleDouble (._*) entries"
fi
if unzip -l "$FINAL_ZIP" | LC_ALL=C grep -q $'[\x80-\xff]'; then
  fail "final zip contains non-ASCII file names"
fi
EXTRACT_DIR=$(mktemp -d)
trap 'rm -rf "$EXTRACT_DIR"' EXIT
unzip -qq "$FINAL_ZIP" -d "$EXTRACT_DIR"
codesign --verify --deep --strict "$EXTRACT_DIR/$APP_NAME.app" || fail "extracted app fails signature verification"
if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
  spctl --assess --type execute "$EXTRACT_DIR/$APP_NAME.app" || fail "extracted app fails Gatekeeper assessment"
fi

print -- ""
print -- "Release zip: $FINAL_ZIP"
print -- "Notarization archive: $NOTARIZATION_ZIP"
