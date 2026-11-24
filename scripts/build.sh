#!/bin/bash
# Builds build.noindex/Hush.app (universal: arm64 + x86_64). The audio driver ships
# inside it, at Contents/PlugIns/Hush.driver; install.sh copies it to HAL.
#
#   ./scripts/build.sh                    # ad-hoc signed, for local testing
#   SIGN_ID="Developer ID Application: …" ./scripts/build.sh   # cert in the keychain
#   ./scripts/release.sh                  # Developer ID in the cloud + notarization
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0}"   # local builds; release.sh sets the real one
SIGN_ID="${SIGN_ID:--}"
MIN_OS=14.0
ARCHS=(arm64 x86_64)
OUT=build.noindex   # .noindex: Spotlight skips it, so builds do not show up as a second Hush in Apps
APP="$OUT/Hush.app/Contents"
rm -rf "$OUT/Hush.app" "$OUT/Hush.driver" "$OUT/obj"
mkdir -p "$OUT/obj"

sign() { # path
  # Hardened runtime also when ad-hoc, so release.sh can re-sign this build as is.
  local args=(--force --options runtime --sign "$SIGN_ID")
  [[ "$SIGN_ID" != "-" ]] && args+=(--timestamp)
  codesign "${args[@]}" "$1"
}

echo "==> Driver"
DRV="$APP/PlugIns/Hush.driver/Contents"
mkdir -p "$DRV/MacOS"
clang -std=c11 -O2 -Wall -Wextra -mmacosx-version-min=$MIN_OS ${ARCHS[@]/#/-arch } \
  -bundle -framework CoreFoundation -framework CoreAudio \
  Driver/HushDriver.c -o "$DRV/MacOS/Hush"
sed "s/__VERSION__/$VERSION/g" Driver/Info.plist > "$DRV/Info.plist"
sign "$APP/PlugIns/Hush.driver"

echo "==> App"
mkdir -p "$APP/MacOS" "$APP/Resources"
BIN=()
for arch in "${ARCHS[@]}"; do
  target="$arch-apple-macos$MIN_OS"
  clang -target "$target" -O2 -Wall -fobjc-arc -c App/Bridge/OSD.m -IApp/Bridge -o "$OUT/obj/OSD-$arch.o"
  swiftc -target "$target" -O \
    -import-objc-header App/Bridge/Hush-Bridging-Header.h \
    App/Sources/*.swift "$OUT/obj/OSD-$arch.o" \
    -framework AppKit -framework CoreAudio -framework IOKit -framework ServiceManagement -framework ApplicationServices \
    -o "$OUT/obj/Hush-$arch"
  BIN+=("$OUT/obj/Hush-$arch")
done
lipo -create "${BIN[@]}" -output "$APP/MacOS/Hush"
sed "s/__VERSION__/$VERSION/g" App/Info.plist > "$APP/Info.plist"
[[ -f App/AppIcon.icns ]] && cp App/AppIcon.icns "$APP/Resources/" || true
sign "$OUT/Hush.app"

echo "==> Done: $OUT/Hush.app with its driver (v$VERSION, signed with: $SIGN_ID)"
