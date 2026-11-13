#!/bin/zsh
set -euo pipefail
setopt NULL_GLOB

ROOT_DIR=${0:A:h:h}
# Bundle name only; the Quick Look appex keeps its SwiftPM product name.
APP_NAME=Wafer
QUICKLOOK_NAME=WaferQuickLook
APP_BUNDLE=${1:-"$ROOT_DIR/build/$APP_NAME.app"}
QUICKLOOK_APPEX="$APP_BUNDLE/Contents/PlugIns/$QUICKLOOK_NAME.appex"
INFO_PLIST="$QUICKLOOK_APPEX/Contents/Info.plist"
EXECUTABLE="$QUICKLOOK_APPEX/Contents/MacOS/$QUICKLOOK_NAME"
CORE_RESOURCE_BUNDLE="$QUICKLOOK_APPEX/Contents/Resources/Wafer_WaferCore.bundle"
# SwiftPM 6.4+ emits resource bundles in the macOS layout (Contents/Resources);
# earlier toolchains emitted them flat. Runtime lookup uses Bundle APIs, which
# accept both.
if [[ -d "$CORE_RESOURCE_BUNDLE/Contents/Resources" ]]; then
  CORE_RESOURCE_BUNDLE="$CORE_RESOURCE_BUNDLE/Contents/Resources"
fi

fail() {
  print -u2 -- "error: $*"
  exit 1
}

require_plist_value() {
  local key expected actual
  key=$1
  expected=$2
  actual=$(/usr/libexec/PlistBuddy -c "Print $key" "$INFO_PLIST" 2>/dev/null) || fail "missing Quick Look plist key: $key"
  [[ "$actual" == "$expected" ]] || fail "Quick Look plist key $key was '$actual', expected '$expected'."
}

[[ -d "$APP_BUNDLE" ]] || fail "app bundle not found: $APP_BUNDLE"
[[ -d "$QUICKLOOK_APPEX" ]] || fail "Quick Look extension bundle not found: $QUICKLOOK_APPEX"
[[ -f "$INFO_PLIST" ]] || fail "Quick Look Info.plist not found: $INFO_PLIST"
[[ -x "$EXECUTABLE" ]] || fail "Quick Look executable not found or not executable: $EXECUTABLE"
[[ -f "$CORE_RESOURCE_BUNDLE/reader-theme.css" ]] || fail "Quick Look extension is missing WaferCore resources: $CORE_RESOURCE_BUNDLE"
[[ -f "$CORE_RESOURCE_BUNDLE/gemoji-shortcodes.json" ]] || fail "Quick Look extension is missing Gemoji shortcode data: $CORE_RESOURCE_BUNDLE"
[[ -f "$CORE_RESOURCE_BUNDLE/gemoji-LICENSE.txt" ]] || fail "Quick Look extension is missing Gemoji license: $CORE_RESOURCE_BUNDLE"
unused_resources=("$CORE_RESOURCE_BUNDLE"/mermaid* "$CORE_RESOURCE_BUNDLE"/katex* "$CORE_RESOURCE_BUNDLE"/KaTeX_*)
(( ${#unused_resources} == 0 )) || fail "Quick Look extension contains unused Mermaid or KaTeX resources: $unused_resources"

plutil -lint "$INFO_PLIST" >/dev/null
require_plist_value ":CFBundleExecutable" "$QUICKLOOK_NAME"
require_plist_value ":CFBundleIdentifier" "dev.wafer.app.quicklook"
require_plist_value ":CFBundlePackageType" "XPC!"
require_plist_value ":NSExtension:NSExtensionPointIdentifier" "com.apple.quicklook.preview"
require_plist_value ":NSExtension:NSExtensionPrincipalClass" "PreviewProvider"

data_based=$(/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionAttributes:QLIsDataBasedPreview" "$INFO_PLIST" 2>/dev/null || true)
[[ -z "$data_based" || "$data_based" == "false" ]] || fail "Quick Look extension must be view-based (QLIsDataBasedPreview must be absent or false)."

linked_libraries=$(otool -L "$EXECUTABLE") || fail "could not read Quick Look executable linkage: $EXECUTABLE"
[[ "$linked_libraries" == *"/QuickLookUI.framework/"* ]] || fail "Quick Look executable does not link QuickLookUI."
[[ "$linked_libraries" != *"/WebKit.framework/"* ]] || fail "Quick Look executable must not link WebKit; previews are native and scriptless."

codesign --verify --strict --verbose=2 "$QUICKLOOK_APPEX" >/dev/null

entitlements_plist=$(mktemp "${TMPDIR:-/tmp}/wafer-appex-entitlements.XXXXXX.plist")
trap 'rm -f "$entitlements_plist"' EXIT
codesign -d --entitlements :- "$QUICKLOOK_APPEX" > "$entitlements_plist" 2>/dev/null
sandbox=$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$entitlements_plist" 2>/dev/null || true)
[[ "$sandbox" == "true" ]] || fail "Quick Look extension is missing com.apple.security.app-sandbox=true."
network_client=$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.network.client" "$entitlements_plist" 2>/dev/null || true)
[[ -z "$network_client" ]] || fail "Quick Look extension must not request com.apple.security.network.client for static previews."

print -- "Verified Quick Look extension: $QUICKLOOK_APPEX"
