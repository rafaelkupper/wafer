#!/bin/zsh
set -euo pipefail
setopt NULL_GLOB

ROOT_DIR=${0:A:h:h}
CONFIGURATION=${1:-debug}
MODE=${CONFIGURATION:l}
APP_NAME=Wafer
QUICKLOOK_NAME=WaferQuickLook
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
RESOURCE_BUNDLES=(Wafer_WaferCore.bundle Wafer_WaferApp.bundle)
QUICKLOOK_APPEX="$APP_BUNDLE/Contents/PlugIns/$QUICKLOOK_NAME.appex"
APP_ENTITLEMENTS="$ROOT_DIR/App/$APP_NAME.entitlements"
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
BUILD_FLAGS=()
if [[ "$MODE" == "release" ]]; then
  BUILD_FLAGS=(-Xswiftc -g -Xswiftc -debug-prefix-map -Xswiftc "$ROOT_DIR=/wafer"
    -Xswiftc -file-prefix-map -Xswiftc "$ROOT_DIR=/wafer"
    -Xcc "-fdebug-prefix-map=$ROOT_DIR=/wafer")
fi
swift build -c "$MODE" "${BUILD_FLAGS[@]}" --product "$APP_NAME"
swift build -c "$MODE" "${BUILD_FLAGS[@]}" --product "$QUICKLOOK_NAME"
BUILD_PRODUCTS_DIR=$(swift build -c "$MODE" "${BUILD_FLAGS[@]}" --show-bin-path)
EXECUTABLE_PATH="$BUILD_PRODUCTS_DIR/$APP_NAME"
QUICKLOOK_EXECUTABLE_PATH="$BUILD_PRODUCTS_DIR/$QUICKLOOK_NAME"

# Check required bundles before replacing the previous app.
for bundle_name in "${RESOURCE_BUNDLES[@]}"; do
  [[ -d "$BUILD_PRODUCTS_DIR/$bundle_name" ]] || { print -u2 -- "error: missing required resource bundle: $bundle_name"; exit 1; }
done
CORE_RESOURCES=$(resource_directory "$BUILD_PRODUCTS_DIR/Wafer_WaferCore.bundle")
for resource in reader-theme.css gemoji-shortcodes.json gemoji-LICENSE.txt \
  mermaid.min.js mermaid-LICENSE.txt katex.min.js katex.min.css katex-LICENSE.txt KaTeX_Main-Regular.woff2; do
  require_resource "$CORE_RESOURCES/$resource"
done
APP_RESOURCES=$(resource_directory "$BUILD_PRODUCTS_DIR/Wafer_WaferApp.bundle")
require_resource "$APP_RESOURCES/Themes/GitHub Light.json"
require_resource "$APP_ENTITLEMENTS"
require_resource "$ROOT_DIR/App/container-migration.plist"

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
# Read by macOS once, when the first sandboxed launch creates the container.
cp "$ROOT_DIR/App/container-migration.plist" "$APP_BUNDLE/Contents/Resources/container-migration.plist"
cp "$ROOT_DIR/App/QuickLook-Info.plist" "$QUICKLOOK_APPEX/Contents/Info.plist"
cp "$QUICKLOOK_EXECUTABLE_PATH" "$QUICKLOOK_APPEX/Contents/MacOS/$QUICKLOOK_NAME"

# Embed Sparkle whole, symlinks included. The executable finds it through the
# @executable_path/../Frameworks rpath set in Package.swift.
SPARKLE_FRAMEWORK="$BUILD_PRODUCTS_DIR/Sparkle.framework"
[[ -d "$SPARKLE_FRAMEWORK" ]] || { echo "Sparkle.framework was not built: $SPARKLE_FRAMEWORK"; exit 1; }
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"

# Copy SwiftPM resource bundles so bundled CSS and other assets are available at runtime.
for bundle_name in "${RESOURCE_BUNDLES[@]}"; do
  resource_bundle="$BUILD_PRODUCTS_DIR/$bundle_name"
  cp -R "$resource_bundle" "$APP_BUNDLE/Contents/Resources/"

  if [[ "$bundle_name" == "Wafer_WaferCore.bundle" ]]; then
    cp -R "$resource_bundle" "$QUICKLOOK_APPEX/Contents/Resources/"
  fi
done

# Quick Look imports static HTML into NSTextView and never runs these renderers.
QUICKLOOK_RESOURCES=$(resource_directory "$QUICKLOOK_APPEX/Contents/Resources/Wafer_WaferCore.bundle")
rm -f -- "$QUICKLOOK_RESOURCES"/mermaid* "$QUICKLOOK_RESOURCES"/katex* "$QUICKLOOK_RESOURCES"/KaTeX_*

if [[ "$MODE" == "release" ]]; then
  for product in "$APP_NAME" "$QUICKLOOK_NAME"; do
    xcrun dsymutil "$BUILD_PRODUCTS_DIR/$product" --object-prefix-map "/wafer=$ROOT_DIR" -o "$ROOT_DIR/build/$product.dSYM"
  done
  # Keep the unstripped SwiftPM products for symbol generation; strip only shipping copies.
  strip -S -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "$QUICKLOOK_APPEX/Contents/MacOS/$QUICKLOOK_NAME"
fi

codesign --force --sign - --entitlements "$ROOT_DIR/App/QuickLook.entitlements" "$QUICKLOOK_APPEX"
# The app is signed last, after the nested code it seals, so local builds run
# in the App Sandbox with the shipping entitlements. Ad hoc signing has no team
# identity, so the hardened runtime's library validation is left to the
# Developer ID release signing in package-release.sh.
codesign --force --sign - --entitlements "$APP_ENTITLEMENTS" "$APP_BUNDLE"

if [[ "${WAFER_REGISTER_APP:-0}" == "1" ]]; then
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
  fi

  if command -v pluginkit >/dev/null 2>&1; then
    pluginkit -a "$QUICKLOOK_APPEX" >/dev/null 2>&1 || true
  fi
fi

echo "Built local app bundle at $APP_BUNDLE"
