#!/bin/zsh
set -euo pipefail

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
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

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
for resource_bundle in "$BUILD_PRODUCTS_DIR"/Wafer_*.bundle(N); do
  bundle_name=$(basename "$resource_bundle")
  rm -rf "$APP_BUNDLE/Contents/Resources/$bundle_name"
  cp -R "$resource_bundle" "$APP_BUNDLE/Contents/Resources/"

  if [[ "$bundle_name" == "Wafer_WaferCore.bundle" ]]; then
    rm -rf "$QUICKLOOK_APPEX/Contents/Resources/$bundle_name"
    cp -R "$resource_bundle" "$QUICKLOOK_APPEX/Contents/Resources/"
  fi
done

codesign --force --sign - --entitlements "$ROOT_DIR/App/QuickLook.entitlements" "$QUICKLOOK_APPEX"

if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

if command -v pluginkit >/dev/null 2>&1; then
  pluginkit -a "$QUICKLOOK_APPEX" >/dev/null 2>&1 || true
fi

echo "Built local app bundle at $APP_BUNDLE"
