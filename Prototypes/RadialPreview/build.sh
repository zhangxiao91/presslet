#!/bin/bash
set -euo pipefail
PREVIEW_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$PREVIEW_DIR/../.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build/radial-preview"
APP_DIR="$BUILD_DIR/PressletRadialPreview.app"
mkdir -p "$BUILD_DIR/module-cache" "$APP_DIR/Contents/MacOS"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx14.0 -O \
  -module-cache-path "$BUILD_DIR/module-cache" -framework AppKit -framework QuartzCore \
  "$PREVIEW_DIR/Main.swift" "$PROJECT_DIR/Sources/RadialSelection.swift" "$PROJECT_DIR/Sources/PressureFeedback.swift" "$PROJECT_DIR/Sources/RadialBubbleMotion.swift" "$PROJECT_DIR/Sources/RadialMenuView.swift" \
  -o "$APP_DIR/Contents/MacOS/PressletRadialPreview"
cp "$PREVIEW_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
