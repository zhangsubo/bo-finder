#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/DeskSide.app"
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

xcrun swiftc -sdk "$SDK_PATH" -target "$TARGET" \
    "$ROOT_DIR/BoFinderApp/MeetingModels.swift" \
    "$ROOT_DIR/Tests/MeetingTests.swift" -o "$BUILD_DIR/run_meeting_tests"
"$BUILD_DIR/run_meeting_tests"
"$BUILD_DIR/run_tests"

xcrun swiftc -sdk "$SDK_PATH" -target "$TARGET" \
    "$ROOT_DIR/BoFinderApp/MeetingModels.swift" \
    "$ROOT_DIR/BoFinderApp/MeetingAppleSpeech.swift" \
    "$ROOT_DIR/Tests/MeetingAppleSpeechTests.swift" -o "$BUILD_DIR/run_apple_speech_tests"
"$BUILD_DIR/run_apple_speech_tests"

echo "==> [2/5] Preparing bundle directories..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APPEX_BUNDLE/Contents/MacOS"
mkdir -p "$APPEX_BUNDLE/Contents/Resources"

cp "$ROOT_DIR/BoFinderApp/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/BoFinderSync/Info.plist" "$APPEX_BUNDLE/Contents/Info.plist"
cp "$ROOT_DIR/BoFinderApp/AppLogo.png" "$APP_BUNDLE/Contents/Resources/AppLogo.png"
cp "$ROOT_DIR/BoFinderApp/MenuBarLogo.png" "$APP_BUNDLE/Contents/Resources/MenuBarLogo.png"
cp "$ROOT_DIR/scripts/meeting_worker.py" "$APP_BUNDLE/Contents/Resources/meeting_worker.py"

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

echo "==> [4/5] Compiling DeskSide.app (Main Menu Bar Application)..."
xcrun swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -O \
    -module-name DeskSide \
    -framework Cocoa \
    -framework SwiftUI \
    -framework ApplicationServices \
    -framework ServiceManagement \
    "$ROOT_DIR/Shared/Models.swift" \
    "$ROOT_DIR/Shared/PathFormatter.swift" \
    "$ROOT_DIR/Shared/SharedStore.swift" \
    "$ROOT_DIR/BoFinderApp/HUDWindowController.swift" \
    "$ROOT_DIR/BoFinderApp/FinderSelectionHelper.swift" \
    "$ROOT_DIR/BoFinderApp/FinderExtensionDoctor.swift" \
    "$ROOT_DIR/BoFinderApp/HiddenFilesManager.swift" \
    "$ROOT_DIR/BoFinderApp/LaunchAtLoginManager.swift" \
    "$ROOT_DIR/BoFinderApp/TerminalLauncher.swift" \
    "$ROOT_DIR/BoFinderApp/CutPasteManager.swift" \
    "$ROOT_DIR/BoFinderApp/QuickPopupMenuController.swift" \
    "$ROOT_DIR/BoFinderApp/CloudQuickBarController.swift" \
    "$ROOT_DIR/BoFinderApp/EventTapManager.swift" \
    "$ROOT_DIR/BoFinderApp/MeetingModels.swift" \
    "$ROOT_DIR/BoFinderApp/MeetingCapture.swift" \
    "$ROOT_DIR/BoFinderApp/MeetingServices.swift" \
    "$ROOT_DIR/BoFinderApp/MeetingAppleSpeech.swift" \
    "$ROOT_DIR/BoFinderApp/MeetingManager.swift" \
    "$ROOT_DIR/BoFinderApp/MeetingView.swift" \
    "$ROOT_DIR/BoFinderApp/SettingsWindow.swift" \
    "$ROOT_DIR/BoFinderApp/AppDelegate.swift" \
    "$ROOT_DIR/BoFinderApp/main.swift" \
    -o "$APP_BUNDLE/Contents/MacOS/DeskSide"

echo "==> [5/5] Code signing bundles..."
codesign --force --sign - \
    --entitlements "$ROOT_DIR/BoFinderSync/BoFinderSync.entitlements" \
    "$APPEX_BUNDLE"

codesign --force --sign - \
    --entitlements "$ROOT_DIR/BoFinderApp/BoFinder.entitlements" \
    "$APP_BUNDLE"

# Building does not change the active Finder extension. The app registers it on launch.
if [[ "${1:-}" == "--register" ]]; then
    pluginkit -a "$APPEX_BUNDLE"
    pluginkit -e use -i com.bofinder.app.FinderSync
fi

echo ""
echo "✅ Build complete: $APP_BUNDLE"
