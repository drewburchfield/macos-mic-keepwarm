#!/bin/bash
# Render App/AppIcon/*.svg into App/AppIcon.icns.
#
# AppIcon.svg is the full Night icon; AppIcon-small.svg is the simplified drawing used
# at 16 and 32 px. Rendering needs Google Chrome (headless) and ImageMagick, so the .icns
# is committed and CI does not regenerate it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/App/AppIcon"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

render() {  # svg -> 1024px png with transparent corners
    local name="$1"
    printf '<!doctype html><body style="margin:0"><img src="file://%s" width="1024" height="1024">' \
        "$SRC/$name.svg" > "$WORK/$name.html"
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=1024,1024 \
        --default-background-color=00000000 --screenshot="$WORK/$name.png" \
        "file://$WORK/$name.html" >/dev/null 2>&1
}
render AppIcon
render AppIcon-small

SET="$WORK/AppIcon.iconset"
mkdir "$SET"
resize() { magick "$WORK/$1.png" -filter Lanczos -resize "$2x$2" "$SET/$3"; }
resize AppIcon-small 16   icon_16x16.png
resize AppIcon-small 32   icon_16x16@2x.png
resize AppIcon-small 32   icon_32x32.png
resize AppIcon       64   icon_32x32@2x.png
resize AppIcon       128  icon_128x128.png
resize AppIcon       256  icon_128x128@2x.png
resize AppIcon       256  icon_256x256.png
resize AppIcon       512  icon_256x256@2x.png
resize AppIcon       512  icon_512x512.png
cp "$WORK/AppIcon.png" "$SET/icon_512x512@2x.png"

iconutil --convert icns --output "$ROOT/App/AppIcon.icns" "$SET"
echo "Wrote $ROOT/App/AppIcon.icns"
