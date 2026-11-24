#!/bin/bash
# Packs build.noindex/Hush.app into build.noindex/Hush-$VERSION.dmg, with a link to
# /Applications to drag it onto.
#
#   VERSION=1.2.0 ./scripts/dmg.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?set VERSION, e.g. VERSION=1.2.0 ./scripts/dmg.sh}"
OUT=build.noindex
STAGE="$OUT/dmg"
DMG="$OUT/Hush-$VERSION.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$OUT/Hush.app" "$STAGE/Hush.app"
ln -s /Applications "$STAGE/Applications"
if diskutil image create from -h >/dev/null 2>&1; then # macOS 26+
  diskutil image create from --format ULFO --volumeName "Hush $VERSION" "$STAGE" "$DMG" >/dev/null 2>&1
else
  hdiutil create -volname "Hush $VERSION" -srcfolder "$STAGE" -fs APFS -format ULFO "$DMG" >/dev/null
fi
rm -rf "$STAGE"
echo "==> $DMG"
