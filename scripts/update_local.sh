#!/usr/bin/env bash
# Wait (optionally) for active GitHub Action on zhangsubo/bo-finder, then download,
# verify SHA-256 & codesign, and atomically update /Applications/DeskSide.app.
set -euo pipefail

REPO="zhangsubo/bo-finder"
INSTALL_PATH="${DESKSIDE_INSTALL_PATH:-/Applications/DeskSide.app}"

if [[ "${1:-}" == "--watch" ]]; then
    echo "==> Checking active GitHub Actions runs on $REPO..."
    RUN_ID=$(gh run list --repo "$REPO" --workflow Release --limit 1 --json databaseId,status --jq '.[] | select(.status != "completed") | .databaseId' || true)
    if [[ -n "$RUN_ID" ]]; then
        echo "==> Waiting for GitHub Actions run #$RUN_ID to finish..."
        gh run watch "$RUN_ID" --repo "$REPO" --exit-status
    fi
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deskside-local-update.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Fetching latest GitHub Release from $REPO..."
TAG="$(gh release view --repo "$REPO" --json tagName --jq '.tagName')"
LATEST_VER="${TAG#v}"
CURRENT_VER="none"
if [[ -f "$INSTALL_PATH/Contents/Info.plist" ]]; then
    CURRENT_VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INSTALL_PATH/Contents/Info.plist" 2>/dev/null || echo "unknown")"
fi
echo "    Installed: v$CURRENT_VER  ->  Latest Release: v$LATEST_VER ($TAG)"

gh release download "$TAG" --repo "$REPO" --dir "$WORK_DIR" --pattern "DeskSide-*.zip" --pattern "checksums.txt"

echo "==> Verifying SHA-256 checksum..."
(cd "$WORK_DIR" && shasum -a 256 -c checksums.txt)

ZIP_FILE="$(ls "$WORK_DIR"/DeskSide-*.zip | head -n 1)"
UNPACK_DIR="$WORK_DIR/unpacked"
mkdir -p "$UNPACK_DIR"
ditto -x -k "$ZIP_FILE" "$UNPACK_DIR"

NEW_APP="$UNPACK_DIR/DeskSide.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$NEW_APP/Contents/Info.plist")"
[[ "$BUNDLE_ID" == "com.bofinder.app" ]] || { echo "Error: unexpected Bundle ID $BUNDLE_ID" >&2; exit 1; }
codesign --verify --deep --strict "$NEW_APP"

echo "==> Stopping running DeskSide (if active)..."
osascript -e 'tell application id "com.bofinder.app" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 25); do
    pgrep -x DeskSide >/dev/null 2>&1 || break
    sleep 0.2
done
pkill -x DeskSide >/dev/null 2>&1 || true

echo "==> Installing $INSTALL_PATH (v$LATEST_VER)..."
if [[ -d "$INSTALL_PATH" ]]; then
    mv "$INSTALL_PATH" "$WORK_DIR/old-DeskSide.app"
fi
if mv "$NEW_APP" "$INSTALL_PATH"; then
    xattr -dr com.apple.quarantine "$INSTALL_PATH" 2>/dev/null || true
    rm -rf "$WORK_DIR/old-DeskSide.app"
else
    [[ -d "$WORK_DIR/old-DeskSide.app" ]] && mv "$WORK_DIR/old-DeskSide.app" "$INSTALL_PATH"
    exit 1
fi

echo "==> Launching updated $INSTALL_PATH..."
open "$INSTALL_PATH" --args --updated-silently
echo "✅ Local DeskSide updated to v$LATEST_VER!"
