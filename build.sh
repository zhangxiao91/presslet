#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_DIR="$BUILD_DIR/Presslet.app"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:--}"

if [[ $# -gt 0 ]]; then
  printf 'Usage: %s\n' "$0" >&2
  exit 2
fi

mkdir -p "$BUILD_DIR/module-cache" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

xcrun swiftc \
  -target arm64-apple-macosx14.0 -swift-version 5 -O \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -framework AppKit -framework Carbon -framework ApplicationServices \
  "$PROJECT_DIR"/Sources/*.swift \
  -o "$BUILD_DIR/Presslet"

xcrun swiftc \
  -target "$(uname -m)-apple-macosx14.0" -swift-version 5 \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -framework AppKit "$PROJECT_DIR/Tools/MakeIcon.swift" \
  -o "$BUILD_DIR/MakeIcon"
"$BUILD_DIR/MakeIcon" "$BUILD_DIR/AppIcon.icns"

/usr/bin/install -m 755 "$BUILD_DIR/Presslet" "$APP_DIR/Contents/MacOS/Presslet"
/bin/cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
/bin/cp "$BUILD_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"

SIGNING_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGNING_ARGS+=(--options runtime --timestamp)
fi
/usr/bin/codesign "${SIGNING_ARGS[@]}" "$APP_DIR"
/usr/bin/codesign --verify --strict --verbose=2 "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
