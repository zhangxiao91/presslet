#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAKE_DMG=false
if [[ "${1:-}" == "--dmg" && $# -eq 1 ]]; then
  MAKE_DMG=true
elif [[ $# -gt 0 ]]; then
  printf 'Usage: %s [--dmg]\n' "$0" >&2
  exit 2
fi

"$PROJECT_DIR/scripts/test.sh"
"$PROJECT_DIR/build.sh"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Info.plist")"
DIST_DIR="$PROJECT_DIR/dist"
PACKAGE_NAME="Presslet-$VERSION-macos-arm64"
mkdir -p "$DIST_DIR"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent \
  "$PROJECT_DIR/build/Presslet.app" "$DIST_DIR/$PACKAGE_NAME.zip"
printf 'Packaged: %s\n' "$DIST_DIR/$PACKAGE_NAME.zip"

if $MAKE_DMG; then
  STAGING_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/presslet-dmg.XXXXXX")"
  trap 'rm -rf "$STAGING_DIR"' EXIT
  /usr/bin/ditto "$PROJECT_DIR/build/Presslet.app" "$STAGING_DIR/Presslet.app"
  /bin/ln -s /Applications "$STAGING_DIR/Applications"
  /usr/bin/hdiutil create -quiet -volname Presslet -srcfolder "$STAGING_DIR" \
    -format UDZO -ov "$DIST_DIR/$PACKAGE_NAME.dmg"
  printf 'Packaged: %s\n' "$DIST_DIR/$PACKAGE_NAME.dmg"
fi
