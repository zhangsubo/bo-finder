#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/BoFinder.app"
APPEX_BUNDLE="$APP_BUNDLE/Contents/PlugIns/BoFinderSync.appex"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos13.0"

echo "==> [1/5] Running unit tests..."
mkdir -p "$BUILD_DIR"
xcrun swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -framework Cocoa \
    "$ROOT_DIR/Shared/Models.swift" \
    "$ROOT_DIR/Shared/PathFormatter.swift" \
    "$ROOT_DIR/Shared/SharedStore.swift" \
    "$ROOT_DIR/Tests/PathFormatterTests.swift" \
    -o "$BUILD_DIR/run_tests"
"$BUILD_DIR/run_tests"

echo "==> [2/5] Preparing bundle directories..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APPEX_BUNDLE/Contents/MacOS"
mkdir -p "$APPEX_BUNDLE/Contents/Resources"

cp "$ROOT_DIR/BoFinderApp/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/BoFinderSync/Info.plist" "$APPEX_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/BoFinderApp/AppLogo.png" "$APP_BUNDLE/Contents/Resources/AppLogo.png"

ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
xcrun swift "$ROOT_DIR/scripts/generate_icon.swift" "$ICONSET_DIR" "$ROOT_DIR/BoFinderApp/AppLogo.png"
iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$APP_BUNDLE/Contents/Resources/AppIcon.icns" "$APPEX_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET_DIR"

echo "==> [3/5] Compiling BoFinderSync.appex (Finder Sync Extension)..."
xcrun swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -O \
    -application-extension \
    -module-name BoFinderSync \
    -framework Cocoa \
    -framework FinderSync \
    -Xlinker -e -Xlinker _NSExtensionMain \
    "$ROOT_DIR/Shared/Models.swift" \
    "$ROOT_DIR/Shared/PathFormatter.swift" \
    "$ROOT_DIR/Shared/SharedStore.swift" \
    "$ROOT_DIR/BoFinderSync/FinderSync.swift" \
    -o "$APPEX_BUNDLE/Contents/MacOS/BoFinderSync"

echo "==> [4/5] Compiling BoFinder.app (Main Menu Bar Application)..."
xcrun swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -O \
    -module-name BoFinder \
    -framework Cocoa \
    -framework SwiftUI \
    -framework ApplicationServices \
    "$ROOT_DIR/Shared/Models.swift" \
    "$ROOT_DIR/Shared/PathFormatter.swift" \
    "$ROOT_DIR/Shared/SharedStore.swift" \
    "$ROOT_DIR/BoFinderApp/HUDWindowController.swift" \
    "$ROOT_DIR/BoFinderApp/FinderSelectionHelper.swift" \
    "$ROOT_DIR/BoFinderApp/FinderExtensionDoctor.swift" \
    "$ROOT_DIR/BoFinderApp/TerminalLauncher.swift" \
    "$ROOT_DIR/BoFinderApp/CutPasteManager.swift" \
    "$ROOT_DIR/BoFinderApp/QuickPopupMenuController.swift" \
    "$ROOT_DIR/BoFinderApp/CloudQuickBarController.swift" \
    "$ROOT_DIR/BoFinderApp/EventTapManager.swift" \
    "$ROOT_DIR/BoFinderApp/SettingsWindow.swift" \
    "$ROOT_DIR/BoFinderApp/AppDelegate.swift" \
    "$ROOT_DIR/BoFinderApp/main.swift" \
    -o "$APP_BUNDLE/Contents/MacOS/BoFinder"

echo "==> [5/5] Code signing and registering Finder Sync Extension..."
codesign --force --sign - \
    --entitlements "$ROOT_DIR/BoFinderSync/BoFinderSync.entitlements" \
    "$APPEX_BUNDLE"

codesign --force --sign - \
    --entitlements "$ROOT_DIR/BoFinderApp/BoFinder.entitlements" \
    "$APP_BUNDLE"

pluginkit -a "$APPEX_BUNDLE" || true
pluginkit -e use -i com.bofinder.app.FinderSync || true

echo ""
echo "✅ Build complete: $APP_BUNDLE"
