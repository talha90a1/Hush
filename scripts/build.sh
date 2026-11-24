#!/bin/bash
# Builds build.noindex/Hush.app (universal: arm64 + x86_64). The audio driver ships
# inside it, at Contents/PlugIns/Hush.driver; install.sh copies it to HAL.
#
#   ./scripts/build.sh                          # ad-hoc signed
#   SIGN_ID="Hush Release" ./scripts/build.sh   # identity in the keychain
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0}"
# Bump only when Driver/ changes: the app reinstalls the driver (password + audio restart)
# when the installed driver's version differs from this one.
DRIVER_VERSION=1.0.0
SIGN_ID="${SIGN_ID:--}"
SPARKLE_VERSION=2.10.1
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
MIN_OS=14.0
ARCHS=(arm64 x86_64)
OUT=build.noindex   # .noindex: Spotlight skips it, so builds do not show up as a second Hush in Apps
APP="$OUT/Hush.app/Contents"
rm -rf "$OUT/Hush.app" "$OUT/Hush.driver" "$OUT/obj"
mkdir -p "$OUT/obj"

SPARKLE="$OUT/Sparkle-$SPARKLE_VERSION"
if [[ ! -d "$SPARKLE/Sparkle.framework" ]]; then
  echo "==> Sparkle $SPARKLE_VERSION"
  archive="$OUT/Sparkle-$SPARKLE_VERSION.tar.xz"
  curl -fsSL -o "$archive" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  echo "$SPARKLE_SHA256  $archive" | shasum -a 256 -c -
  mkdir -p "$SPARKLE"
  tar -xJf "$archive" -C "$SPARKLE"
  rm "$archive"
fi

sign() { # path [codesign options]
  codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" "${@:2}" "$1"
}

echo "==> Driver"
DRV="$APP/PlugIns/Hush.driver/Contents"
mkdir -p "$DRV/MacOS"
clang -std=c11 -O2 -Wall -Wextra -mmacosx-version-min=$MIN_OS ${ARCHS[@]/#/-arch } \
  -bundle -framework CoreFoundation -framework CoreAudio \
  Driver/HushDriver.c -o "$DRV/MacOS/Hush"
sed "s/__VERSION__/$DRIVER_VERSION/g" Driver/Info.plist > "$DRV/Info.plist"
sign "$APP/PlugIns/Hush.driver"

echo "==> App"
mkdir -p "$APP/MacOS" "$APP/Resources"
BIN=()
for arch in "${ARCHS[@]}"; do
  target="$arch-apple-macos$MIN_OS"
  swiftc -target "$target" -O \
    -import-objc-header App/Bridge/Hush-Bridging-Header.h \
    App/Sources/*.swift \
    -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -framework AppKit -framework CoreAudio -framework IOKit -framework ServiceManagement -framework ApplicationServices -framework CoreLocation \
    -o "$OUT/obj/Hush-$arch"
  BIN+=("$OUT/obj/Hush-$arch")
done
lipo -create "${BIN[@]}" -output "$APP/MacOS/Hush"
sed "s/__VERSION__/$VERSION/g" App/Info.plist > "$APP/Info.plist"
[[ -f App/AppIcon.icns ]] && cp App/AppIcon.icns "$APP/Resources/" || true

# Hush isn't sandboxed, so Sparkle's XPC services aren't needed.
FW="$APP/Frameworks/Sparkle.framework"
mkdir -p "$APP/Frameworks"
ditto "$SPARKLE/Sparkle.framework" "$FW"
rm -rf "$FW/Versions/B/XPCServices" "$FW/XPCServices"
cp "$SPARKLE/LICENSE" "$APP/Resources/Sparkle LICENSE.txt"
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"

sign "$OUT/Hush.app" --entitlements App/Hush.entitlements

echo "==> Done: $OUT/Hush.app with its driver (v$VERSION, signed with: $SIGN_ID)"
