#!/bin/bash
# Package an existing .app bundle without rebuilding or launching it.
# Usage: bash scripts/package-dmg.sh [app-path] [output-path]
set -euo pipefail

APP_PATH="${1:-build/Universal TV Remote.app}"
DMG_PATH="${2:-build/Universal.TV.Remote.for.Mac.dmg}"
if [[ ! -d "$APP_PATH/Contents" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/universal-tv-remote-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_PATH" "$STAGING_DIR/Universal TV Remote.app"
ln -s /Applications "$STAGING_DIR/Applications"
mkdir -p "$(dirname "$DMG_PATH")"
hdiutil create -volname "Universal TV Remote" -srcfolder "$STAGING_DIR" \
  -format UDZO -ov "$DMG_PATH"
hdiutil verify "$DMG_PATH"
