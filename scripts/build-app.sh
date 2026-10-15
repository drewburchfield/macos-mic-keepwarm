#!/bin/bash
# Build "Mic Warm.app" from the MicWarmApp SwiftPM target.
#
#   scripts/build-app.sh              native arch, release
#   scripts/build-app.sh --universal  arm64 + x86_64, release
#
# Output: .build/Mic Warm.app, ad-hoc signed. Developer ID signing and notarization come later.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ARCH_FLAGS=()
if [[ "${1:-}" == "--universal" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release --product MicWarmApp ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release --product MicWarmApp ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="$ROOT/.build/Mic Warm.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MicWarmApp" "$APP/Contents/MacOS/Mic Warm"
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --sign - "$APP"
echo "Built $APP"
