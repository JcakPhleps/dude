#!/usr/bin/env bash
# Build Dude.dmg — a drag-to-Applications installer disk image.
#
# Prereqs:
#   brew install create-dmg
#   a Release build of Dude.app (xcodebuild ... -configuration Release build)
#
# Design your artwork against these coordinates (see dmg/README.md):
#   window 640x400 · Dude.app icon centered at (160,185) · Applications at (480,185)
# Drop the art at dmg/background.png (640x400) and dmg/background@2x.png (1280x800);
# this script fuses them into a Retina-ready .tiff automatically.
set -euo pipefail

cd "$(dirname "$0")/.."      # repo root
ROOT="$PWD"

VOLNAME="Install dude"
WINDOW_W=640 ; WINDOW_H=400
ICON_SIZE=128
APP_X=160  ; APP_Y=185       # center of the Dude.app icon
APPS_X=480 ; APPS_Y=185      # center of the Applications shortcut

# 1. Locate the Release build.
APP="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project Dude.xcodeproj -scheme Dude -configuration Release \
  -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{d=$3} END{print d"/Dude.app"}')"
if [ ! -d "$APP" ]; then
  echo "✖ No Release build found. First run:"
  echo "  xcodegen generate"
  echo "  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Dude.xcodeproj -scheme Dude -configuration Release build"
  exit 1
fi

# 2. Stage a clean folder holding just the app.
SRC="$ROOT/build/dmg-src"
rm -rf "$SRC" && mkdir -p "$SRC"
cp -R "$APP" "$SRC/"

# 3. Fuse a Retina background .tiff if the art is present.
BG_ARG=()
if [ -f "$ROOT/dmg/background.png" ] && [ -f "$ROOT/dmg/background@2x.png" ]; then
  mkdir -p "$ROOT/build"
  tiffutil -cathidpicheck "$ROOT/dmg/background.png" "$ROOT/dmg/background@2x.png" \
    -out "$ROOT/build/background.tiff"
  BG_ARG=(--background "$ROOT/build/background.tiff")
elif [ -f "$ROOT/dmg/background.png" ]; then
  BG_ARG=(--background "$ROOT/dmg/background.png")
else
  echo "… no dmg/background.png yet — building a plain DMG (add the art and re-run)."
fi

# 4. Build the DMG.
rm -f "$ROOT/Dude.dmg"
create-dmg \
  --volname "$VOLNAME" \
  "${BG_ARG[@]}" \
  --window-pos 200 120 \
  --window-size "$WINDOW_W" "$WINDOW_H" \
  --icon-size "$ICON_SIZE" \
  --icon "Dude.app" "$APP_X" "$APP_Y" \
  --app-drop-link "$APPS_X" "$APPS_Y" \
  --hide-extension "Dude.app" \
  --no-internet-enable \
  "$ROOT/Dude.dmg" \
  "$SRC"

echo "✓ Built $ROOT/Dude.dmg"
