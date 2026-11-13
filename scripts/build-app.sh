#!/bin/zsh
set -euo pipefail
setopt NULL_GLOB

ROOT_DIR=${0:A:h:h}
CONFIGURATION=${1:-debug}
MODE=${CONFIGURATION:l}
APP_NAME=Wafer
QUICKLOOK_NAME=WaferQuickLook
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
EXECUTABLE_PATH="$ROOT_DIR/.build/$MODE/$APP_NAME"
QUICKLOOK_EXECUTABLE_PATH="$ROOT_DIR/.build/$MODE/$QUICKLOOK_NAME"
BUILD_PRODUCTS_DIR="$ROOT_DIR/.build/$MODE"
QUICKLOOK_APPEX="$APP_BUNDLE/Contents/PlugIns/$QUICKLOOK_NAME.appex"
LSREGISTER=${WAFER_LSREGISTER:-"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"}

resource_directory() {
  if [[ -d "$1/Contents/Resources" ]]; then
    print -r -- "$1/Contents/Resources"
  else
    print -r -- "$1"
  fi
}

require_resource() {
  [[ -f "$1" ]] || { print -u2 -- "error: missing required resource: $1"; exit 1; }
}

case "$MODE" in
  debug|release) ;;
  *)
    echo "Unsupported configuration: $CONFIGURATION"
    echo "Use 'debug' or 'release'."
    exit 1
    ;;
esac

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift toolchain unavailable. Install Xcode or the Command Line Tools first."
  exit 1
fi

mkdir -p "$ROOT_DIR/build"

# Build the Swift executable that backs the app bundle.
swift build -c "$MODE" --product "$APP_NAME"
swift build -c "$MODE" --product "$QUICKLOOK_NAME"

# Check required bundles before replacing the previous app.
CORE_RESOURCES=$(resource_directory "$BUILD_PRODUCTS_DIR/Wafer_WaferCore.bundle")
for resource in reader-theme.css gemoji-shortcodes.json gemoji-LICENSE.txt \
  mermaid.min.js mermaid-LICENSE.txt katex.min.js katex.min.css katex-LICENSE.txt KaTeX_Main-Regular.woff2; do
  require_resource "$CORE_RESOURCES/$resource"
done
APP_RESOURCES=$(resource_directory "$BUILD_PRODUCTS_DIR/Wafer_WaferApp.bundle")
require_resource "$APP_RESOURCES/Themes/GitHub Light.json"

rm -rf "$APP_BUNDLE"
mkdir -p \
  "$APP_BUNDLE/Contents/MacOS" \
  "$APP_BUNDLE/Contents/Resources" \
  "$QUICKLOOK_APPEX/Contents/MacOS" \
  "$QUICKLOOK_APPEX/Contents/Resources"

# Assemble the minimal macOS app bundle structure.
cp "$ROOT_DIR/App/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$EXECUTABLE_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/App/Resources/$APP_NAME.icns" "$APP_BUNDLE/Contents/Resources/$APP_NAME.icns"
cp "$ROOT_DIR/App/QuickLook-Info.plist" "$QUICKLOOK_APPEX/Contents/Info.plist"
cp "$QUICKLOOK_EXECUTABLE_PATH" "$QUICKLOOK_APPEX/Contents/MacOS/$QUICKLOOK_NAME"

# Embed Sparkle whole, symlinks included. The executable finds it through the
# @executable_path/../Frameworks rpath set in Package.swift.
SPARKLE_FRAMEWORK="$BUILD_PRODUCTS_DIR/Sparkle.framework"
[[ -d "$SPARKLE_FRAMEWORK" ]] || { echo "Sparkle.framework was not built: $SPARKLE_FRAMEWORK"; exit 1; }
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"

# Copy SwiftPM resource bundles so bundled CSS and other assets are available at runtime.
for resource_bundle in "$BUILD_PRODUCTS_DIR"/Wafer_*.bundle; do
  bundle_name=$(basename "$resource_bundle")
  rm -rf "$APP_BUNDLE/Contents/Resources/$bundle_name"
  cp -R "$resource_bundle" "$APP_BUNDLE/Contents/Resources/"

  if [[ "$bundle_name" == "Wafer_WaferCore.bundle" ]]; then
    rm -rf "$QUICKLOOK_APPEX/Contents/Resources/$bundle_name"
    cp -R "$resource_bundle" "$QUICKLOOK_APPEX/Contents/Resources/"
  fi
done

# Quick Look imports static HTML into NSTextView and never runs these renderers.
QUICKLOOK_RESOURCES=$(resource_directory "$QUICKLOOK_APPEX/Contents/Resources/Wafer_WaferCore.bundle")
rm -f -- "$QUICKLOOK_RESOURCES"/mermaid* "$QUICKLOOK_RESOURCES"/katex* "$QUICKLOOK_RESOURCES"/KaTeX_*

codesign --force --sign - --entitlements "$ROOT_DIR/App/QuickLook.entitlements" "$QUICKLOOK_APPEX"

if [[ "${WAFER_REGISTER_APP:-0}" == "1" ]]; then
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
  fi

  if command -v pluginkit >/dev/null 2>&1; then
    pluginkit -a "$QUICKLOOK_APPEX" >/dev/null 2>&1 || true
  fi
fi

echo "Built local app bundle at $APP_BUNDLE"
